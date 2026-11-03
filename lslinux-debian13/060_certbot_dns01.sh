#!/bin/sh
WORKDIR="$(dirname "${0}")"
. "${WORKDIR}/server.conf"

usage() {
  exec >&2
  printf "Usage : %s {backup|restore|hooks|status}\n" "$(basename "${0}")"
  printf "  backup  : archive certificat lslinux, hooks, acme_txt.sh (data/certbot_etc_AAAAMMJJ.tgz)\n"
  printf "  restore : extrait l'archive, puis reinstalle les hooks depuis ce dossier\n"
  printf "  hooks   : installe acme_txt.sh, les hooks DNS-01 (auth/cleanup) et les hooks de deploiement\n"
  printf "            (permissions ssl-cert, reload postfix/dovecot/nginx) depuis ce dossier\n"
  printf "  status  : certbot certificates\n"
  printf "  Validation DNS-01 par delegation : le TXT est ecrit dans acme.lslinux.org (lslng seul), genserv n'intervient plus.\n"
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

# Les sources du dossier font foi (ce sont les versions deployees) : elles remplacent
# ce que contient l'archive. Les hooks de deploiement sont executes par certbot apres
# chaque renouvellement (ordre alphabetique).
hooks() {
  for f in acme_txt.sh certbot_auth_hook.sh certbot_cleanup_hook.sh \
           certbot_deploy_10-ssl-cert-group.sh certbot_deploy_99-services-reload.sh; do
    [ -f "${WORKDIR}/${f}" ] || { printf "Source manquante : %s/%s\n" "${WORKDIR}" "${f}" >&2; exit 1; }
  done
  ${SUSSH} "install -d -m 0755 -o root -g root /etc/letsencrypt/hooks /etc/letsencrypt/renewal-hooks/deploy" || exit 1
  cat "${WORKDIR}/acme_txt.sh" | ${SSH} "sudo tee /root/acme_txt.sh >/dev/null && sudo chmod 0755 /root/acme_txt.sh" || exit 1
  cat "${WORKDIR}/certbot_auth_hook.sh" | ${SSH} "sudo tee /etc/letsencrypt/hooks/auth.sh >/dev/null && sudo chmod 0755 /etc/letsencrypt/hooks/auth.sh" || exit 1
  cat "${WORKDIR}/certbot_cleanup_hook.sh" | ${SSH} "sudo tee /etc/letsencrypt/hooks/cleanup.sh >/dev/null && sudo chmod 0755 /etc/letsencrypt/hooks/cleanup.sh" || exit 1
  cat "${WORKDIR}/certbot_deploy_10-ssl-cert-group.sh" | ${SSH} "sudo tee /etc/letsencrypt/renewal-hooks/deploy/10-ssl-cert-group.sh >/dev/null && sudo chmod 0750 /etc/letsencrypt/renewal-hooks/deploy/10-ssl-cert-group.sh" || exit 1
  cat "${WORKDIR}/certbot_deploy_99-services-reload.sh" | ${SSH} "sudo tee /etc/letsencrypt/renewal-hooks/deploy/99-services-reload.sh >/dev/null && sudo chmod 0750 /etc/letsencrypt/renewal-hooks/deploy/99-services-reload.sh" || exit 1
  ${SSH} "sudo ls -l /root/acme_txt.sh /etc/letsencrypt/hooks /etc/letsencrypt/renewal-hooks/deploy"
}

restore() {
  cat "${WORKDIR}/data/certbot_etc.tgz" | ${SSH} "sudo tar xvzpf - -C /"
  hooks
  printf "=> Ready! ${SUSSH} postconf -e smtpd_tls_cert_file=/etc/letsencrypt/live/lslinux/fullchain.pem (idem key_file + dovecot 10-ssl.conf), puis reload postfix/dovecot\n"
}

status() {
  ${SSH} "sudo certbot certificates"
}


case "${1}" in
  backup)  backup;;
  restore) restore;;
  hooks)   hooks;;
  status)  status;;
  *)       usage;;
esac
