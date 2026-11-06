#!/bin/sh
# Download a DietPi image for a Raspberry Pi (2 or 3B), check its SHA256 and optionally write it to a block device
set -eu
set -o pipefail 2>/dev/null || true

BASE_URL="https://dietpi.com/downloads/images"
BOARD=""
ARCH=""
RELEASE="trixie"
DOWNLOAD_DIR="$(dirname "$0")"
DRY_RUN="false"
VERBOSE="false"
BLOCK_DEVICE=""

usage() {
  exec >&2
  printf "Usage : %s -B BOARD [options] [device]\n" "$(basename "$0")"
  printf "  Download DietPi image for a Raspberry Pi\n"
  printf "  Optionally write it to specified device\n"
  printf "Options :\n"
  printf "  -B {rpi2|rpi3b}           : board, mandatory\n"
  printf "  -a {armv8|armv7}          : architecture, 64 or 32 bit (default: armv7 for rpi2, armv8 for rpi3b)\n"
  printf "                              (armv8 on rpi2 needs a v1.2 board)\n"
  printf "  -r {trixie|bookworm|forky} : Debian release (default: %s)\n" "${RELEASE}"
  printf "  -o DIR                    : download directory (default: script directory)\n"
  printf "  -n                        : dry run, only print the image URL\n"
  printf "  -v                        : be verbose\n"
  printf "  -h                        : display this help message\n"
  exit "${1:-1}"
}

log() { if [ "${VERBOSE}" = "true" ]; then printf '%s\n' "$*" >&2; fi; }
die() { printf 'Error: %s\n' "$*" >&2; exit 1; }

while getopts B:a:r:o:nvh opt; do case "${opt}" in
  B) BOARD="${OPTARG}";;
  a) ARCH="${OPTARG}";;
  r) RELEASE="${OPTARG}";;
  o) DOWNLOAD_DIR="${OPTARG}";;
  n) DRY_RUN=true;;
  v) VERBOSE=true;;
  h) usage 0;;
  *) usage;;
esac; done
shift $((OPTIND - 1))
BLOCK_DEVICE="${1:-}"

# --- Image selection (RPi 2 and 3 run the RPi2/3/4 32 bit image, the 3 and the v1.2 of the 2 the 64 bit one too) ---
case "${BOARD}" in
  rpi2) ARCH="${ARCH:-armv7}";;
  rpi3b) ARCH="${ARCH:-armv8}";;
  "") usage;;
  *) die "unknown board '${BOARD}'";;
esac
case "${ARCH}" in
  armv8) MODEL="RPi234-ARMv8";;
  armv7) MODEL="RPi2-ARMv7";;
  *) die "unknown architecture '${ARCH}'";;
esac
case "${RELEASE}" in
  trixie|bookworm|forky) ;;
  *) die "unknown release '${RELEASE}'";;
esac
# Bookworm -> Bookworm, the server uses capitalized release names
RELEASE_NAME="$(printf '%s' "${RELEASE}" | cut -c1 | tr a-z A-Z)$(printf '%s' "${RELEASE}" | cut -c2-)"
IMAGE_NAME="DietPi_${MODEL}-${RELEASE_NAME}.img.xz"
IMAGE_URL="${BASE_URL}/${IMAGE_NAME}"

log "Checking ${IMAGE_URL}"
curl -sfI -o /dev/null "${IMAGE_URL}" || die "no image available at ${IMAGE_URL}"

if [ "${DRY_RUN}" = "true" ]; then
  printf '%s\n' "${IMAGE_URL}"
  exit 0
fi

# --- Download and check ---
# The image names carry no version: a file already there may be an older build, the checksum tells
mkdir -p "${DOWNLOAD_DIR}"
IMAGE_PATH="${DOWNLOAD_DIR}/${IMAGE_NAME}"

log "Fetching checksum"
set -- $(curl -sfL "${IMAGE_URL}.sha256") || die "cannot fetch checksum"
IMAGE_SHA="${1:-}"
[ "${2:-}" = "${IMAGE_NAME}" ] || die "checksum file does not match ${IMAGE_NAME}"

# check_image FILE : true if FILE has the published checksum
check_image() {
  [ "$(sha256sum "$1" | cut -d' ' -f1)" = "${IMAGE_SHA}" ]
}

if [ -f "${IMAGE_PATH}" ] && check_image "${IMAGE_PATH}"; then
  log "${IMAGE_NAME} already downloaded and verified"
else
  if [ -f "${IMAGE_PATH}" ]; then
    printf '%s is outdated or damaged, downloading it again\n' "${IMAGE_NAME}" >&2
    rm -f "${IMAGE_PATH}"
  fi
  # Resume an interrupted download first, start over if the result is wrong (the .part was from an older build)
  for attempt in resume fresh; do
    if [ "${attempt}" = "fresh" ]; then
      [ -f "${IMAGE_PATH}.part" ] || break
      log "Checksum mismatch, starting the download over"
      rm -f "${IMAGE_PATH}.part"
    fi
    printf 'Downloading %s\n' "${IMAGE_NAME}" >&2
    curl -fL --progress-bar -C - -o "${IMAGE_PATH}.part" "${IMAGE_URL}" || die "download failed"
    if check_image "${IMAGE_PATH}.part"; then
      mv -f "${IMAGE_PATH}.part" "${IMAGE_PATH}"
      break
    fi
  done
  [ -f "${IMAGE_PATH}" ] || { rm -f "${IMAGE_PATH}.part"; die "checksum mismatch, image removed"; }
  log "Checksum OK"
fi
printf '%s\n' "${IMAGE_PATH}"

# --- Optional write to block device ---
[ -n "${BLOCK_DEVICE}" ] || exit 0

[ -b "${BLOCK_DEVICE}" ] || die "${BLOCK_DEVICE} is not a block device"
if lsblk -nro MOUNTPOINT "${BLOCK_DEVICE}" | grep -q .; then
  die "${BLOCK_DEVICE} has mounted partitions, unmount them first"
fi

lsblk -o NAME,SIZE,MODEL,TRAN,FSTYPE,LABEL "${BLOCK_DEVICE}" >&2
printf 'ALL DATA ON %s WILL BE DESTROYED. Type YES to continue: ' "${BLOCK_DEVICE}" >&2
read -r answer </dev/tty
[ "${answer}" = "YES" ] || die "aborted"

SUDO=""
[ "$(id -u)" -eq 0 ] || SUDO="sudo"
xz -dc "${IMAGE_PATH}" | ${SUDO} dd of="${BLOCK_DEVICE}" bs=4M conv=fsync status=progress
sync
printf '%s written to %s\n' "${IMAGE_NAME}" "${BLOCK_DEVICE}" >&2
