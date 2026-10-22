#!/bin/sh
WORKDIR="$(dirname "${0}")"
. "${WORKDIR}/server.conf"

NSBOX="${NSBOX:-nsd@nsbox}"
NSSSH="ssh ${NSBOX}"
KEYNAME="/root/.ssh/id_lslng"

usage() {
  exec >&2
  printf "Usage : %s {install-lslng|install-nsbox|access|cron-nsbox|run|status}\n" "$(basename "${0}")"
  printf "  install-lslng : dump MariaDB quotidien (timer systemd) sur lslng\n"
  printf "  install-nsbox : script /backup/lslng/00_snapshot.sh sur nsbox (sans cron)\n"
  printf "  access        : cle SSH root@nsbox -> debian@lslng (+ test sudo rsync)\n"
  printf "  cron-nsbox    : cron quotidien du snapshot sur nsbox\n"
  printf "  run     : lance un snapshot maintenant sur nsbox (en arriere-plan)\n"
  printf "  status  : snapshots presents, dernier log, timer de dump\n"
}

# lslng : dump MariaDB quotidien (pas de cron sur lslng : timer systemd)
install_lslng() {
  cat "${WORKDIR}/backup/mariadb-dump-all.sh" | ${SSH} "sudo tee /usr/local/sbin/mariadb-dump-all >/dev/null && sudo chmod 0750 /usr/local/sbin/mariadb-dump-all" || return 1

  ${SSH} "sudo tee /etc/systemd/system/mariadb-dump-all.service >/dev/null" <<'UNIT' || return 1
[Unit]
Description=Dump complet MariaDB (backup)
After=mariadb.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/mariadb-dump-all
UNIT

  ${SSH} "sudo tee /etc/systemd/system/mariadb-dump-all.timer >/dev/null" <<'UNIT' || return 1
[Unit]
Description=Dump MariaDB quotidien

[Timer]
OnCalendar=*-*-* 03:30:00
Persistent=true

[Install]
WantedBy=timers.target
UNIT

  ${SSH} "sudo systemctl daemon-reload && sudo systemctl enable --now mariadb-dump-all.timer" || return 1
}

# nsbox : script de snapshot (sans cron)
install_nsbox() {
  cat "${WORKDIR}/backup/lslng_snapshot.sh" | ${NSSSH} "sudo install -d -m 0750 /backup/lslng /backup/lslng/logs && sudo tee /backup/lslng/00_snapshot.sh >/dev/null && sudo chmod 0750 /backup/lslng/00_snapshot.sh"
}

# Cle SSH root@nsbox -> debian@lslng (sudo complet cote lslng), puis test rsync
access() {
  pub="$(${NSSSH} "sudo sh -c '[ -f ${KEYNAME} ] || ssh-keygen -q -t ed25519 -N \"\" -C root@nsbox-lslng-backup -f ${KEYNAME}; cat ${KEYNAME}.pub'")" || return 1
  test -n "${pub}" || return 1
  printf "%s\n" "${pub}" | ${SSH} "umask 077; mkdir -p ~/.ssh; read k; grep -qxF \"\$k\" ~/.ssh/authorized_keys 2>/dev/null || echo \"\$k\" >> ~/.ssh/authorized_keys" || return 1
  ${NSSSH} "sudo ssh -i ${KEYNAME} -o BatchMode=yes -o StrictHostKeyChecking=accept-new ${SSH_USER}@${SSH_HOST} 'sudo -n rsync --version | head -1'"
}

cron_nsbox() {
  ${NSSSH} "sudo tee /etc/cron.d/lslng_bkp >/dev/null" <<'CRON'
20 4 * * * root /backup/lslng/00_snapshot.sh
CRON
}

run() {
  ${NSSSH} "sudo sh -c 'nohup /backup/lslng/00_snapshot.sh >> /backup/lslng/logs/run.log 2>&1 &'" && \
  printf "Snapshot lance sur nsbox. Suivre : sh %s status\n" "$(basename "${0}")"
}

status() {
  ${NSSSH} "sudo sh -c 'ls -ld /backup/lslng/[0-9]* /backup/lslng/.inprogress /backup/lslng/latest 2>&1; df -h /backup | tail -1; tail -n 5 \$(ls -t /backup/lslng/logs/*.log | head -1)'" ; \
  ${SSH} "systemctl list-timers mariadb-dump-all.timer --no-pager; ls -l /var/backups/mariadb 2>&1"
}

case "${1}" in
  install-lslng) install_lslng;;
  install-nsbox) install_nsbox;;
  access)        access;;
  cron-nsbox)    cron_nsbox;;
  run)     run;;
  status)  status;;
  *)       usage;;
esac
