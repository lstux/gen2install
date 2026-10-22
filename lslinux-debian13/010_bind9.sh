#!/bin/sh
WORKDIR="$(dirname "${0}")"
. "${WORKDIR}/server.conf"

usage() {
  exec >&2
  printf "Usage : $(basename "${0}") {backup|restore}\n"
  printf "  Backup/Restore Bind9 installation on Debian13 server\n"
}

backup() {
  d="$(date +%Y%m%d)"
  ${SSH} "cd /etc && \
          sudo tar cvpz \
                   bind/named.conf.local \
                   bind/named.conf.options \
                   bind/zones.conf \
                   bind/zones/ \
                   bind/rndc.key \
                   apparmor.d/local/usr.sbin.named" \
  > "${WORKDIR}/data/bind_etc_${d}.tgz" && \
  ln -sf "bind_etc_${d}.tgz" "${WORKDIR}/data/bind_etc.tgz"
}

restore() {
  cat "${WORKDIR}/data/bind_etc.tgz" | ${SSH} "sudo tar xvzpf - -C /etc/"
  ${SUSSH} "apt -y install bind9 bind9-utils bind9-dnsutils"
  ${SUSSH} "install -d -obind -gbind -m755 /var/log/bind"
  ${SUSSH} "systemctl reload apparmor && named-checkconf -z"
  printf "\n=> Ready! ${SUSSH} systemctl restart bind9"
}

status() {
  ${SSH} "sudo systemctl status bind9"
}


case "${1}" in
  backup)  backup;;
  restore) restore;;
  status)  status;;
  *)       usage;;
esac
