#!/bin/sh
# Preconfigure a DietPi image (or an SD card freshly written with one) for one of my Raspberry Pi boards:
# unattended first run (hostname, timezone, locale, OpenSSH, user with SSH key), Waveshare HDMI LCD with XPT2046
# touch, and depending on the board camera and I2C sensors. Ethernet, optional Wi-Fi.
# Only the FAT boot partition is modified: DietPi imports dietpi.txt and the Automation_Custom_* scripts from it
# on first boot, then removes them from it.
set -eu

BOARD=""
HOSTNAME_NEW=""
USER_NAME="nsd"
TIMEZONE="Europe/Paris"
LOCALE="fr_FR.UTF-8"
KEYBOARD_LAYOUT="fr"
WIFI_COUNTRY="FR"
WPA_FILE=""
SSH_SERVER="dropbear"
KIOSK_URL=""
BUTTONS=""
SPLASH=""
SCREEN_KIND=""
WPA_DEFAULT="/etc/wpa_supplicant/wpa_supplicant.conf"
PASSWORD=""
PENIRQ_GPIO=""
TOUCH_SWAP=""
ROTATE=""
TOUCH_PMAX=""
GYRO_SENSOR=""
PRESSURE_SENSOR=""
CAMERA=""
# Public keys of the user: downloaded from the web site (no directory listing there, hence the list)
KEYS_URL="https://lslinux.org/identities"
KEYS_DEFAULT="id_nsd_nsvivo.pub id_nsd_nsbox.pub id_nsd_pixel8.pub"
NL='
'
KEY_SOURCES=""
# Groups the user is added to (those missing on the board are skipped)
USER_GROUPS="sudo adm dialout audio video plugdev input render netdev gpio i2c spi users systemd-journal"
# APT packages installed at the end of the first run: mDNS and touch tools, more below for I2C and the camera
APT_INSTALLS="avahi-daemon libnss-mdns evtest"
MARK_BEGIN="# >>> DietPi_Customize.sh"
MARK_END="# <<< DietPi_Customize.sh"

# --- Board profiles: hardware plugged on each board, options below override them ---
# board_profile BOARD : set the P_* variables, fail on an unknown board
board_profile() {
  case "$1" in
    rpi3b)
      P_HOSTNAME="rpi3b"
      P_DTBS="bcm2710-rpi-3-b.dtb"
      P_SCREEN_KIND="hdmi"
      P_SCREEN_NAME='Waveshare 10.1" HDMI LCD'
      P_SCREEN_W=1024; P_SCREEN_H=600
      P_PENIRQ=25
      # Measured: the touch axes of this panel are swapped against the screen
      P_TOUCH_SWAP="on"
      P_ROTATE="normal"
      # Measured on this panel: a press has a resistance of 300 to 800, the contact and the release of the pen
      # 800 to 1600 with a position that is off by tens of pixels. The driver drops what is above this limit.
      P_TOUCH_PMAX=800
      P_GYRO="mpu6050"; P_PRESSURE="bmp180"; P_CAMERA="on"
      P_EXTRA_CONFIG=""
      # Mode of the screen for X, when the 1024x600 of its EDID is enough there is no modeline to add
      P_MODELINE=""
      ;;
    rpi2)
      P_HOSTNAME="rpi2"
      # v1.1 (BCM2836) or v1.2 (BCM2837)
      P_DTBS="bcm2709-rpi-2-b.dtb bcm2710-rpi-2-b.dtb"
      # The 5" Waveshare is still here with -D hdmi, but its touch controller does not answer on the board
      P_SCREEN_KIND="pitft28"
      P_SCREEN_NAME='Waveshare 5" HDMI LCD'
      P_SCREEN_W=800; P_SCREEN_H=480
      P_PENIRQ=25
      # Not measured: touch-calibrate notices it by itself and swaps them, at the cost of a second calibration
      P_TOUCH_SWAP="off"
      P_ROTATE="normal"
      # Not measured on this panel (its touch does not answer yet), the one of the 10.1" for now
      P_TOUCH_PMAX=800
      P_GYRO="none"; P_PRESSURE="none"; P_CAMERA="off"
      # Up to 1.2 A on the USB ports, the screen is powered from one of them
      P_EXTRA_CONFIG="max_usb_current=1"
      # 800x480 is not sure to be in the modes of the screen, this one is the CVT timing of it
      P_MODELINE='"800x480" 29.50 800 824 896 992 480 483 493 500 -hsync +vsync'
      ;;
    *) return 1;;
  esac
}

usage() {
  exec >&2
  printf "Usage : %s -B BOARD [options] {image.img.xz|image.img|device}\n" "$(basename "$0")"
  printf "  Preconfigure a DietPi image for an unattended first boot on a Raspberry Pi\n"
  printf "  - image.img.xz : decompressed to image.custom.img (original untouched), then customized\n"
  printf "  - image.img    : customized in place\n"
  printf "  - device       : SD card already written with a DietPi image, not booted yet\n"
  printf "Boards :\n"
  printf "  rpi3b : Waveshare 10.1\" HDMI LCD 1024x600, camera, MPU-6050 and BMP180 on I2C\n"
  printf "  rpi2  : Adafruit PiTFT 2.8\" 240x320 on SPI (or with -D hdmi the Waveshare 5\" HDMI LCD 800x480)\n"
  printf "Options :\n"
  printf "  -B BOARD  : board, mandatory (rpi3b or rpi2)\n"
  printf "  -H NAME   : hostname (default: the board name)\n"
  printf "  -u USER   : user to create (default: %s)\n" "${USER_NAME}"
  printf "  -k KEY    : SSH public key file or https URL, can be repeated\n"
  printf "              (default: %s/{%s})\n" "${KEYS_URL}" "$(printf '%s' "${KEYS_DEFAULT}" | tr ' ' ',')"
  printf "  -p PASS   : password of root, dietpi and USER for console logins (default: random, printed at the end)\n"
  printf "  -t TZ     : timezone (default: %s)\n" "${TIMEZONE}"
  printf "  -l LOCALE : locale (default: %s)\n" "${LOCALE}"
  printf "  -K LAYOUT : console keyboard layout (default: %s)\n" "${KEYBOARD_LAYOUT}"
  printf "  -w FILE   : wpa_supplicant.conf with the Wi-Fi networks to join (the first 5 are used, DHCP, Ethernet preferred)\n"
  printf "              (default: %s if readable and with networks, none: no Wi-Fi)\n" "${WPA_DEFAULT}"
  printf "  -U URL    : install Chromium and start it full screen (kiosk) on this URL at boot\n"
  printf "  -F on|off : 4 push buttons between GPIO and ground, as keys of the kiosk (default: on with -U, off without)\n"
  printf "              GPIO23 reload (long press, 3 s: power off), GPIO22 back, GPIO27 page down, GPIO17 home\n"
  printf "  -s on|off : quiet boot and FPV splash screen, set up at the end of the first run so that it stays visible\n"
  printf "              (default: on with -U, off without)\n"
  printf "  -S SERVER : SSH server, dropbear or openssh (default: %s)\n" "${SSH_SERVER}"
  printf "  -c CODE   : Wi-Fi country code (default: %s)\n" "${WIFI_COUNTRY}"
  printf "  -T GPIO   : GPIO of the touch controller pen interrupt, or none (default: 25)\n"
  printf "  -D SCREEN : screen, hdmi (the HDMI LCD of the board) or pitft28 (Adafruit PiTFT 2.8\", SPI, no HDMI)\n"
  printf "              (default: board). With pitft28 -T and -P do not apply, -R left/right gives a landscape screen\n"
  printf "  -P LIMIT  : touch pressure limit of the driver, 100 to 65535 (default: board). Lower: steadier\n"
  printf "              pointer but a firmer press needed, higher: lighter touches (stylus) but pointer jumps\n"
  printf "  -R ROTATION : screen orientation, normal, left, right or inverted (default: normal)\n"
  printf "              left and right give a portrait screen, the touch axes and the kiosk size follow\n"
  printf "  -X on|off : touch axes swapped against the screen (default: board and rotation, found by itself when off)\n"
  printf "  -g SENSOR : gyroscope/accelerometer on I2C, mpu6050 or none (default: board)\n"
  printf "  -b SENSOR : pressure sensor on I2C, bmp180, bme280 or none (default: board)\n"
  printf "  -C on|off : camera module (default: board)\n"
  printf "  -h        : display this help message\n"
  exit "${1:-1}"
}

die() { printf 'Error: %s\n' "$*" >&2; exit 1; }
info() { printf '%s\n' "$*" >&2; }

while getopts B:H:u:k:p:t:l:K:w:c:S:U:F:s:T:P:R:X:D:g:b:C:h opt; do case "${opt}" in
  B) BOARD="${OPTARG}";;
  H) HOSTNAME_NEW="${OPTARG}";;
  u) USER_NAME="${OPTARG}";;
  k) KEY_SOURCES="${KEY_SOURCES}${OPTARG}${NL}";;
  p) PASSWORD="${OPTARG}";;
  t) TIMEZONE="${OPTARG}";;
  l) LOCALE="${OPTARG}";;
  K) KEYBOARD_LAYOUT="${OPTARG}";;
  w) WPA_FILE="${OPTARG}";;
  c) WIFI_COUNTRY="${OPTARG}";;
  S) SSH_SERVER="${OPTARG}";;
  U) KIOSK_URL="${OPTARG}";;
  F) BUTTONS="${OPTARG}";;
  s) SPLASH="${OPTARG}";;
  T) PENIRQ_GPIO="${OPTARG}";;
  P) TOUCH_PMAX="${OPTARG}";;
  R) ROTATE="${OPTARG}";;
  X) TOUCH_SWAP="${OPTARG}";;
  D) SCREEN_KIND="${OPTARG}";;
  g) GYRO_SENSOR="${OPTARG}";;
  b) PRESSURE_SENSOR="${OPTARG}";;
  C) CAMERA="${OPTARG}";;
  h) usage 0;;
  *) usage;;
esac; done
shift $((OPTIND - 1))
[ $# -eq 1 ] || usage
TARGET="$1"

[ -n "${BOARD}" ] || usage
board_profile "${BOARD}" || die "unknown board '${BOARD}'"
SCREEN_KIND="${SCREEN_KIND:-${P_SCREEN_KIND}}"
case "${SCREEN_KIND}" in
  hdmi) ;;
  pitft28)
    # Adafruit PiTFT 2.8": display (ILI9341) and touch (STMPE610) on SPI0, 240x320 in portrait by default
    P_SCREEN_NAME='Adafruit PiTFT 2.8" (ILI9341 + STMPE610)'
    P_SCREEN_W=240; P_SCREEN_H=320
    P_TOUCH_SWAP="off"; P_MODELINE=""; P_EXTRA_CONFIG="";;
  *) die "-D expects hdmi or pitft28";;
esac
HOSTNAME_NEW="${HOSTNAME_NEW:-${P_HOSTNAME}}"
PENIRQ_GPIO="${PENIRQ_GPIO:-${P_PENIRQ}}"
ROTATE="${ROTATE:-${P_ROTATE}}"
TOUCH_PMAX="${TOUCH_PMAX:-${P_TOUCH_PMAX}}"
GYRO_SENSOR="${GYRO_SENSOR:-${P_GYRO}}"
PRESSURE_SENSOR="${PRESSURE_SENSOR:-${P_PRESSURE}}"
CAMERA="${CAMERA:-${P_CAMERA}}"
# Wi-Fi networks: the ones of this computer unless told otherwise
case "${WPA_FILE}" in
  none) WPA_FILE="";;
  "")
    if [ -r "${WPA_DEFAULT}" ] && grep -q '^[[:space:]]*network=' "${WPA_DEFAULT}"; then
      WPA_FILE="${WPA_DEFAULT}"
      info "Wi-Fi networks taken from ${WPA_DEFAULT} (-w none to disable)"
    fi;;
esac

# --- Checks (as the calling user, so that relative paths and ~ keep their meaning) ---
case "${HOSTNAME_NEW}" in
  ''|-*|*[!a-zA-Z0-9-]*) die "invalid hostname '${HOSTNAME_NEW}'";;
esac
case "${USER_NAME}" in
  ''|-*|*[!a-z0-9_-]*|root|dietpi) die "invalid user name '${USER_NAME}'";;
esac
# dietpi.txt is read by shell scripts and some DietPi software chokes on $"|\ : keep the password simple
case "${PASSWORD}" in
  *[!A-Za-z0-9_.,:@%+=-]*) die "the password may only contain letters, digits and _.,:@%+=-";;
esac
case "${TIMEZONE}" in
  ''|/*|*..*|*[!a-zA-Z0-9/_+-]*) die "invalid timezone '${TIMEZONE}'";;
esac
case "${LOCALE}" in
  *.UTF-8) ;;
  *) die "locale must be a UTF-8 locale (eg. fr_FR.UTF-8)";;
esac
case "${LOCALE}" in
  ''|*[!a-zA-Z0-9_.@-]*) die "invalid locale '${LOCALE}'";;
esac
case "${KEYBOARD_LAYOUT}" in
  [a-z][a-z]) ;;
  *) die "invalid keyboard layout '${KEYBOARD_LAYOUT}' (two letters, eg. fr)";;
esac
case "${WIFI_COUNTRY}" in
  [A-Z][A-Z]) ;;
  *) die "invalid Wi-Fi country code '${WIFI_COUNTRY}' (two capital letters, eg. FR)";;
esac
# The URL ends up in dietpi.txt and on a command line of DietPi: no blank, quote, backslash, $ or backtick
case "${KIOSK_URL}" in
  "") ;;
  http://?*|https://?*|file:///?*)
    case "${KIOSK_URL}" in
      *[[:space:]\'\"\\\$\`]*) die "invalid URL '${KIOSK_URL}' (no blank, quote, backslash, \$ or backtick, use %20 for a space)";;
    esac;;
  *) die "invalid URL '${KIOSK_URL}' (http://, https:// or file:///)";;
esac
if [ -z "${BUTTONS}" ]; then if [ -n "${KIOSK_URL}" ]; then BUTTONS="on"; else BUTTONS="off"; fi; fi
case "${BUTTONS}" in
  on|off) ;;
  *) die "invalid -F '${BUTTONS}' (on or off)";;
esac
if [ -z "${SPLASH}" ]; then if [ -n "${KIOSK_URL}" ]; then SPLASH="on"; else SPLASH="off"; fi; fi
case "${SPLASH}" in
  on|off) ;;
  *) die "invalid -s '${SPLASH}' (on or off)";;
esac
case "${SSH_SERVER}" in
  dropbear|openssh) ;;
  *) die "unknown SSH server '${SSH_SERVER}' (dropbear or openssh)";;
esac
case "${PENIRQ_GPIO}" in
  none) ;;
  ''|*[!0-9]*) die "invalid GPIO '${PENIRQ_GPIO}'";;
esac
case "${TOUCH_PMAX}" in
  ''|*[!0-9]*) die "-P expects a number";;
esac
if [ "${TOUCH_PMAX}" -lt 100 ] || [ "${TOUCH_PMAX}" -gt 65535 ]; then die "-P must be between 100 and 65535"; fi
case "${ROTATE}" in
  normal|left|right|inverted) ;;
  *) die "-R expects normal, left, right or inverted";;
esac
# Turning the screen by a quarter turn swaps the touch axes against it once more. The calibrator works the
# inversions out by itself, but not the swap (see touch-calibrate).
# fbtft rotation of the PiTFT
case "${ROTATE}" in
  normal) PITFT_ROTATE=0;;
  right) PITFT_ROTATE=90;;
  inverted) PITFT_ROTATE=180;;
  left) PITFT_ROTATE=270;;
esac
PORTRAIT="false"
KIOSK_W="${P_SCREEN_W}"; KIOSK_H="${P_SCREEN_H}"
case "${ROTATE}" in
  left|right) PORTRAIT="true"; KIOSK_W="${P_SCREEN_H}"; KIOSK_H="${P_SCREEN_W}";;
esac
if [ -z "${TOUCH_SWAP}" ]; then
  TOUCH_SWAP="${P_TOUCH_SWAP}"
  if [ "${PORTRAIT}" = "true" ]; then
    if [ "${TOUCH_SWAP}" = "on" ]; then TOUCH_SWAP="off"; else TOUCH_SWAP="on"; fi
  fi
fi
case "${TOUCH_SWAP}" in
  on|off) ;;
  *) die "-X expects on or off";;
esac
case "${GYRO_SENSOR}" in
  mpu6050|none) ;;
  *) die "unknown gyroscope '${GYRO_SENSOR}'";;
esac
case "${PRESSURE_SENSOR}" in
  bmp180|bme280|none) ;;
  *) die "unknown pressure sensor '${PRESSURE_SENSOR}'";;
esac
case "${CAMERA}" in
  on|off) ;;
  *) die "-C expects on or off";;
esac
if [ -n "${WPA_FILE}" ]; then [ -r "${WPA_FILE}" ] || die "cannot read ${WPA_FILE}"; fi
[ -e "${TARGET}" ] || die "${TARGET} not found"

if [ "${GYRO_SENSOR}" = "none" ] && [ "${PRESSURE_SENSOR}" = "none" ]; then I2C="off"; else I2C="on"; fi
if [ "${SCREEN_KIND}" = "pitft28" ] || [ "${PENIRQ_GPIO}" != "none" ]; then TOUCH="on"; else TOUCH="off"; fi
# Name of the touch device in the X input classes
if [ "${SCREEN_KIND}" = "pitft28" ]; then TOUCH_MATCH="stmpe-ts"; else TOUCH_MATCH="ADS7846 Touchscreen"; fi
if [ "${I2C}" = "on" ]; then APT_INSTALLS="${APT_INSTALLS} i2c-tools"; fi
if [ "${CAMERA}" = "on" ]; then APT_INSTALLS="${APT_INSTALLS} v4l-utils rpicam-apps-lite"; fi
# Fonts for web pages in the kiosk: the base image has hardly any (Noto covers most scripts, no CJK: it weighs 89 MB)
if [ -n "${KIOSK_URL}" ]; then APT_INSTALLS="${APT_INSTALLS} fonts-noto-core fonts-noto-color-emoji fonts-liberation fonts-dejavu"; fi
# The long press on the reload button powers off: it listens to the key events
if [ "${BUTTONS}" = "on" ]; then APT_INSTALLS="${APT_INSTALLS} evtest"; fi
# Touch calibration, needs an X session (see the comment of the ads7846 line in config.txt)
# (xinput_calibrator only calibrates devices of the evdev X driver, not the libinput one X takes by default)
if [ "${TOUCH}" = "on" ]; then APT_INSTALLS="${APT_INSTALLS} xinput-calibrator xserver-xorg-input-evdev"; fi
# The PiTFT is a framebuffer (fbtft) that X draws on with the fbdev driver
if [ "${SCREEN_KIND}" = "pitft28" ]; then APT_INSTALLS="${APT_INSTALLS} xserver-xorg-video-fbdev fbset"; fi

# Splash screen: the picture is the content of the framebuffer, made by splash/make-splash.py
if [ "${SPLASH}" = "on" ]; then
  SPLASH_DIR="$(cd "$(dirname "$0")" && pwd)/splash"
  if [ "${SCREEN_KIND}" = "pitft28" ]; then
    # fbtft turns the picture by itself: 240x320 for the rotations 0 and 180, 320x240 for the others
    case "${PITFT_ROTATE}" in 0|180) SPLASH_SIZE="240,320";; *) SPLASH_SIZE="320,240";; esac
    SPLASH_FILE="${SPLASH_DIR}/fpv-pitft-${SPLASH_SIZE%,*}x${SPLASH_SIZE#*,}.raw.gz"
    SPLASH_FB="/dev/fb1"; SPLASH_BPP=2
  else
    SPLASH_SIZE="${P_SCREEN_W},${P_SCREEN_H}"
    SPLASH_FILE="${SPLASH_DIR}/fpv-hdmi-${ROTATE}.raw.gz"
    SPLASH_FB="/dev/fb0"; SPLASH_BPP=2
  fi
  SPLASH_ANIM="${SPLASH_FILE%.raw.gz}-anim.raw.gz"
  [ -r "${SPLASH_FILE}" ] && [ -r "${SPLASH_ANIM}" ] && [ -r "${SPLASH_ANIM%.raw.gz}.txt" ] \
    || die "splash pictures ${SPLASH_FILE} not found (splash/make-splash.py builds them)"
  # first row, number of rows, frames, bytes per row of the animation
  SPLASH_ANIM_META="$(cat "${SPLASH_ANIM%.raw.gz}.txt")"
fi

# --- Root is needed to loop-mount and write to the card ---
if [ "$(id -u)" -ne 0 ]; then
  TARGET="$(realpath "${TARGET}")"
  set -- -B "${BOARD}" -H "${HOSTNAME_NEW}" -u "${USER_NAME}" -t "${TIMEZONE}" -l "${LOCALE}" \
    -K "${KEYBOARD_LAYOUT}" -c "${WIFI_COUNTRY}" -S "${SSH_SERVER}" -F "${BUTTONS}" -s "${SPLASH}" -T "${PENIRQ_GPIO}" -X "${TOUCH_SWAP}" -R "${ROTATE}" -P "${TOUCH_PMAX}" -D "${SCREEN_KIND}" -g "${GYRO_SENSOR}" -b "${PRESSURE_SENSOR}" \
    -C "${CAMERA}"
  if [ -n "${PASSWORD}" ]; then set -- "$@" -p "${PASSWORD}"; fi
  if [ -n "${KIOSK_URL}" ]; then set -- "$@" -U "${KIOSK_URL}"; fi
  if [ -n "${WPA_FILE}" ]; then set -- "$@" -w "$(realpath "${WPA_FILE}")"; else set -- "$@" -w none; fi
  IFS="${NL}"
  for src in ${KEY_SOURCES}; do
    case "${src}" in https://*) ;; *) src="$(realpath "${src}")";; esac
    set -- "$@" -k "${src}"
  done
  unset IFS
  exec sudo -- "$0" "$@" "${TARGET}"
fi

# --- Prepare the target ---
LOOP_DEV=""
MNT=""
WORK_DIR="$(mktemp -d)"
KEYS_FILE="${WORK_DIR}/authorized_keys"
: > "${KEYS_FILE}"
cleanup() {
  rm -rf "${WORK_DIR}"
  if [ -n "${MNT}" ]; then
    if mountpoint -q "${MNT}"; then umount "${MNT}" || info "Warning: cannot unmount ${MNT}"; fi
    rmdir "${MNT}" 2>/dev/null || true
  fi
  if [ -n "${LOOP_DEV}" ]; then losetup -d "${LOOP_DEV}" 2>/dev/null || true; fi
}
trap cleanup EXIT

# --- SSH public keys (checked before anything is decompressed or mounted) ---
# add_key SOURCE : append a key file or https URL to KEYS_FILE, fail if it is not a valid public key
add_key() {
  _one="${WORK_DIR}/one.pub"
  case "$1" in
    https://*) curl -fsSL --retry 3 --connect-timeout 5 -o "${_one}" "$1" || return 1;;
    *) cat "$1" > "${_one}" || return 1;;
  esac
  ssh-keygen -l -f "${_one}" >/dev/null 2>&1 || return 1
  { cat "${_one}"; echo; } | grep . >> "${KEYS_FILE}"
  info "SSH key from $1: $(ssh-keygen -l -f "${_one}" | cut -d' ' -f1-2,4 | tr '\n' ' ')"
}

if [ -n "${KEY_SOURCES}" ]; then
  IFS="${NL}"
  for src in ${KEY_SOURCES}; do add_key "${src}" || die "cannot get a valid SSH public key from ${src}"; done
  unset IFS
else
  for name in ${KEYS_DEFAULT}; do
    add_key "${KEYS_URL}/${name}" || info "Warning: no key from ${KEYS_URL}/${name}, skipped"
  done
fi
[ -s "${KEYS_FILE}" ] || die "no SSH public key available, refusing to build an image nobody can log into"
if grep -qx 'EOF_KEYS' "${KEYS_FILE}"; then die "unexpected line in the SSH keys"; fi

# --- Wi-Fi networks: SSID, key, key management of each network block of the wpa_supplicant.conf ---
WIFI_LIST="${WORK_DIR}/wifi.tsv"
if [ -n "${WPA_FILE}" ]; then
  awk '
    function unquote(v) { return (v ~ /^".*"$/) ? substr(v, 2, length(v) - 2) : v }
    /^[[:space:]]*network=\{/ { n++; ssid[n] = ""; psk[n] = ""; km[n] = "WPA-PSK"; inb = 1; next }
    inb && /^[[:space:]]*\}/ { inb = 0; next }
    inb {
      line = $0; sub(/^[[:space:]]+/, "", line)
      k = line; sub(/=.*/, "", k); v = line; sub(/^[^=]*=/, "", v)
      if (k == "ssid") ssid[n] = unquote(v); else if (k == "psk") psk[n] = unquote(v); else if (k == "key_mgmt") km[n] = v
    }
    END { for (i = 1; i <= n; i++) printf "%s\t%s\t%s\n", ssid[i], psk[i], km[i] }
  ' "${WPA_FILE}" > "${WIFI_LIST}"
  WIFI_COUNT="$(grep -c . "${WIFI_LIST}" || true)"
  [ "${WIFI_COUNT}" -ge 1 ] || die "${WPA_FILE} has no network block"
  # DietPi takes 5 networks at most: keep the first ones
  if [ "${WIFI_COUNT}" -gt 5 ]; then
    head -n 5 "${WIFI_LIST}" > "${WIFI_LIST}.5" && mv "${WIFI_LIST}.5" "${WIFI_LIST}"
    info "Warning: ${WPA_FILE} has ${WIFI_COUNT} networks, only the first 5 are used"
  fi
  if cut -f1 "${WIFI_LIST}" | grep -qx ''; then die "${WPA_FILE}: every network needs a quoted ssid"; fi
fi

if [ -z "${PASSWORD}" ]; then
  PASSWORD="$(tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 16)"
  PASSWORD_GENERATED="true"
else
  PASSWORD_GENERATED="false"
fi

case "${TARGET}" in
  *.img.xz)
    IMAGE="${TARGET%.img.xz}.custom.img"
    info "Decompressing ${TARGET##*/} to ${IMAGE##*/}"
    xz -dc "${TARGET}" > "${IMAGE}.tmp" || { rm -f "${IMAGE}.tmp"; die "decompression failed"; }
    chown --reference="${TARGET}" "${IMAGE}.tmp"
    mv -f "${IMAGE}.tmp" "${IMAGE}"
    ;;
  *) IMAGE="${TARGET}";;
esac

if [ -b "${IMAGE}" ]; then
  DEVICE="${IMAGE}"
  if lsblk -nro MOUNTPOINT "${DEVICE}" | grep -q .; then
    die "${DEVICE} has mounted partitions, unmount them first"
  fi
elif [ -f "${IMAGE}" ]; then
  LOOP_DEV="$(losetup -Pf --show "${IMAGE}")" || die "cannot attach ${IMAGE} to a loop device"
  DEVICE="${LOOP_DEV}"
  udevadm settle 2>/dev/null || sleep 1
else
  die "${IMAGE} is neither a file nor a block device"
fi

# --- Find and mount the boot partition (FAT, holds config.txt) ---
MNT="$(mktemp -d "/tmp/${BOARD}-boot.XXXXXX")"
BOOT_FOUND="false"
for part in $(lsblk -nlo PATH,TYPE "${DEVICE}" | awk '$2 == "part" {print $1}'); do
  if mount -t vfat "${part}" "${MNT}" 2>/dev/null; then
    if [ -f "${MNT}/config.txt" ]; then BOOT_FOUND="true"; info "Boot partition: ${part}"; break; fi
    umount "${MNT}"
  fi
done
[ "${BOOT_FOUND}" = "true" ] || die "no Raspberry Pi boot partition found on ${DEVICE}"
DTB_FOUND="false"
for dtb in ${P_DTBS}; do
  if [ -f "${MNT}/${dtb}" ]; then DTB_FOUND="true"; fi
done
[ "${DTB_FOUND}" = "true" ] || die "this image does not support the ${BOARD} board"
# DietPi moves dietpi.txt off the boot partition on first boot: past that point this script cannot help
[ -f "${MNT}/dietpi.txt" ] || die "no dietpi.txt on the boot partition: not a DietPi image, or already booted once"

# set_line FILE PREFIX LINE [append] : replace the first line starting with PREFIX, commented out or not, by LINE.
# If there is none, LINE is appended with "append", else it is an error.
set_line() {
  _tmp="${WORK_DIR}/set_line"
  P="$2" L="$3" awk '
    BEGIN { p = ENVIRON["P"]; l = ENVIRON["L"] }
    !done { s = $0; sub(/^[[:blank:]#]*/, "", s); if (index(s, p) == 1) { print l; done = 1; next } }
    { print }
    END { exit !done }
  ' "$1" > "${_tmp}" && { cat "${_tmp}" > "$1"; return 0; }
  if [ "${4:-}" = "append" ]; then
    printf '%s\n' "$3" >> "$1"
  else
    die "${2} not found in ${1##*/}"
  fi
}

# --- dietpi.txt: unattended first run ---
DIETPI_TXT="${MNT}/dietpi.txt"
dietpi_set() { set_line "${DIETPI_TXT}" "$1=" "$1=$2"; }
dietpi_set AUTO_SETUP_AUTOMATED 1
dietpi_set AUTO_SETUP_GLOBAL_PASSWORD "${PASSWORD}"
dietpi_set AUTO_SETUP_LOCALE "${LOCALE}"
dietpi_set AUTO_SETUP_KEYBOARD_LAYOUT "${KEYBOARD_LAYOUT}"
dietpi_set AUTO_SETUP_TIMEZONE "${TIMEZONE}"
dietpi_set AUTO_SETUP_NET_HOSTNAME "${HOSTNAME_NEW}"
dietpi_set AUTO_SETUP_NET_ETHERNET_ENABLED 1
dietpi_set AUTO_SETUP_NET_WIFI_COUNTRY_CODE "${WIFI_COUNTRY}"
dietpi_set AUTO_SETUP_NET_USESTATIC 0
case "${SSH_SERVER}" in
  dropbear) dietpi_set AUTO_SETUP_SSH_SERVER_INDEX -1;;
  openssh) dietpi_set AUTO_SETUP_SSH_SERVER_INDEX -2;;
esac
# Key only logins: DietPi applies it to the SSH server it installs
dietpi_set SOFTWARE_DISABLE_SSH_PASSWORD_LOGINS 1
# The serial console is not wired, and enable_uart=1 caps the core clock on boards with onboard Wi-Fi
dietpi_set CONFIG_SERIAL_CONSOLE_ENABLE 0
dietpi_set SURVEY_OPTED_IN 0
dietpi_set AUTO_SETUP_APT_INSTALLS "${APT_INSTALLS}"
# Chromium kiosk at the resolution of the screen (the autostart mode 11 starts it on the first boot after the setup)
dietpi_set SOFTWARE_CHROMIUM_RES_X "${KIOSK_W}"
dietpi_set SOFTWARE_CHROMIUM_RES_Y "${KIOSK_H}"
if [ -n "${KIOSK_URL}" ]; then
  dietpi_set AUTO_SETUP_INSTALL_SOFTWARE_ID chromium
  dietpi_set AUTO_SETUP_AUTOSTART_TARGET_INDEX 11
  # The user exists since the PreScript, the kiosk runs as him (as root Chromium would need --no-sandbox)
  dietpi_set AUTO_SETUP_AUTOSTART_LOGIN_USER "${USER_NAME}"
  dietpi_set SOFTWARE_CHROMIUM_AUTOSTART_URL "${KIOSK_URL}"
  info "Kiosk: Chromium at boot on ${KIOSK_URL}"
fi
info "dietpi.txt: unattended first run, hostname ${HOSTNAME_NEW}, ${TIMEZONE}, ${LOCALE}, keyboard ${KEYBOARD_LAYOUT}, ${SSH_SERVER}"

# --- Wi-Fi (optional): DietPi writes wpa_supplicant.conf from dietpi-wifi.txt ---
if [ -n "${WPA_FILE}" ]; then
  [ -f "${MNT}/dietpi-wifi.txt" ] || die "no dietpi-wifi.txt on the boot partition"
  # Values are single-quoted in this file, which DietPi sources as a bash script: ' becomes '\''
  awk -F '\t' '
    function q(v,   parts, n, i, s) {
      n = split(v, parts, "\047"); s = parts[1]
      for (i = 2; i <= n; i++) s = s "\047\\\047\047" parts[i]
      return "\047" s "\047"
    }
    FNR == NR { n++; ssid[n - 1] = $1; key[n - 1] = $2; km[n - 1] = $3; next }
    match($0, /^aWIFI_(SSID|KEY|KEYMGR)\[[0-9]+\]=/) {
      head = substr($0, 1, RLENGTH); i = head; sub(/^[^[]*\[/, "", i); sub(/\].*/, "", i); i += 0
      if (i < n) {
        if (head ~ /^aWIFI_SSID/) { print head q(ssid[i]); next }
        if (head ~ /^aWIFI_KEY\[/) { print head q(key[i]); next }
        if (head ~ /^aWIFI_KEYMGR/) { print head q(km[i]); next }
      }
    }
    { print }
  ' "${WIFI_LIST}" "${MNT}/dietpi-wifi.txt" > "${WORK_DIR}/dietpi-wifi.txt"
  cat "${WORK_DIR}/dietpi-wifi.txt" > "${MNT}/dietpi-wifi.txt"
  dietpi_set AUTO_SETUP_NET_WIFI_ENABLED 1
  info "Wi-Fi: $(cut -f1 "${WIFI_LIST}" | tr '\n' ' ')(Ethernet preferred once set up)"
else
  dietpi_set AUTO_SETUP_NET_WIFI_ENABLED 0
fi

# --- config.txt: interfaces, camera, display ---
CONFIG_TXT="${MNT}/config.txt"
if [ "${I2C}" = "on" ]; then set_line "${CONFIG_TXT}" "dtparam=i2c_arm=" "dtparam=i2c_arm=on" append; fi
if [ "${TOUCH}" = "on" ]; then set_line "${CONFIG_TXT}" "dtparam=spi=" "dtparam=spi=on" append; fi
if [ "${CAMERA}" = "on" ]; then
  set_line "${CONFIG_TXT}" "camera_auto_detect=" "camera_auto_detect=1" append
  # The camera ISP and the codecs need the full firmware, which needs 64 MiB for the GPU (16 loads the cut-down one)
  set_line "${CONFIG_TXT}" "gpu_mem_1024=" "gpu_mem_1024=64" append
  set_line "${CONFIG_TXT}" "gpu_mem_512=" "gpu_mem_512=64" append
  set_line "${CONFIG_TXT}" "gpu_mem_256=" "gpu_mem_256=64" append
fi
if [ "${SCREEN_KIND}" = "hdmi" ]; then
  set_line "${CONFIG_TXT}" "dtoverlay=vc4-kms-v3d" "dtoverlay=vc4-kms-v3d,noaudio" append
  set_line "${CONFIG_TXT}" "hdmi_force_hotplug=" "hdmi_force_hotplug=1" append
  set_line "${CONFIG_TXT}" "hdmi_drive=" "hdmi_drive=1" append
else
  # No HDMI: KMS and the forced HDMI output would only take the framebuffer 0 and memory, switch them off
  sed -i -E 's/^(dtoverlay=vc4-f?kms-v3d|hdmi_force_hotplug=|hdmi_drive=)/#\1/' "${CONFIG_TXT}"
fi

# Lines of our block, which goes at the end, replacing the one of a previous run
if [ "${SCREEN_KIND}" = "pitft28" ]; then
  BLOCK="${MARK_BEGIN}: ${BOARD}, ${P_SCREEN_NAME}
# Display (ILI9341) on SPI0 CE0 as /dev/fb1 (fb0 is the one of the firmware), touch (STMPE610) on CE1, IRQ on GPIO24
dtoverlay=pitft28-resistive,rotate=${PITFT_ROTATE},speed=32000000,fps=30"
else
  BLOCK="${MARK_BEGIN}: ${BOARD}, ${P_SCREEN_NAME}
# ${P_SCREEN_W}x${P_SCREEN_H} for the firmware (the KMS driver takes video= from cmdline.txt)
hdmi_group=2
hdmi_mode=87
hdmi_cvt=${P_SCREEN_W} ${P_SCREEN_H} 60 6 0 0 0"
  if [ -n "${P_EXTRA_CONFIG}" ]; then BLOCK="${BLOCK}${NL}${P_EXTRA_CONFIG}"; fi
  if [ "${PENIRQ_GPIO}" != "none" ]; then
    BLOCK="${BLOCK}
# XPT2046 touch controller on SPI0 CE1, pen interrupt on GPIO${PENIRQ_GPIO} (fine calibration: xinput_calibrator)
dtoverlay=ads7846,cs=1,penirq=${PENIRQ_GPIO},penirq_pull=2,speed=50000,pmax=${TOUCH_PMAX},xohms=150,xmin=200,xmax=3900,ymin=200,ymax=3900"
  fi
fi
case "${GYRO_SENSOR}" in
  mpu6050) BLOCK="${BLOCK}
# MPU-6050 (GY-521) at 0x68, INT on GPIO4: shows up in /sys/bus/iio/devices
dtoverlay=i2c-sensor,mpu6050,int_pin=4";;
esac
case "${PRESSURE_SENSOR}" in
  bmp180) BLOCK="${BLOCK}
# BMP180 pressure/temperature sensor at 0x77
dtoverlay=i2c-sensor,bmp180";;
  bme280) BLOCK="${BLOCK}
# BME280 pressure/temperature/humidity sensor at 0x76
dtoverlay=i2c-sensor,bme280";;
esac
if [ "${BUTTONS}" = "on" ]; then
  BLOCK="${BLOCK}
# Push buttons between the GPIO and ground (internal pull-up) as keys the kiosk understands (same as the PiTFT 2.8\")
dtoverlay=gpio-key,gpio=23,active_low=1,gpio_pull=up,keycode=173,label=RELOAD
dtoverlay=gpio-key,gpio=22,active_low=1,gpio_pull=up,keycode=158,label=BACK
dtoverlay=gpio-key,gpio=27,active_low=1,gpio_pull=up,keycode=109,label=PAGEDOWN
dtoverlay=gpio-key,gpio=17,active_low=1,gpio_pull=up,keycode=172,label=HOME"
fi
BLOCK="${BLOCK}${NL}${MARK_END}"

awk -v b="${MARK_BEGIN}" -v e="${MARK_END}" 'index($0, b) == 1 {skip = 1} !skip {print} index($0, e) == 1 {skip = 0}' \
  "${CONFIG_TXT}" > "${WORK_DIR}/config.txt"
cat "${WORK_DIR}/config.txt" > "${CONFIG_TXT}"
printf '%s\n' "${BLOCK}" >> "${CONFIG_TXT}"
if [ "${BUTTONS}" = "on" ]; then info "Buttons: GPIO23 reload (long press: power off), GPIO22 back, GPIO27 page down, GPIO17 home"; fi
info "config.txt: screen ${SCREEN_KIND} ${P_SCREEN_W}x${P_SCREEN_H}, touch: ${PENIRQ_GPIO}, I2C: ${I2C} (gyro: ${GYRO_SENSOR}, pressure: ${PRESSURE_SENSOR}), camera: ${CAMERA}"
if [ "${ROTATE}" != "normal" ]; then info "Screen rotated: ${ROTATE} (kiosk ${KIOSK_W}x${KIOSK_H}, touch axes swapped: ${TOUCH_SWAP})"; fi

# --- cmdline.txt: screen mode for the KMS driver (single line file) ---
CMDLINE_TXT="${MNT}/cmdline.txt"
VIDEO_ARG="video=HDMI-A-1:${P_SCREEN_W}x${P_SCREEN_H}M@60"
if [ "${SCREEN_KIND}" = "pitft28" ]; then
  # The console goes to the PiTFT (fb1), in a font that fits a 240x320 screen
  sed -i '1s/ video=HDMI-A-1:[^[:space:]]*//' "${CMDLINE_TXT}"
  if ! grep -q 'fbcon=map:' "${CMDLINE_TXT}"; then sed -i '1s/[[:space:]]*$/ fbcon=map:10 fbcon=font:VGA8x8/' "${CMDLINE_TXT}"; fi
elif grep -q 'video=HDMI-A-1:' "${CMDLINE_TXT}"; then
  sed -i "1s/video=HDMI-A-1:[^[:space:]]*/${VIDEO_ARG}/" "${CMDLINE_TXT}"
else
  sed -i "1s/[[:space:]]*\$/ ${VIDEO_ARG}/" "${CMDLINE_TXT}"
fi

# --- First boot, before the network: user, SSH, kernel modules ---
PRESCRIPT="${MNT}/Automation_Custom_PreScript.sh"
{
  printf '#!/bin/bash\n'
  printf '# Generated by DietPi_Customize.sh: run once by DietPi on first boot, before the network is up\n'
  printf "BOARD='%s'\n" "${BOARD}"
  printf "USER_NAME='%s'\n" "${USER_NAME}"
  printf "USER_GROUPS='%s'\n" "${USER_GROUPS}"
  printf "SSH_SERVER='%s'\n" "${SSH_SERVER}"
  printf "CAMERA='%s'\n" "${CAMERA}"
  printf "I2C='%s'\n" "${I2C}"
  printf "TOUCH='%s'\n" "${TOUCH}"
  printf "BUTTONS='%s'\n" "${BUTTONS}"
  printf "KIOSK_URL='%s'\n" "${KIOSK_URL}"
  printf "TOUCH_MATCH='%s'\n" "${TOUCH_MATCH}"
  printf "SCREEN_KIND='%s'\n" "${SCREEN_KIND}"
  printf "TOUCH_SWAP='%s'\n" "${TOUCH_SWAP}"
  printf "SCREEN_ROTATE='%s'\n" "${ROTATE}"
  printf "SCREEN_MODE='%sx%s'\n" "${P_SCREEN_W}" "${P_SCREEN_H}"
  printf "SCREEN_MODELINE='%s'\n" "${P_MODELINE}"
  printf "read -r -d '' AUTHORIZED_KEYS <<'EOF_KEYS'\n"
  cat "${KEYS_FILE}"
  printf 'EOF_KEYS\n'
  cat <<'EOF'
log() { echo "${BOARD}-prescript: $*"; }

# User, with the same password as root and dietpi for console logins (SSH takes keys only)
if ! id "${USER_NAME}" >/dev/null 2>&1; then
  groups=""
  for g in ${USER_GROUPS}; do
    if getent group "${g}" >/dev/null; then groups="${groups:+${groups},}${g}"; fi
  done
  useradd --create-home --shell /bin/bash --user-group --groups "${groups}" --comment "${USER_NAME}" "${USER_NAME}"
  log "user ${USER_NAME} created (groups: ${groups})"
fi
password="$(sed -n '/^[[:blank:]]*AUTO_SETUP_GLOBAL_PASSWORD=/{s/^[^=]*=//p;q}' /boot/dietpi.txt)"
if [ -n "${password}" ]; then printf '%s:%s\n' "${USER_NAME}" "${password}" | chpasswd; fi
unset password

home="$(getent passwd "${USER_NAME}" | cut -d: -f6)"
install -d -m 700 -o "${USER_NAME}" -g "${USER_NAME}" "${home}/.ssh"
printf '%s\n' "${AUTHORIZED_KEYS}" > "${home}/.ssh/authorized_keys"
chown "${USER_NAME}:${USER_NAME}" "${home}/.ssh/authorized_keys"
chmod 600 "${home}/.ssh/authorized_keys"
log "$(grep -c . "${home}/.ssh/authorized_keys") SSH key(s) installed for ${USER_NAME}"

printf '%s ALL=(ALL) NOPASSWD:ALL\n' "${USER_NAME}" > "/etc/sudoers.d/90-${USER_NAME}"
chmod 440 "/etc/sudoers.d/90-${USER_NAME}"

# OpenSSH is installed later in the first run, its sshd_config includes sshd_config.d first, first value wins
# (Dropbear has no such file: DietPi turns password logins off for it, root has no key)
if [ "${SSH_SERVER}" = "openssh" ]; then
  mkdir -p /etc/ssh/sshd_config.d
  printf 'PasswordAuthentication no\nPermitRootLogin no\n' > "/etc/ssh/sshd_config.d/10-${BOARD}.conf"
fi

# DietPi blacklists the camera, ISP, codec and VideoCore shared memory drivers: the camera needs them all
if [ "${CAMERA}" = "on" ]; then
  rm -f /etc/modprobe.d/dietpi-disable_rpi_camera.conf /etc/modprobe.d/dietpi-disable_rpi_codec.conf \
    /etc/modprobe.d/dietpi-disable_vcsm.conf
  log "camera drivers unblocked"
fi
# X takes the first mode of the screen, which is not always the one of the panel (1024x768 for a 1024x600 one):
# the picture is then cut and the touch is off. Force the mode of the panel.
mkdir -p /etc/X11/xorg.conf.d
if [ "${SCREEN_KIND}" = "hdmi" ]; then
  {
    echo 'Section "Monitor"'
    echo '    Identifier "HDMI-1"'
    if [ -n "${SCREEN_MODELINE}" ]; then echo "    Modeline ${SCREEN_MODELINE}"; fi
    echo "    Option \"PreferredMode\" \"${SCREEN_MODE}\""
    if [ "${SCREEN_ROTATE}" != "normal" ]; then echo "    Option \"Rotate\" \"${SCREEN_ROTATE}\""; fi
    echo 'EndSection'
  } > /etc/X11/xorg.conf.d/10-monitor.conf
  log "X mode ${SCREEN_MODE}, rotation ${SCREEN_ROTATE}"
else
  # The PiTFT is /dev/fb1 (fb0 is the one of the firmware): X draws on it with the fbdev driver. The driver of
  # its touch controller is not loaded by itself.
  cat > /etc/X11/xorg.conf.d/20-pitft-fbdev.conf <<'EOF_FBDEV'
Section "Device"
    Identifier "PiTFT"
    Driver "fbdev"
    Option "fbdev" "/dev/fb1"
EndSection
EOF_FBDEV
  echo stmpe_ts > /etc/modules-load.d/pitft.conf
  log "PiTFT: X on /dev/fb1, touch driver stmpe_ts"
fi
# Touchscreen calibration: touch-calibrate.service runs it in a bare X session before the graphical one (Chromium
# kiosk, desktop) until it is done, the next X session then reads the result from /etc/X11/xorg.conf.d
if [ "${TOUCH}" = "on" ]; then
  cat > /usr/local/sbin/touch-calibrate <<'EOF_CAL'
#!/bin/sh
# Calibrate the touchscreen once, in a bare X session started before the graphical one: the result goes to a
# xorg.conf.d file that the next X session reads. Run at boot by touch-calibrate.service, until it is done
# (3 tries at most, each one waits 60 seconds for the touches, long enough to look at the screen at boot).
# To calibrate again: rm /etc/X11/xorg.conf.d/99-calibration.conf /var/lib/touch-calibrate/tries; reboot
set -eu
CONF="/etc/X11/xorg.conf.d/99-calibration.conf"
SWAP_CONF="/etc/X11/xorg.conf.d/51-touchscreen-swap.conf"
STATE="/var/lib/touch-calibrate"
MAX_TRIES=3
WAIT=60
log() { echo "touch-calibrate: $*"; }

[ ! -f "${CONF}" ] || exit 0
TRIES="$(cat "${STATE}/tries" 2>/dev/null || echo 0)"
[ "${TRIES}" -lt "${MAX_TRIES}" ] || { log "gave up after ${MAX_TRIES} tries (rm ${STATE}/tries to try again)"; exit 0; }
# The touch controller: ADS7846 (XPT2046 of the HDMI screens) or STMPE (Adafruit PiTFT)
TOUCH_NAME="$(sed -n 's/^N: Name="\(ADS7846 Touchscreen\|stmpe-ts\)"$/\1/p' /proc/bus/input/devices | head -1)"
[ -n "${TOUCH_NAME}" ] || { log "no touch controller found"; exit 0; }
command -v xinput_calibrator >/dev/null && command -v xinit >/dev/null || { log "xinput_calibrator or xinit missing"; exit 0; }

mkdir -p "${STATE}"
echo $((TRIES + 1)) > "${STATE}/tries"
OUT="$(mktemp)"
trap 'rm -f "${OUT}" "${OUT}.conf"' EXIT

# run_calibrator : leaves the snippet of the calibrator in ${OUT}.conf, empty if nothing was calibrated
run_calibrator() {
  timeout -k 5 "${WAIT}" xinit /usr/bin/xinput_calibrator --no-timeout --output-type xorg.conf.d -- :0 vt1 > "${OUT}" || true
  cat "${OUT}"
  sed -n '/^Section "InputClass"/,/^EndSection/p' "${OUT}" > "${OUT}.conf"
}
# is_degenerate FILE : the calibration has (almost) no range on an axis. The calibrator does that when the touch
# axes are swapped against the screen: it notices it, but averages the clicks before swapping them.
is_degenerate() {
  awk -F'"' '/Option[[:space:]]+"Calibration"/ { split($4, v, " "); a = v[1] - v[2]; b = v[3] - v[4]
    if (a < 0) a = -a; if (b < 0) b = -b; found = 1; bad = (a < 300 || b < 300) } END { exit !(found && bad) }' "$1"
}

log "try $((TRIES + 1)) of ${MAX_TRIES}"
run_calibrator
if [ -s "${OUT}.conf" ] && is_degenerate "${OUT}.conf" && [ ! -f "${SWAP_CONF}" ]; then
  log "touch axes look swapped against the screen, calibrating again with them swapped"
  cat > "${SWAP_CONF}" <<EOF_SWAP
# The touch axes are swapped against the screen
Section "InputClass"
    Identifier "touch swap"
    MatchProduct "${TOUCH_NAME}"
    MatchDriver "evdev"
    Option "SwapAxes" "1"
EndSection
EOF_SWAP
  run_calibrator
  if [ ! -s "${OUT}.conf" ] || is_degenerate "${OUT}.conf"; then rm -f "${SWAP_CONF}"; fi
fi
[ -s "${OUT}.conf" ] || { log "no calibration done"; exit 0; }
if is_degenerate "${OUT}.conf"; then log "calibration looks wrong (no range on an axis), not saved"; exit 0; fi
mkdir -p "$(dirname "${CONF}")"
install -m 644 "${OUT}.conf" "${CONF}"
rm -rf "${STATE}"
log "calibration saved to ${CONF}"
EOF_CAL
  chmod 755 /usr/local/sbin/touch-calibrate
  cat > /etc/X11/xorg.conf.d/50-touchscreen-evdev.conf <<EOF_EVDEV
# The touchscreen is handled by the evdev driver: xinput_calibrator can only calibrate this one
Section "InputClass"
    Identifier "touch evdev"
    MatchProduct "${TOUCH_MATCH}"
    MatchDevicePath "/dev/input/event*"
    Driver "evdev"
EndSection
EOF_EVDEV
  cat > /etc/systemd/system/touch-calibrate.service <<'EOF_UNIT'
[Unit]
Description=Touchscreen calibration before the graphical session
ConditionPathExists=!/etc/X11/xorg.conf.d/99-calibration.conf
ConditionPathExists=/usr/bin/xinput_calibrator
After=local-fs.target systemd-udevd.service
Before=getty@tty1.service display-manager.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/touch-calibrate
StandardInput=tty-force
StandardOutput=journal
StandardError=journal
TTYPath=/dev/tty1
TTYReset=yes
TTYVHangup=yes
TimeoutStartSec=150

[Install]
WantedBy=multi-user.target
EOF_UNIT
  if [ "${TOUCH_SWAP}" = "on" ]; then
    cat > /etc/X11/xorg.conf.d/51-touchscreen-swap.conf <<EOF_SWAPCONF
# The touch axes are swapped against the screen
Section "InputClass"
    Identifier "touch swap"
    MatchProduct "${TOUCH_MATCH}"
    MatchDriver "evdev"
    Option "SwapAxes" "1"
EndSection
EOF_SWAPCONF
  fi
  mkdir -p /etc/systemd/system/multi-user.target.wants
  ln -sf /etc/systemd/system/touch-calibrate.service /etc/systemd/system/multi-user.target.wants/touch-calibrate.service
  log "touch calibration before the first graphical session"
fi
# Buttons: gpio-key makes keys of them (config.txt), X must read those devices with the evdev driver. The Home key
# of Chromium opens the home page of its settings (Google by default): the managed policy sets the one of the kiosk.
if [ "${BUTTONS}" = "on" ]; then
  cat > /etc/X11/xorg.conf.d/60-gpio-buttons.conf <<'EOF_BTN'
Section "InputClass"
    Identifier "gpio buttons"
    MatchProduct "gpio_keys|gpio-keys|button@"
    MatchDevicePath "/dev/input/event*"
    Driver "evdev"
EndSection
EOF_BTN
  if [ -n "${KIOSK_URL}" ]; then
    mkdir -p /etc/chromium/policies/managed
    printf '{"HomepageLocation":"%s","HomepageIsNewTabPage":false}\n' "${KIOSK_URL}" > /etc/chromium/policies/managed/kiosk-home.json
  fi
  # Long press (3 s) on the reload button (GPIO23): power off. The short press still reloads the page: Chromium
  # reads the same key events, this only listens. (systemctl poweroff fails on DietPi: /sbin/poweroff)
  cat > /usr/local/sbin/button-poweroff <<'EOF_POFF'
#!/bin/bash
# Long press on a gpio-key button => poweroff. Usage: button-poweroff GPIO [SECONDS]
GPIO=${1:?GPIO}; HOLD=${2:-3}
NAME=$(printf 'button@%x' "$GPIO")
DEV=$(awk -v n="N: Name=\"$NAME\"" '$0==n{f=1} f&&/Handlers/{for(i=1;i<=NF;i++)if($i~/^event/){print "/dev/input/"$i;exit}}' /proc/bus/input/devices)
[ -n "$DEV" ] || { echo "$NAME not found" >&2; exit 1; }
start=
evtest "$DEV" | while true; do
  if read -r -t 0.2 line; then
    case $line in
      *"(EV_KEY)"*"value 1") start=$EPOCHREALTIME ;;
      *"(EV_KEY)"*"value 0") start= ;;
    esac
  elif [ $? -le 128 ]; then exit 1   # end of the evtest stream
  fi
  if [ -n "$start" ] && awk -v a="$start" -v b="$EPOCHREALTIME" -v h="$HOLD" 'BEGIN{exit !(b-a>=h)}'; then
    logger -t button-poweroff "long press on $NAME: poweroff"
    exec /sbin/poweroff
  fi
done
EOF_POFF
  chmod 755 /usr/local/sbin/button-poweroff
  cat > /etc/systemd/system/button-poweroff.service <<'EOF_UNIT'
[Unit]
Description=Long press on the reload button powers off

[Service]
ExecStart=/usr/local/sbin/button-poweroff 23 3
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF_UNIT
  mkdir -p /etc/systemd/system/multi-user.target.wants
  ln -sf /etc/systemd/system/button-poweroff.service /etc/systemd/system/multi-user.target.wants/button-poweroff.service
  log "buttons: X config, kiosk home page, long press power off"
fi
# /dev/i2c-1 for i2cdetect and user space access
if [ "${I2C}" = "on" ]; then
  printf 'i2c-dev\n' > "/etc/modules-load.d/${BOARD}-i2c.conf"
  log "i2c-dev loaded at boot"
fi
EOF
} > "${PRESCRIPT}"
info "Automation_Custom_PreScript.sh: user ${USER_NAME}, $(grep -c . "${KEYS_FILE}") SSH key(s), SSH keys only"

# --- End of the first run (network up, software installed) ---
# - Wi-Fi: on first boot DietPi only sets up Wi-Fi when it is enabled (Ethernet is the fallback): enable both,
#   Ethernet preferred thanks to a lower route metric.
# - PiTFT: installing X software makes DietPi switch the KMS driver on again, which takes the framebuffer numbers
#   the X configuration relies on (the PiTFT must stay /dev/fb1): switch it off.
POSTSCRIPT="${MNT}/Automation_Custom_Script.sh"
if [ -n "${WPA_FILE}" ] || [ "${SCREEN_KIND}" = "pitft28" ] || [ "${SPLASH}" = "on" ]; then
  cat > "${POSTSCRIPT}" <<'EOF'
#!/bin/bash
# Generated by DietPi_Customize.sh: run once by DietPi at the end of the first run setup
log() { echo "dietpi-postscript: $*"; }
EOF
  if [ -n "${WPA_FILE}" ]; then
    cat >> "${POSTSCRIPT}" <<'EOF'

restart_eth="false"
for iface in eth0 wlan0; do
  if ! grep -q "^allow-hotplug ${iface}\$" "/etc/network/interfaces.d/${iface}.conf" 2>/dev/null; then
    /boot/dietpi/dietpi-network apply "${iface}" --enable --dhcp --force --no-restart || log "cannot enable ${iface}"
    [ "${iface}" = "eth0" ] && restart_eth="true"
  fi
done

# set_metric IFACE METRIC : route metric of a DHCP interface (passed to dhclient by ifupdown)
set_metric() {
  local conf="/etc/network/interfaces.d/$1.conf"
  [ -f "${conf}" ] || return 0
  sed -i "/^[[:blank:]]*metric[[:blank:]]/d; /^iface $1 inet dhcp\$/a metric $2" "${conf}"
}
set_metric eth0 100
set_metric wlan0 600

# Bring Ethernet up now if it was just enabled, Wi-Fi keeps running (it may carry the current SSH session)
if [ "${restart_eth}" = "true" ] && [ -e /sys/class/net/eth0 ]; then systemctl restart ifup@eth0 || true; fi
log "Ethernet and Wi-Fi enabled, Ethernet preferred (metrics fully applied after the next reboot)"
EOF
    info "Automation_Custom_Script.sh: Ethernet and Wi-Fi both enabled"
  fi
  if [ "${SCREEN_KIND}" = "pitft28" ]; then
    cat >> "${POSTSCRIPT}" <<'EOF'

sed -i -E 's/^(dtoverlay=vc4-f?kms-v3d)/#\1/' /boot/firmware/config.txt
log "KMS switched off again, the PiTFT stays /dev/fb1"
EOF
    info "Automation_Custom_Script.sh: KMS switched off after the installs (PiTFT)"
  fi
  if [ "${SPLASH}" = "on" ]; then
    # Not before the end of the first run: its messages must stay visible. The picture is written to the framebuffer by
    # a service as early as the device is there (the PiTFT shows up a few seconds after the start of the kernel).
    {
      printf "\nSPLASH_FB='%s'; SPLASH_SIZE='%s'; SPLASH_BPP='%s'; SPLASH_ANIM='%s'; SPLASH_USER='%s'\n" \
        "${SPLASH_FB}" "${SPLASH_SIZE}" "${SPLASH_BPP}" "${SPLASH_ANIM_META}" "${USER_NAME}"
      printf "base64 -d > /usr/local/share/boot-splash.raw.gz <<'EOF_PIC'\n"
      base64 "${SPLASH_FILE}"
      printf 'EOF_PIC\n'
      printf "base64 -d > /usr/local/share/boot-splash-anim.raw.gz <<'EOF_ANIM'\n"
      base64 "${SPLASH_ANIM}"
      printf 'EOF_ANIM\n'
      cat <<'EOF'
cat > /usr/local/sbin/boot-splash <<'EOF_SPL'
#!/bin/sh
# boot-splash FRAMEBUFFER WIDTH,HEIGHT BYTES_PER_PIXEL FILE.gz [ANIM.gz FIRST_ROW ROWS FRAMES BYTES_PER_ROW]
# Show a picture made for this framebuffer, then animate some rows of it until X starts. With KMS the framebuffer
# of the firmware comes first and is replaced by the one of the driver a few seconds later, and the console clears
# the screen as it takes over: the whole picture is drawn again when it is gone.
FB=$1; SIZE=$2; BPP=$3; FILE=$4
N=${FB##*/}
G=/sys/class/graphics/${N}
# Is the framebuffer the one the picture was made for (size, no padding on the lines)?
fb_ok() {
  [ -w "${FB}" ] && [ "$(cat "${G}/virtual_size" 2>/dev/null)" = "${SIZE}" ] \
    && [ "$(cat "${G}/stride" 2>/dev/null)" = "$(( ${SIZE%,*} * BPP ))" ]
}
i=0
while ! fb_ok && [ "${i}" -lt 300 ]; do sleep 0.1; i=$((i + 1)); done
fb_ok || { logger -t boot-splash "framebuffer ${FB} is not ${SIZE} at ${BPP} bytes per pixel, no splash"; exit 0; }
BASE=/run/boot-splash.base
zcat "${FILE}" > "${BASE}" || exit 0
draw() { dd if="${BASE}" of="${FB}" bs=64k 2>/dev/null; DRV=$(cat "${G}/name"); }
# Is the picture still there? One line of the top of the screen (the animation is further down)
LINE=$(( 10 * ${SIZE%,*} * BPP ))
still_there() { cmp -s -n "$(( ${SIZE%,*} * BPP ))" -i "${LINE}:${LINE}" "${FB}" "${BASE}"; }
draw
[ -n "$5" ] || exit 0
ANIM=$5; ROW0=$6; ROWS=$7; FRAMES=$8; RB=$9
TMP=/run/boot-splash.frames
zcat "${ANIM}" > "${TMP}" || exit 0
f=0; n=0
# 3 pictures a second (the CPU is busy booting), for 10 minutes at most
while [ ! -e /tmp/.X11-unix/X0 ] && [ "${n}" -lt 2000 ]; do
  if [ "$(cat "${G}/name")" != "${DRV}" ] || ! still_there; then
    # another driver took the framebuffer over, or the console cleared the screen as it took over: draw it all again
    fb_ok && draw
  else
    dd if="${TMP}" of="${FB}" bs="${RB}" skip=$((f * ROWS)) seek="${ROW0}" count="${ROWS}" 2>/dev/null
  fi
  f=$(( (f + 1) % FRAMES )); n=$((n + 1))
  sleep 0.3
done
rm -f "${TMP}" "${BASE}"
EOF_SPL
chmod 755 /usr/local/sbin/boot-splash
cat > /etc/systemd/system/boot-splash.service <<EOF_UNIT
[Unit]
Description=Boot splash screen
DefaultDependencies=no
Before=sysinit.target shutdown.target
Conflicts=shutdown.target

[Service]
ExecStart=/usr/local/sbin/boot-splash ${SPLASH_FB} ${SPLASH_SIZE} ${SPLASH_BPP} /usr/local/share/boot-splash.raw.gz /usr/local/share/boot-splash-anim.raw.gz ${SPLASH_ANIM}

[Install]
WantedBy=sysinit.target
EOF_UNIT
mkdir -p /etc/systemd/system/sysinit.target.wants
ln -sf /etc/systemd/system/boot-splash.service /etc/systemd/system/sysinit.target.wants/boot-splash.service
# Quiet boot from now on: no kernel messages (DietPi sets kernel.printk to 4, a later file wins), no cursor, no
# firmware rainbow; the DietPi boot services must not write to the console either
if ! grep -q '\bquiet\b' /boot/firmware/cmdline.txt; then
  sed -i '1s/[[:space:]]*$/ quiet loglevel=3 logo.nologo vt.global_cursor_default=0/' /boot/firmware/cmdline.txt
fi
grep -q '^disable_splash=' /boot/firmware/config.txt || echo 'disable_splash=1' >> /boot/firmware/config.txt
echo 'kernel.printk = 3 3 1 3' > /etc/sysctl.d/98-quiet.conf
for u in dietpi-preboot dietpi-postboot; do
  mkdir -p "/etc/systemd/system/${u}.service.d"
  printf '[Service]\nStandardOutput=journal\n' > "/etc/systemd/system/${u}.service.d/quiet.conf"
done
# The autologin must not clear the console (systemd resets it before the getty, which also writes a message), and
# neither the login banner, X nor Chromium must write to it
mkdir -p /etc/systemd/system/getty@tty1.service.d
cat > /etc/systemd/system/getty@tty1.service.d/zz-quiet.conf <<EOF_GETTY
[Service]
TTYReset=no
TTYVHangup=no
TTYVTDisallocate=no
ExecStart=
ExecStart=-/sbin/agetty --noissue --noclear --nohostname --skip-login -o "-f ${SPLASH_USER}" %I \$TERM
EOF_GETTY
user_home="$(getent passwd "${SPLASH_USER}" | cut -d: -f6)"
if [ -d "${user_home}" ]; then
  touch "${user_home}/.hushlogin"
  printf '#!/bin/sh\n# X server of startx: its messages would show over the boot splash\nexec /usr/bin/X -nolisten tcp "$@" >/dev/null 2>&1\n' > "${user_home}/.xserverrc"
  chmod 755 "${user_home}/.xserverrc"
  chown "${SPLASH_USER}:${SPLASH_USER}" "${user_home}/.hushlogin" "${user_home}/.xserverrc"
fi
mkdir -p /etc/chromium.d
printf '# no output on the console (it would show over the boot splash)\nexec >/dev/null 2>&1\n' > /etc/chromium.d/zz-quiet-console
log "boot splash and quiet boot set up for the next boots"
EOF
    } >> "${POSTSCRIPT}"
    info "Automation_Custom_Script.sh: quiet boot and splash from the second boot on"
  fi
else
  rm -f "${POSTSCRIPT}"
fi

sync
info "Done: ${IMAGE}"
info "SSH: ssh ${USER_NAME}@${HOSTNAME_NEW}.local once the first run is over (a few minutes, the board updates itself)"
if [ "${PASSWORD_GENERATED}" = "true" ]; then
  info "Console password of root, dietpi and ${USER_NAME}: ${PASSWORD}"
fi
