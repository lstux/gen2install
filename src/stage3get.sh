#!/bin/bash
MIRROR="https://mirror.bytemark.co.uk/gentoo/releases"
ARCH="amd64"
SYSINIT="-openrc"

DOWNLOADS="/tmp"
PROFILE=""
DOWNLOADDIR=""
DOWNLOADFILE=""
DODOWNLOAD="true"
EXTRACTTO=""

usage() {
  exec >&2
  [ -n "${1}" ] && printf "Error : ${1}\n"
  printf "Usage : $(basename "${0}") [options]\n"
  printf "  Get Gentoo stage3 archive link\n"
  printf "Options :\n"
  printf "  -d dir  : download archive to dir, keeping original filename [${DOWNLOADS}]\n"
  printf "  -o path : download archive to file specified by path\n"
  printf "  -x dir  : once downloaded, extract archive to specified dir\n"
  printf "  -l      : just display download link, do not actually download\n"
  printf "  -O      : use openrc as init (default)\n"
  printf "  -S      : use systemd as init instead of openrc\n"
  printf "  -D      : select a Desktop profile\n"
  printf "  -H      : select an Hardened profile\n"
  printf "  -N      : select a NoMultilib profile\n"
  printf "  -h      : display this help message\n"
  exit 1
}

while getopts SODHNld:o:x:h opt; do case "${opt}" in
  S) SYSINIT="-systemd";;
  O) SYSINIT="-openrc";;
  D) PROFILE="-desktop";;
  H) PROFILE="-hardened";;
  N) PROFILE="-nomultilib";;
  l) DODOWNLOAD="false";;
  d) [ -n "${DOWNLOADFILE}" ] && usage "-d and -o options can't be used simultenaously"; DOWNLOADDIR="${OPTARG}";;
  o) if [ -n "${DOWNLOADDIR}" ]; then
       [ "${DOWNLOADDIR}" = "${DOWNLOADS}" ] && DOWNLOADDIR="" || usage "-d and -o options can't be used simultenaously"
     fi; DOWNLOADFILE="${OPTARG}";;
  x) [ -d "${OPTARG}" ] || usage "stage3 extraction directory should exist (and be prepared)..."; EXTRACTTO="${OPTARG}";;
  *) usage;;
esac; done
shift $((${OPTIND} - 1))

LATEST="${MIRROR}/${ARCH}/autobuilds/$(curl -s "${MIRROR}/${ARCH}/autobuilds/latest-stage3-${ARCH}${PROFILE}${SYSINIT}.txt" | sed -n "/^[^#]/s/\s\+[0-9]\+.*$//p")"
${DODOWNLOAD} || { echo "${LATEST}"; exit 0; }

[ -n "${DOWNLOADDIR}" -o -n "${DOWNLOADFILE}" ] || DOWNLOADDIR="${DOWNLOADS}"
if [ -n "${DOWNLOADFILE}" ]; then
  [ -d "$(dirname "${DOWNLOADFILE}")" ] || { printf "Error : '$(dirname "{DOWNLOADFILE}")', directory does not exist\n" >&2; exit 2; }
  OUTPUT="${DOWNLOADFILE}"
else
  [ -d "${DOWNLOADDIR}" ] || { printf "Error : '${DOWNLOADDIR}', directory does not exist\n" >&2; exit 2; }
  OUTPUT="${DOWNLOADDIR}/$(basename "${LATEST}")"
fi

if [ -e "${OUTPUT}" ]; then
  printf "Stage3 already downloaded, remove to redownload :\n"
else
  curl -o "${OUTPUT}" -L "${LATEST}" || exit $?
  printf "Stage3 downloaded :\n"
fi
printf " -> ${OUTPUT}\n"

[ -d "${EXTRACTTO}" ] || exit 0
tar xpvf "${OUTPUT}" --xattrs-include='*.*' --numeric-owner -C "${EXTRACTTO}"
