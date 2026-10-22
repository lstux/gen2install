#!/bin/sh
WORKDIR="$(dirname "${0}")"
. "${WORKDIR}/server.conf"

VMAIL_UID=5000
VMAIL_GID=5000
VMAIL_DATA_DIR="/var/lib/vmail"
VMAIL_DB="${VMAIL_DATA_DIR}/vmail.db"

usage() {
  exec >&2
  printf "Usage : $(basename "${0}") {backup|restore|status}\n"
  printf "  Backup/Restore Postfix+Dovecot (SQLite) installation on Debian13 server\n"
}

install_packages() {
  ${SSH} "sudo apt -y install \
                   postfix postfix-sqlite \
                   dovecot-core dovecot-imapd dovecot-lmtpd dovecot-sqlite \
                   sqlite3"
}

setup_vmail_user() {
  ${SSH} "sudo getent group vmail >/dev/null || sudo groupadd -g ${VMAIL_GID} vmail
          sudo getent passwd vmail >/dev/null || sudo useradd -u ${VMAIL_UID} -g vmail -d ${VMAIL_DATA_DIR} -s /usr/sbin/nologin vmail
          sudo install -d -ovmail -gvmail -m750 ${VMAIL_DATA_DIR}
          sudo install -d -ovmail -gvmail -m750 ${VMAIL_DATA_DIR}/vhosts"
}

init_schema() {
  if [ -f "${WORKDIR}/data/vmail_schema.sql" ]; then
    cat "${WORKDIR}/data/vmail_schema.sql" | ${SSH} "\
      if sudo test -f ${VMAIL_DB}; then \
        echo 'vmail.db existe déjà, schéma non réappliqué (protection contre écrasement).' ; \
      else \
        sudo sh -c 'sqlite3 ${VMAIL_DB} && chown vmail:vmail ${VMAIL_DB} && chmod 640 ${VMAIL_DB}'; \
      fi"
  else
    printf "Pas de ${WORKDIR}/data/vmail_schema.sql en local, schéma non déployé.\n" >&2
  fi
}

backup() {
  d="$(date +%Y%m%d)"
  ${SSH} "cd /etc && \
          sudo tar cvpz \
                   postfix/main.cf \
                   postfix/master.cf \
                   postfix/sqlite/ \
                   dovecot/dovecot.conf \
                   dovecot/conf.d/10-auth.conf \
                   dovecot/conf.d/10-mail.conf \
                   dovecot/conf.d/10-master.conf \
                   dovecot/conf.d/10-ssl.conf \
                   dovecot/conf.d/20-lmtp.conf \
                   dovecot/conf.d/auth-sql.conf.ext" \
  > "${WORKDIR}/data/postfix_dovecot_etc_${d}.tgz" && \
  ln -sf "postfix_dovecot_etc_${d}.tgz" "${WORKDIR}/data/postfix_dovecot_etc.tgz"
}

restore() {
  install_packages
  setup_vmail_user

  if [ -f "${WORKDIR}/data/postfix_dovecot_etc.tgz" ]; then
    cat "${WORKDIR}/data/postfix_dovecot_etc.tgz" | ${SSH} "sudo tar xvzpf - -C /etc/"
  else
    printf "\nPas de ${WORKDIR}/data/postfix_dovecot_etc.tgz en local.\n" >&2
    printf "Configure main.cf/master.cf/dovecot une première fois à la main sur le serveur,\n" >&2
    printf "puis relance : $(basename "${0}") backup\n" >&2
  fi

  init_schema

  ${SSH} "sudo postfix check && sudo doveconf -n >/dev/null"
  printf "\n=> Ready! ${SSH} sudo systemctl restart postfix dovecot"
}

status() {
  ${SSH} "sudo systemctl status postfix dovecot"
}


case "${1}" in
  backup)  backup;;
  restore) restore;;
  status)  status;;
  *)       usage;;
esac
