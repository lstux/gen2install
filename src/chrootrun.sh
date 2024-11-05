#!/bin/bash
CHROOTDIR=""
RUNCOMMAND="/bin/sh --rcfile /etc/profile"

usage() {
  exec >&2
  printf "Usage : $(basename "${0}") [options] chrootdir [command]\n"
  printf "  Run chrooted command (${RUNCOMMAND} by default) after mounting\n"
  printf "  appropriate virtual filesystms\n"
  printf "Options :\n"
  printf "  -h : display this help message\n"
  exit 1
}

rbind() { mount --rbind "${1}" "${2}" && mount --make-rslave "${2}"; }

sysumounts() {
  local e=0 i j f
  for i in run dev sys proc; do
    mountpoint -q "${CHROOTDIR}/${i}" || continue
    f="$(mount | grep "${CHROOTDIR}/${i}" | awk '{print $3}' | tac)"
    for j in ${f}; do
      umount "${CHROOTDIR}/${j}" || e=$((${e} + 1))
    done
  done
  return ${e}
}

sysmounts() {
  local e=0 i
  if ! mountpoint -q "${CHROOTDIR}/proc"; then mount -t proc /proc "${CHROOTDIR}/proc" || e=$((${e} + 1)); fi
  [ ${e} -eq 0 ] && for i in sys dev run; do
    if ! mountpoint -q "${CHROOTDIR}/${i}"; then rbind "/${i}" "${CHROOTDIR}/${i}" && continue; e=$((${e} + 1)); break; fi
  done
  [ ${e} -eq 0 ] || sysumounts
  return ${e}
}

UMOUNTONLY="false"
while getopts uh opt; do case "${opt}" in
  u) UMOUNTONLY="true";;
  *) usage;;
esac; done
shift $((${OPTIND} - 1))
[ -d "${1}" ] || usage
CHROOTDIR="${1}"
shift
[ -n "${1}" ] && RUNCOMMAND="${RUNCOMMAND} -c '$*'"
echo "RUNCOMMAND=${RUNCOMMAND}" >&2

if ! ${UMOUNTONLY}; then
  sysmounts "${CHROOTDIR}" || exit 2
  cp --dereference /etc/resolv.conf "${CHROOTDIR}/etc/resolv.conf"
  eval chroot "${CHROOTDIR}" ${RUNCOMMAND}
fi
sysumounts
