#!/bin/sh
WORKDIR="$(dirname "${0}")"
. "${WORKDIR}/server.conf"

usage() {
  exec >&2
  printf "Usage : %s {backup|restore|status}\n" "$(basename "${0}")"
  printf "  Backup/Restore rspamd (antivirus+dkim_signing) + ClamAV integration on Debian13 server\n"
}

backup() {
  d="$(date +%Y%m%d)"
  ${SSH} "cd /etc && \
          sudo tar cvpz \
                   rspamd/local.d/antivirus.conf \
                   rspamd/local.d/dkim_signing.conf \
                   rspamd/local.d/redis.conf \
                   rspamd/local.d/actions.conf \
                   rspamd/local.d/milter_headers.conf \
                   dovecot/conf.d/91-spam-sieve.conf \
                   dovecot/sieve/spam.sieve \
                   rspamd/dkim/" \
  > "${WORKDIR}/data/rspamd_etc_${d}.tgz" && \
  ln -sf "rspamd_etc_${d}.tgz" "${WORKDIR}/data/rspamd_etc.tgz"
}

restore() {
  ${SUSSH} "apt -y install rspamd redis-server clamav-daemon clamav-freshclam"
  cat "${WORKDIR}/data/rspamd_etc.tgz" | ${SSH} "sudo tar xvzpf - -C /etc/"
  ${SUSSH} "chown -R _rspamd:_rspamd /etc/rspamd/dkim && chmod 750 /etc/rspamd/dkim && chmod 640 /etc/rspamd/dkim/*.key"
  ${SUSSH} "sievec /etc/dovecot/sieve/spam.sieve && doveconf -n >/dev/null"
  ${SUSSH} "rspamadm configtest"
  printf "\n=> N'oublie pas : postconf -e smtpd_milters/non_smtpd_milters sur postfix (voir 020_postfix_dovecot.sh backup), puis :\n"
  printf "=> Ready! ${SUSSH} systemctl reload rspamd && ${SUSSH} systemctl reload postfix && ${SUSSH} systemctl reload dovecot\n"
  printf "=> Bayes : apprentissage initial a refaire a la main (rspamc learn_spam sur les Junk, learn_ham sur un tri propre).\n"
}

status() {
  ${SSH} "sudo systemctl status rspamd clamav-daemon --no-pager"
}


case "${1}" in
  backup)  backup;;
  restore) restore;;
  status)  status;;
  *)       usage;;
esac
