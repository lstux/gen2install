#!/bin/sh
WORKDIR="$(dirname "${0}")"
. "${WORKDIR}/server.conf"

usage() {
  exec >&2
  printf "Usage : %s {backup|restore|status}\n" "$(basename "${0}")"
  printf "  Backup/Restore certbot DNS-01 (hooks + acme_txt.sh + certificat lslinux) sur lslng\n"
  printf "  NB: acme_txt.sh doit aussi etre pose en /root/acme_txt.sh sur genserv (hors scope de ce script, genserv n'est pas gere via server.conf)\n"
}

backup() {
  d="$(date +%Y%m%d)"
  ${SSH} "cd / && \
          sudo tar cvpz \
                   root/acme_txt.sh \
                   etc/letsencrypt/hooks/ \
                   etc/letsencrypt/renewal-hooks/ \
                   etc/letsencrypt/live/lslinux/ \
                   etc/letsencrypt/archive/lslinux/ \
                   etc/letsencrypt/renewal/lslinux.conf" \
  > "${WORKDIR}/data/certbot_etc_${d}.tgz" && \
  ln -sf "certbot_etc_${d}.tgz" "${WORKDIR}/data/certbot_etc.tgz"
}

restore() {
  cat "${WORKDIR}/data/certbot_etc.tgz" | ${SSH} "sudo tar xvzpf - -C /"
  ${SUSSH} "chmod +x /root/acme_txt.sh /etc/letsencrypt/hooks/auth.sh /etc/letsencrypt/hooks/cleanup.sh"
  printf "\n=> Pense a poser /root/acme_txt.sh (ACME_ZONEDIR=/var/bind/pri) en root sur genserv aussi.\n"
  printf "=> Ready! ${SUSSH} postconf -e smtpd_tls_cert_file=/etc/letsencrypt/live/lslinux/fullchain.pem (idem key_file + dovecot 10-ssl.conf), puis reload postfix/dovecot\n"
}

status() {
  ${SSH} "sudo certbot certificates"
}


case "${1}" in
  backup)  backup;;
  restore) restore;;
  status)  status;;
  *)       usage;;
esac
