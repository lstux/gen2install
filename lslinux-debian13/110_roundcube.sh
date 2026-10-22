#!/bin/sh
WORKDIR="$(dirname "${0}")"
. "${WORKDIR}/server.conf"

usage() {
  exec >&2
  printf "Usage : %s {packages|configure|activate|status}\n" "$(basename "${0}")"
  printf "  packages  : roundcube-core + roundcube-mysql (base dediee, mot de passe genere) ; services NON demarres\n"
  printf "  configure : config Roundcube (IMAP/SMTP locaux), vhost wm.lslinux.org ; nginx -t, ne recharge rien\n"
  printf "  activate  : reload php-fpm et nginx\n"
  printf "  status    : services et reponse HTTPS locale (sans passer par le DNS genserv)\n"
}

# Comme 100_monitoring : policy-rc.d bloque le demarrage des services pendant l'installation.
packages() {
  ${SUSSH} "sh -s" <<'REMOTE' || exit 1
set -e
printf '#!/bin/sh\nexit 101\n' > /usr/sbin/policy-rc.d
chmod 0755 /usr/sbin/policy-rc.d
trap 'rm -f /usr/sbin/policy-rc.d' EXIT

pw="$(openssl rand -base64 24 | tr -d '/+=' | cut -c1-24)"
debconf-set-selections <<DEB
roundcube-core roundcube/dbconfig-install boolean true
roundcube-core roundcube/database-type select mysql
dbconfig-common dbconfig-common/mysql/app-pass password ${pw}
dbconfig-common dbconfig-common/password-confirm password ${pw}
DEB

DEBIAN_FRONTEND=noninteractive apt-get -y install --no-install-recommends \
  roundcube-core roundcube-mysql
REMOTE
}

# La cle DES est conservee d'une execution a l'autre (elle chiffre les mots de passe en session).
configure() {
  cat "${WORKDIR}/roundcube/config.inc.php" | ${SSH} "cat > /tmp/rc_config.inc.php" || exit 1
  cat "${WORKDIR}/nginx/wm.lslinux.org.conf" | ${SSH} "cat > /tmp/rc_mail.conf" || exit 1
  cat "${WORKDIR}/roundcube/mailpw.sh" | ${SSH} "cat > /tmp/rc_mailpw.sh" || exit 1
  cat "${WORKDIR}/roundcube/mailpw.php" | ${SSH} "cat > /tmp/rc_mailpw.php" || exit 1
  cat "${WORKDIR}/roundcube/sudoers-roundcube" | ${SSH} "cat > /tmp/rc_sudoers" || exit 1
  ${SUSSH} "sh -s" <<'REMOTE' || exit 1
set -e
key="$(sed -n "s/^\$config\['des_key'\] = '\([^']*\)';/\1/p" /etc/roundcube/config.inc.php 2>/dev/null | head -n 1)"
[ -n "${key}" ] || key="$(openssl rand -base64 24 | tr -d '/+=' | cut -c1-24)"
sed "s|__DES_KEY__|${key}|" /tmp/rc_config.inc.php > /etc/roundcube/config.inc.php
chown root:www-data /etc/roundcube/config.inc.php
chmod 0640 /etc/roundcube/config.inc.php

rm -f /etc/nginx/sites-enabled/mail.lslinux.org /etc/nginx/sites-available/mail.lslinux.org

install -m 0750 -o root -g root /tmp/rc_mailpw.sh /usr/local/sbin/mailpw
install -m 0644 -o root -g root /tmp/rc_mailpw.php /usr/share/roundcube/plugins/password/drivers/mailpw.php
visudo -cf /tmp/rc_sudoers
install -m 0440 -o root -g root /tmp/rc_sudoers /etc/sudoers.d/roundcube-mailpw
rm -f /tmp/rc_mailpw.sh /tmp/rc_mailpw.php /tmp/rc_sudoers
install -m 0644 -o root -g root /tmp/rc_mail.conf /etc/nginx/sites-available/wm.lslinux.org
ln -sfn ../sites-available/wm.lslinux.org /etc/nginx/sites-enabled/wm.lslinux.org
nginx -t
rm -f /tmp/rc_config.inc.php /tmp/rc_mail.conf
REMOTE
  printf "\n=> Configuration ecrite, rien de recharge. Ensuite : sh %s activate\n" "$(basename "${0}")"
}

activate() {
  ${SUSSH} "sh -s" <<'REMOTE' || exit 1
set -e
nginx -t
systemctl reload php8.4-fpm
systemctl reload nginx
REMOTE
}

status() {
  ${SSH} "systemctl is-active php8.4-fpm nginx mariadb; curl -sk -o /dev/null -w 'HTTPS local wm.lslinux.org : %{http_code}\n' --resolve wm.lslinux.org:443:127.0.0.1 https://wm.lslinux.org/"
}

case "${1}" in
  packages)  packages;;
  configure) configure;;
  activate)  activate;;
  status)    status;;
  *)         usage;;
esac
