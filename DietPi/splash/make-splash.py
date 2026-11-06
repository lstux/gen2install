#!/usr/bin/env python3
"""Build the boot splash images (raw framebuffer contents, gzip) from logo.svg.
Needs rsvg-convert and python3-pillow. Run it after changing logo.svg, commit the results.

fpv-pitft-240x320 / fpv-pitft-320x240 : RGB565 of the PiTFT 2.8" (fbtft turns the picture by itself, upright)
fpv-hdmi-<rotation>                   : 1024x600 XRGB8888 of the HDMI panel, the picture is turned in it when the
                                        panel is mounted in portrait (rotation as -R of DietPi_Customize.sh)
"""
import gzip, os, struct, subprocess, sys, tempfile
from PIL import Image, ImageChops

HERE = os.path.dirname(os.path.abspath(__file__))
BG = (0x0b, 0x12, 0x20)

FRAMES = 8
ACCENT = (0xff, 0x7a, 0x1a)

def spinner(im, w, h, k):
    """Ring of dots under the picture, dot k is the brightest and the ones before it fade (frame k of FRAMES)"""
    import math
    from PIL import ImageDraw
    s = min(w, h)
    cx, cy, r = w / 2, (h - s) / 2 + 0.93 * s, 0.035 * s
    dot = max(1.6, r * 0.26)
    big = 4
    box = int(2 * (r + dot) + 4)
    x0, y0 = int(cx - box / 2), int(cy - box / 2)
    tile = Image.new("RGB", (box * big, box * big), BG)
    d = ImageDraw.Draw(tile)
    for i in range(FRAMES):
        lvl = 1.0 - ((k - i) % FRAMES) / FRAMES
        lvl = 0.12 + 0.88 * lvl ** 2
        col = tuple(int(BG[c] + (ACCENT[c] - BG[c]) * lvl) for c in range(3))
        a = 2 * math.pi * i / FRAMES - math.pi / 2
        px, py = (box / 2 + r * math.cos(a)) * big, (box / 2 + r * math.sin(a)) * big
        d.ellipse((px - dot * big, py - dot * big, px + dot * big, py + dot * big), fill=col)
    im.paste(tile.resize((box, box), Image.LANCZOS), (x0, y0))

def upright(w, h, k=None):
    s = min(w, h)
    with tempfile.TemporaryDirectory() as t:
        png = os.path.join(t, "l.png")
        subprocess.run(["rsvg-convert", "-w", str(s), "-h", str(s), os.path.join(HERE, "logo.svg"), "-o", png], check=True)
        logo = Image.open(png).convert("RGB")
    im = Image.new("RGB", (w, h), BG)
    im.paste(logo, ((w - s) // 2, (h - s) // 2))
    if k is not None:
        spinner(im, w, h, k)
    return im

def rgb565(im):
    return b"".join(struct.pack("<H", ((r >> 3) << 11) | ((g >> 2) << 5) | (b >> 3)) for r, g, b in im.get_flattened_data()) \
        if hasattr(im, "get_flattened_data") else \
        b"".join(struct.pack("<H", ((r >> 3) << 11) | ((g >> 2) << 5) | (b >> 3)) for r, g, b in im.getdata())

def xrgb8888(im):
    return b"".join(bytes((b, g, r, 0)) for r, g, b in (im.get_flattened_data() if hasattr(im, "get_flattened_data") else im.getdata()))

def save(name, data):
    with gzip.GzipFile(os.path.join(HERE, name + ".raw.gz"), "wb", 9, mtime=0) as f:
        f.write(data)
    print(name, len(data))

def variant(name, fmt, w, h, turn):
    """Picture of the framebuffer (turn: function applied to the upright picture) and its animation: the rows of the
    picture that change, FRAMES times. Written as <name>.raw.gz and <name>-anim.raw.gz + <name>-anim.txt (first row,
    rows, frames, bytes per row)"""
    bpp = 2 if fmt is rgb565 else 4
    base = turn(upright(w, h))
    save(name, fmt(base))
    frames = [turn(upright(w, h, k)) for k in range(FRAMES)]
    diff = [f for f in frames if f.tobytes() != base.tobytes()]
    rows = set()
    for f in frames:
        bb = Image.frombytes("RGB", base.size, ImageChops.difference(f, base).tobytes()).getbbox()
        rows.update(range(bb[1], bb[3]))
    r0, r1 = min(rows), max(rows) + 1
    data = b"".join(fmt(f.crop((0, r0, f.width, r1))) for f in frames)
    save(name + "-anim", data)
    with open(os.path.join(HERE, name + "-anim.txt"), "w") as f:
        f.write("%d %d %d %d\n" % (r0, r1 - r0, FRAMES, base.width * bpp))

ident = lambda im: im
variant("fpv-pitft-240x320", rgb565, 240, 320, ident)
variant("fpv-pitft-320x240", rgb565, 320, 240, ident)
variant("fpv-hdmi-normal", xrgb8888, 1024, 600, ident)
variant("fpv-hdmi-right", xrgb8888, 600, 1024, lambda im: im.rotate(-90, expand=True))
variant("fpv-hdmi-left", xrgb8888, 600, 1024, lambda im: im.rotate(90, expand=True))
variant("fpv-hdmi-inverted", xrgb8888, 1024, 600, lambda im: im.rotate(180))
