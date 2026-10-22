#!/bin/sh
WORKDIR="$(dirname "${0}")"
. "${WORKDIR}/server.conf"

usage() {
  exec >&2
  printf "Usage : %s {backup|restore|status}\n" "$(basename "${0}")"
  printf "  Backup/Restore Nginx + PHP-FPM (conf) sur Debian13\n"
}

backup() {
  d="$(date +%Y%m%d)"
  ${SSH} "cd /etc && \
          sudo tar cvpz \
                   nginx/ \
                   php/8.4/fpm/ \
                   php/8.4/mods-available/" \
  > "${WORKDIR}/data/nginx_etc_${d}.tgz" && \
  ln -sf "nginx_etc_${d}.tgz" "${WORKDIR}/data/nginx_etc.tgz"
}

restore() {
  ${SUSSH} "apt -y install nginx php8.4-fpm" && \
  cat "${WORKDIR}/data/nginx_etc.tgz" | ${SSH} "sudo tar xvzpf - -C /etc/" && \
  ${SUSSH} "nginx -t && php-fpm8.4 -t" && \
  printf "\n=> Ready! Verifier puis : %s systemctl restart php8.4-fpm nginx\n" "${SUSSH}"
}

status() {
  ${SSH} "sudo systemctl status nginx php8.4-fpm --no-pager"
}


case "${1}" in
  backup)  backup;;
  restore) restore;;
  status)  status;;
  *)       usage;;
esac
