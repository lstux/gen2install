#!/bin/sh
WORKDIR="$(dirname "${0}")"
. "${WORKDIR}/server.conf"

usage() {
  exec >&2
  printf "Usage : %s {backup|restore|status}\n" "$(basename "${0}")"
  printf "  Backup/Restore fail2ban (jail.local + jails postfix/dovecot) on Debian13 server\n"
}

backup() {
  d="$(date +%Y%m%d)"
  ${SSH} "cd /etc && \
          sudo tar cvpz \
                   fail2ban/jail.local \
                   fail2ban/jail.d/" \
  > "${WORKDIR}/data/fail2ban_etc_${d}.tgz" && \
  ln -sf "fail2ban_etc_${d}.tgz" "${WORKDIR}/data/fail2ban_etc.tgz"
}

restore() {
  # nftables (binaire nft) est indispensable : banaction = nftables dans jail.d/defaults-debian.conf.
  # Sans lui les bannissements echouent en silence (constate le 2026-10-13, 8639 erreurs).
  # Ne PAS activer nftables.service : son /etc/nftables.conf fait "flush ruleset".
  ${SUSSH} "apt -y install fail2ban nftables"
  cat "${WORKDIR}/data/fail2ban_etc.tgz" | ${SSH} "sudo tar xvzpf - -C /etc/"
  ${SUSSH} "fail2ban-client -t"
  printf "\n=> Ready! ${SUSSH} systemctl restart fail2ban (restart, pas reload, pour recreer la table nft)\n"
}

status() {
  ${SSH} "sudo fail2ban-client status"
}


case "${1}" in
  backup)  backup;;
  restore) restore;;
  status)  status;;
  *)       usage;;
esac
