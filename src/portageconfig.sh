#!/bin/sh
GENTOO_ROOTDIR="${GENTOO_ROOTDIR:-/mnt/gentoo}"

#VIDEO_CARDS_VIVOBOOK="amdgpu radeonsi"
#VIDEO_CARDS_NSNOVO="intel"
VIDEO_CARDS="intel"
INPUT_DEVICES="libinput evdev joystick"

cat > "${GENTOO_ROOTDIR}/etc/portage/make.conf" << EOF
# Please consult /usr/share/portage/config/make.conf.example for a more
# detailed example.
COMMON_FLAGS="-O2 -pipe -march=native"
CFLAGS="\${COMMON_FLAGS}"
CXXFLAGS="\${COMMON_FLAGS}"
FCFLAGS="\${COMMON_FLAGS}"
FFLAGS="\${COMMON_FLAGS}"
RUSTFLAGS="\${RUSTFLAGS} -C target-cpu=native"

MAKEOPTS="-j$(nproc) -l$(expr $(nproc) + 1)"
FEATURES="\${FEATURES} getbinpkg binpkg-request-signature candy parallel-fetch"
VIDEO_CARDS="${VIDEO_CARDS}"
INPUT_DEVICES="${INPUT_DEVICES}"

USE="bindist dist-kernel lvm"

ACCEPT_LICENSE="-* @FREE @BINARY-REDISTRIBUTABLE"

# NOTE: This stage was built with the bindist USE flag enabled

# This sets the language of build output to English.
# Please keep this setting intact when reporting bugs.
LC_MESSAGES=C.utf8
EOF

