#!/bin/sh
WORKDIR="$(dirname "${0}")"
. "${WORKDIR}/server.conf"

# Chaque majeure doit etre installee et migree (occ upgrade) dans l'ordre : 31 -> 32 -> 33 -> 34 -> 35.
NC_VERSION="${NC_VERSION:-31.0.7}"
# Empreinte de la cle de signature Nextcloud, a verifier sur nextcloud.com avant usage.
NC_GPG_FPR="${NC_GPG_FPR:-}"
# Destination des donnees pour "save" (disque hors lslng).
NC_BACKUP_DIR="${NC_BACKUP_DIR:-}"
# Source de l'ancienne instance (genserv, Gentoo, Nextcloud 31.0.7).
GS_SSH="ssh -o ConnectTimeout=10 root@genserv.lslinux.org"
GS_NC_DIR="/var/www/localhost/htdocs/nextcloud"

usage() {
  exec >&2
  printf "Usage : %s {backup|restore|upgrade|dbfix|save|tune|vhost|rowformat|mimetypes|phpini|apps|status}\n" "$(basename "${0}")"
  printf "  Backup (genserv) : config.php + dump MariaDB 'nextcloud'\n"
  printf "  Restore (lslng)  : Nextcloud %s (archive officielle verifiee) dans /var/www/nextcloud-%s\n" "${NC_VERSION}" "${NC_VERSION}"
  printf "  Upgrade (lslng)  : une majeure vers NC_VERSION (dump pre-montee dans /root, occ upgrade)\n"
  printf "  Donnees : /var/lib/nextcloud (rsync separe, non gere ici)\n"
  printf "  Variables : NC_VERSION, NC_GPG_FPR (obligatoire pour restore/upgrade)\n"
}

backup() {
  d="$(date +%Y%m%d)"
  ${GS_SSH} "cd ${GS_NC_DIR} && tar cvpz config/" \
  > "${WORKDIR}/data/nextcloud_config_${d}.tgz" && \
  ln -sf "nextcloud_config_${d}.tgz" "${WORKDIR}/data/nextcloud_config.tgz" && \
  ${GS_SSH} "sh -s" <<'REMOTE' || exit 1
set -e
cd /var/www/localhost/htdocs/nextcloud
eval "$(php -r 'include "config/config.php"; printf("DBU=%s\nDBP=%s\nDBH=%s\nDBN=%s\n", escapeshellarg($CONFIG["dbuser"]), escapeshellarg($CONFIG["dbpassword"]), escapeshellarg($CONFIG["dbhost"]), escapeshellarg($CONFIG["dbname"]));')"
umask 077
case "${DBH}" in
  *:*) DBPORT="${DBH#*:}"; DBHOST="${DBH%%:*}";;
  *)   DBPORT=3306; DBHOST="${DBH}";;
esac
printf "[client]\nuser=%s\npassword=%s\nhost=%s\nport=%s\n" "${DBU}" "${DBP}" "${DBHOST}" "${DBPORT}" > /root/nc-dump.cnf
mysqldump --defaults-extra-file=/root/nc-dump.cnf --single-transaction "${DBN}" > /root/nc-dump.sql
rm -f /root/nc-dump.cnf
test -s /root/nc-dump.sql
gzip -f /root/nc-dump.sql
REMOTE
  ${GS_SSH} "cat /root/nc-dump.sql.gz && rm -f /root/nc-dump.sql.gz" \
  > "${WORKDIR}/data/nextcloud_db_${d}.sql.gz" && \
  test -s "${WORKDIR}/data/nextcloud_db_${d}.sql.gz" && \
  ln -sf "nextcloud_db_${d}.sql.gz" "${WORKDIR}/data/nextcloud_db.sql.gz" && \
  printf "\n=> Mettre Nextcloud en maintenance sur genserv avant le dump final (occ maintenance:mode --on).\n"
}

# Telecharge, verifie (SHA256 + GPG) et installe le code dans /var/www/nextcloud-${NC_VERSION}.
# Extraction dans un repertoire temporaire : tar remplacerait sinon le lien /var/www/nextcloud par un dossier.
# Ne touche ni au lien /var/www/nextcloud ni a l'instance en service.
remote_install_code() {
  cat <<'REMOTE'
set -e
dest="/var/www/nextcloud-${NC_VERSION}"
f="nextcloud-${NC_VERSION}.tar.bz2"
base="https://download.nextcloud.com/server/releases"
if [ -e "${dest}" ]; then echo "${dest} existe deja" >&2; exit 1; fi
mkdir -p /root/nc-src && cd /root/nc-src
[ -e "${f}" ] || curl -fsSLO "${base}/${f}"
curl -fsSLO "${base}/${f}.sha256"
curl -fsSLO "${base}/${f}.asc"
grep " ${f}\$" "${f}.sha256" | sha256sum -c -
curl -fsSL https://nextcloud.com/nextcloud.asc | gpg --batch --import
gpg --batch --status-fd 1 --verify "${f}.asc" "${f}" 2>/dev/null | grep -q "VALIDSIG ${NC_GPG_FPR}"
tmp="$(mktemp -d /var/www/.nc-extract.XXXXXX)"
trap 'rm -rf "${tmp}"' EXIT
tar -xjf "${f}" -C "${tmp}"
mv "${tmp}/nextcloud" "${dest}"
rm -rf "${dest}/config"
ln -sfn /etc/nextcloud "${dest}/config"
chown -R www-data:www-data "${dest}"
install -d -o www-data -g www-data -m 0755 /var/lib/nextcloud/apps
ln -sfn /var/lib/nextcloud/apps "${dest}/apps-extra"
REMOTE
}

restore() {
  if [ -z "${NC_GPG_FPR}" ]; then
    printf "NC_GPG_FPR non defini : renseigner l'empreinte de la cle Nextcloud (verifiee sur nextcloud.com).\n" >&2
    exit 1
  fi

  ${SUSSH} "DEBIAN_FRONTEND=noninteractive apt -y install php8.4-apcu php8.4-bcmath php8.4-bz2 php8.4-curl php8.4-gd php8.4-gmp php8.4-imagick php8.4-intl php8.4-mbstring php8.4-mysql php8.4-xml php8.4-zip php8.4-redis redis-server bzip2 gnupg" && \
  { remote_install_code; cat <<'REMOTE'
mkdir -p /etc/nextcloud /var/lib/nextcloud
[ -L /var/www/nextcloud ] || ln -s "nextcloud-${NC_VERSION}" /var/www/nextcloud
chown -R www-data:www-data /etc/nextcloud /var/lib/nextcloud
chmod 750 /var/lib/nextcloud
REMOTE
  } | ${SUSSH} "env NC_VERSION=${NC_VERSION} NC_GPG_FPR=${NC_GPG_FPR} sh -s" && \
  cat "${WORKDIR}/data/nextcloud_config.tgz" | ${SSH} "sudo tar xzpf - -C /etc/nextcloud --strip-components=1" && \
  printf "\n=> Code en place : nextcloud-%s (lien /var/www/nextcloud cree seulement s'il n'existait pas)\n" "${NC_VERSION}" && \
  printf "=> Verifier /etc/nextcloud/config.php : datadirectory => /var/lib/nextcloud/data, dbhost/dbname/dbuser, trusted_domains, overwrite.cli.url\n" && \
  printf "=> Puis : nginx/cloud.lslinux.org.conf (deja dans le depot), %s nginx -t, et restaurer le dump MariaDB\n" "${SUSSH}"
}

# Montee d'UNE majeure (31 -> 32 -> ...). A relancer avec NC_VERSION suivant, apres validation.
upgrade() {
  if [ -z "${NC_GPG_FPR}" ]; then
    printf "NC_GPG_FPR non defini.\n" >&2
    exit 1
  fi

  { cat <<'REMOTE'
set -e
[ -L /var/www/nextcloud ] || { echo "/var/www/nextcloud n'est pas un lien : abandon" >&2; exit 1; }
cur="$(sed -n "s/.*OC_VersionString = '\([0-9]*\)\..*/\1/p" /var/www/nextcloud/version.php)"
new="${NC_VERSION%%.*}"
[ -n "${cur}" ] && [ "$((cur + 1))" -eq "${new}" ] || { echo "Majeure installee (${cur}) -> cible ${NC_VERSION} : une seule majeure a la fois" >&2; exit 1; }
REMOTE
    remote_install_code
    cat <<'REMOTE'
occ() { sudo -u www-data php /var/www/nextcloud/occ "$@" </dev/null; }
old="$(readlink /var/www/nextcloud)"
occ maintenance:mode --on
mariadb-dump --single-transaction nextcloud > "/root/nc-pre-${NC_VERSION}.sql"
test -s "/root/nc-pre-${NC_VERSION}.sql"
gzip -f "/root/nc-pre-${NC_VERSION}.sql"
ln -sfn "nextcloud-${NC_VERSION}" /var/www/nextcloud
if ! occ upgrade; then
  echo "ECHEC occ upgrade. Retour arriere : ln -sfn ${old} /var/www/nextcloud ; restaurer /root/nc-pre-${NC_VERSION}.sql.gz ; occ maintenance:mode --off. Maintenance laissee active." >&2
  exit 1
fi
occ maintenance:mode --off
occ status
REMOTE
  } | ${SUSSH} "env NC_VERSION=${NC_VERSION} NC_GPG_FPR=${NC_GPG_FPR} sh -s" && \
  printf "\n=> Recharger PHP-FPM (opcache/realpath du lien) : %s systemctl reload php8.4-fpm\n" "${SUSSH}" && \
  printf "=> Puis tester la connexion web, et au besoin : occ db:add-missing-indices\n"
}

# Corrige le schema apres les montees : index manquants + int -> bigint (heritage de genserv).
dbfix() {
  cat <<'REMOTE' | ${SUSSH} "sh -s"
set -e
occ() { sudo -u www-data php /var/www/nextcloud/occ "$@" </dev/null; }
d="$(date +%Y%m%d%H%M)"
occ maintenance:mode --on
mariadb-dump --single-transaction nextcloud > "/root/nc-pre-dbfix-${d}.sql"
test -s "/root/nc-pre-dbfix-${d}.sql"
gzip -f "/root/nc-pre-dbfix-${d}.sql"
if ! { occ db:add-missing-indices && occ db:convert-filecache-bigint --no-interaction; }; then
  echo "ECHEC dbfix. Maintenance laissee active ; dump : /root/nc-pre-dbfix-${d}.sql.gz" >&2
  exit 1
fi
occ maintenance:mode --off
occ db:schema:check || true
REMOTE
}

# Sauvegarde de l'instance lslng (pas genserv) : base + config dans data/, donnees (rsync) dans NC_BACKUP_DIR.
# Pour une copie coherente (finale), mettre Nextcloud en maintenance avant : occ maintenance:mode --on
save() {
  if [ -z "${NC_BACKUP_DIR}" ]; then
    printf "NC_BACKUP_DIR non defini : repertoire de destination des donnees (disque hors lslng).\n" >&2
    exit 1
  fi
  d="$(date +%Y%m%d)"
  mkdir -p "${NC_BACKUP_DIR}/data" && \
  ${SSH} "sudo mariadb-dump --single-transaction nextcloud | gzip" \
  > "${WORKDIR}/data/nextcloud_lslng_db_${d}.sql.gz" && \
  test -s "${WORKDIR}/data/nextcloud_lslng_db_${d}.sql.gz" && \
  ln -sf "nextcloud_lslng_db_${d}.sql.gz" "${WORKDIR}/data/nextcloud_lslng_db.sql.gz" && \
  ${SSH} "cd /etc && sudo tar czpf - nextcloud/" \
  > "${WORKDIR}/data/nextcloud_lslng_config_${d}.tgz" && \
  ln -sf "nextcloud_lslng_config_${d}.tgz" "${WORKDIR}/data/nextcloud_lslng_config.tgz" && \
  rsync -aH --info=stats1 -e "ssh" --rsync-path="sudo rsync" \
    "${SSH_USER}@${SSH_HOST}:/var/lib/nextcloud/data/" "${NC_BACKUP_DIR}/data/" && \
  printf "\n=> Sauvegarde dans %s (donnees) et %s/data (base + config)\n" "${NC_BACKUP_DIR}" "${WORKDIR}"
}

# Lot 1 : cache (APCu + Redis), verrouillage, region, fenetre de maintenance, cron (timer systemd, pas de cron sur lslng).
tune() {
  ${SUSSH} "sh -s" <<'REMOTE' || exit 1
set -e
occ() { sudo -u www-data php /var/www/nextcloud/occ "$@" </dev/null; }
redis-cli ping | grep -q PONG
printf 'apc.enable_cli=1\n' > /etc/php/8.4/cli/conf.d/99-nextcloud-apcu.ini
occ config:system:set memcache.local --value='\OC\Memcache\APCu'
occ config:system:set memcache.distributed --value='\OC\Memcache\Redis'
occ config:system:set memcache.locking --value='\OC\Memcache\Redis'
occ config:system:set redis host --value=127.0.0.1
occ config:system:set redis port --value=6379 --type=integer
occ config:system:set filelocking.enabled --value=true --type=boolean
occ config:system:set default_phone_region --value=FR
occ config:system:set maintenance_window_start --value=2 --type=integer
cat > /etc/systemd/system/nextcloud-cron.service <<'EOF'
[Unit]
Description=Nextcloud background jobs
After=mariadb.service

[Service]
Type=oneshot
User=www-data
ExecStart=/usr/bin/php -f /var/www/nextcloud/cron.php
EOF
cat > /etc/systemd/system/nextcloud-cron.timer <<'EOF'
[Unit]
Description=Nextcloud background jobs every 5 minutes

[Timer]
OnBootSec=5min
OnUnitActiveSec=5min
Unit=nextcloud-cron.service

[Install]
WantedBy=timers.target
EOF
systemctl daemon-reload
systemctl enable --now nextcloud-cron.timer
REMOTE
}

# Lot 2 : vhost nginx (sauvegarde, nginx -t avec retour arriere automatique, reload).
vhost() {
  cat "${WORKDIR}/nginx/cloud.lslinux.org.conf" | ${SSH} "cat > /tmp/cloud.vhost" || exit 1
  ${SUSSH} "sh -s" <<'REMOTE' || exit 1
set -e
f=/etc/nginx/sites-available/cloud.lslinux.org
cp -p "${f}" "/root/cloud.lslinux.org.pre-$(date +%Y%m%d%H%M)"
bak="$(ls -t /root/cloud.lslinux.org.pre-* | head -1)"
install -m 0644 /tmp/cloud.vhost "${f}"
rm -f /tmp/cloud.vhost
if ! nginx -t; then cp -p "${bak}" "${f}"; echo "nginx -t KO : ancien vhost restaure" >&2; exit 1; fi
systemctl reload nginx
REMOTE
}

# Lot 3 : tables en ROW_FORMAT=DYNAMIC (maintenance + dump prealable).
rowformat() {
  ${SUSSH} "sh -s" <<'REMOTE' || exit 1
set -e
occ() { sudo -u www-data php /var/www/nextcloud/occ "$@" </dev/null; }
d="$(date +%Y%m%d%H%M)"
occ maintenance:mode --on
mariadb-dump --single-transaction nextcloud > "/root/nc-pre-rowformat-${d}.sql"
test -s "/root/nc-pre-rowformat-${d}.sql"
gzip -f "/root/nc-pre-rowformat-${d}.sql"
mariadb -N -e "SELECT table_name FROM information_schema.tables WHERE table_schema='nextcloud' AND engine='InnoDB' AND row_format<>'Dynamic'" > /tmp/nc-tables.txt
n=0
while read -r t; do
  mariadb nextcloud -e "ALTER TABLE \`${t}\` ROW_FORMAT=DYNAMIC" </dev/null || { echo "ECHEC sur ${t} (maintenance laissee active ; dump /root/nc-pre-rowformat-${d}.sql.gz)" >&2; exit 1; }
  n=$((n + 1))
done < /tmp/nc-tables.txt
rm -f /tmp/nc-tables.txt
occ maintenance:mode --off
echo "${n} tables converties"
REMOTE
}

# Migration des mimetypes (longue) : unite systemd transitoire, cron en pause pendant l'operation, log dans le journal.
mimetypes() {
  ${SUSSH} "sh -s" <<'REMOTE' || exit 1
set -e
systemctl stop nextcloud-cron.timer
systemctl is-active --quiet nextcloud-cron.service && systemctl stop nextcloud-cron.service || true
systemd-run --unit=nc-mimetypes --description="Nextcloud mimetype migrations" \
  -p User=www-data -p 'ExecStopPost=+/bin/systemctl start nextcloud-cron.timer' \
  /usr/bin/php /var/www/nextcloud/occ maintenance:repair --include-expensive
REMOTE
  printf "\n=> Suivi : %s journalctl -u nc-mimetypes -f   (le timer cron redemarre tout seul a la fin)\n" "${SSH}"
}

# Limites PHP-FPM alignees sur nginx (memory_limit 128M par defaut = erreur 500 sur /settings/apps). Ne recharge pas php-fpm.
phpini() {
  cat "${WORKDIR}/php/99-nextcloud.ini" | ${SSH} "sudo tee /etc/php/8.4/fpm/conf.d/99-nextcloud.ini >/dev/null && sudo php-fpm8.4 -t" || return 1
  printf "\n=> Pour appliquer : %s systemctl reload php8.4-fpm\n" "${SUSSH}"
}

# Apps tierces hors du code (apps_paths) : elles survivent aux montees de version.
# Dossier persistant /var/lib/nextcloud/apps, lien apps-extra dans chaque code (pour nginx). A lancer une fois.
apps() {
  ${SUSSH} "sh -s" <<'REMOTE' || exit 1
set -e
occ() { sudo -u www-data php /var/www/nextcloud/occ "$@" </dev/null; }
X=/var/lib/nextcloud/apps
code="$(readlink -f /var/www/nextcloud)"
install -d -o www-data -g www-data -m 0755 "${X}"
ln -sfn "${X}" "${code}/apps-extra"
list="$(python3 -c '
import json,os
s=set(json.load(open("/var/www/nextcloud/core/shipped.json"))["shippedApps"])
d="/var/www/nextcloud/apps"
print(" ".join(sorted(x for x in os.listdir(d) if os.path.isdir(os.path.join(d,x)) and x not in s)))
')"
echo "apps tierces : ${list:-aucune}"
[ -n "${list}" ] || { echo "rien a deplacer"; exit 0; }
bkp="/root/apps-moved-$(date +%Y%m%d%H%M)"
trap 'echo "ECHEC : maintenance laissee active. Originaux dans ${bkp} (a remettre dans /var/www/nextcloud/apps), puis occ config:system:delete apps_paths" >&2' EXIT
occ maintenance:mode --on
for a in ${list}; do rsync -a "/var/www/nextcloud/apps/${a}/" "${X}/${a}/"; done
occ config:system:set apps_paths --type=json --value='[{"path":"/var/www/nextcloud/apps","url":"/apps","writable":false},{"path":"/var/lib/nextcloud/apps","url":"/apps-extra","writable":true}]'
mkdir -p "${bkp}"
for a in ${list}; do mv "/var/www/nextcloud/apps/${a}" "${bkp}/${a}"; done
for a in ${list}; do printf "%s -> " "${a}"; occ app:getpath "${a}"; done
occ app:list --shipped=false
occ maintenance:mode --off
trap - EXIT
echo "Originaux conserves dans ${bkp} (a supprimer apres validation)"
REMOTE
}

status() {
  ${SSH} "sudo systemctl status php8.4-fpm --no-pager; sudo -u www-data php /var/www/nextcloud/occ status || true"
}


case "${1}" in
  backup)  backup;;
  restore) restore;;
  upgrade) upgrade;;
  dbfix)   dbfix;;
  save)    save;;
  tune)    tune;;
  vhost)   vhost;;
  rowformat) rowformat;;
  mimetypes) mimetypes;;
  phpini)  phpini;;
  apps)    apps;;
  status)  status;;
  *)       usage;;
esac
