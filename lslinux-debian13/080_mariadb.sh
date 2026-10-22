#!/bin/sh
WORKDIR="$(dirname "${0}")"
. "${WORKDIR}/server.conf"

usage() {
  exec >&2
  printf "Usage : %s {backup|restore|tune|status}\n" "$(basename "${0}")"
  printf "  Backup/Restore MariaDB (conf + dump complet) sur Debian13\n"
}

backup() {
  d="$(date +%Y%m%d)"
  ${SSH} "sudo mariadb-dump --all-databases --single-transaction --events --routines --triggers" \
  | gzip > "${WORKDIR}/data/mariadb_dump_${d}.sql.gz" && \
  ln -sf "mariadb_dump_${d}.sql.gz" "${WORKDIR}/data/mariadb_dump.sql.gz" && \
  ${SSH} "cd /etc && sudo tar cvpz mysql/" \
  > "${WORKDIR}/data/mariadb_etc_${d}.tgz" && \
  ln -sf "mariadb_etc_${d}.tgz" "${WORKDIR}/data/mariadb_etc.tgz"
}

restore() {
  ${SUSSH} "DEBIAN_FRONTEND=noninteractive apt -y install mariadb-server" && \
  cat "${WORKDIR}/data/mariadb_etc.tgz" | ${SSH} "sudo tar xvzpf - -C /etc/" && \
  printf "\n=> Ready! Verifier puis : %s systemctl restart mariadb\n" "${SUSSH}" && \
  printf "=> Puis restaurer le dump : gunzip -c %s/data/mariadb_dump.sql.gz | %s mariadb\n" "${WORKDIR}" "${SSH}"
}

# Reglages pour Nextcloud : fichier de conf + application a chaud (sans restart).
# innodb_buffer_pool_size ne grossit qu'apres un restart de MariaDB (innodb_buffer_pool_size_max est fige au demarrage).
tune() {
  cat "${WORKDIR}/mariadb/60-nextcloud.cnf" | ${SSH} "sudo tee /etc/mysql/mariadb.conf.d/60-nextcloud.cnf >/dev/null" || return 1
  ${SSH} "sudo mariadb -e \"SET GLOBAL innodb_log_file_size=268435456; SET GLOBAL tmp_table_size=67108864; SET GLOBAL max_heap_table_size=67108864; SET GLOBAL max_allowed_packet=67108864\"" || return 1
  ${SSH} "sudo mariadb -N -e \"show variables where Variable_name in ('innodb_buffer_pool_size','innodb_log_file_size','tmp_table_size','max_heap_table_size','max_allowed_packet')\""
}

status() {
  ${SSH} "sudo systemctl status mariadb --no-pager"
}


case "${1}" in
  backup)  backup;;
  restore) restore;;
  tune)    tune;;
  status)  status;;
  *)       usage;;
esac
