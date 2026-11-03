#!/bin/sh
WORKDIR="$(dirname "${0}")"
. "${WORKDIR}/server.conf"

# Empreinte de la cle du depot apt Grafana (verifiee par Eric).
GRAFANA_FPR="B53AE77BADB630A683046005963FA27710458545"

usage() {
  exec >&2
  printf "Usage : %s {packages|configure|activate|reload|status}\n" "$(basename "${0}")"
  printf "  configure : ecrit la config (127.0.0.1), vhost grafana, utilisateur MariaDB ; ne demarre rien\n"
  printf "  activate  : reload php-fpm/nginx/bind (rndc reconfig), demarre les services\n"
  printf "  reload    : recharge prometheus, relance alertmanager et grafana apres un configure\n"
  printf "  packages : depot Grafana (cle epinglee) + prometheus, exporters, alertmanager, grafana (services NON demarres)\n"
}

# Les paquets Debian demarrent leurs services a l'installation (ecoute sur toutes les
# interfaces) : policy-rc.d les bloque le temps de configurer.
packages() {
  ${SUSSH} "env GRAFANA_FPR=${GRAFANA_FPR} sh -s" <<'REMOTE' || exit 1
set -e
printf '#!/bin/sh\nexit 101\n' > /usr/sbin/policy-rc.d
chmod 0755 /usr/sbin/policy-rc.d
trap 'rm -f /usr/sbin/policy-rc.d' EXIT

install -d -m 0755 /etc/apt/keyrings
curl -fsSL https://apt.grafana.com/gpg.key -o /tmp/grafana.key
gpg --show-keys --with-colons /tmp/grafana.key | grep -q "^fpr:::::::::${GRAFANA_FPR}:"
install -m 0644 /tmp/grafana.key /etc/apt/keyrings/grafana.asc
rm -f /tmp/grafana.key
cat > /etc/apt/sources.list.d/grafana.sources <<'EOF'
Types: deb
URIs: https://apt.grafana.com
Suites: stable
Components: main
Signed-By: /etc/apt/keyrings/grafana.asc
EOF

apt-get update
DEBIAN_FRONTEND=noninteractive apt-get -y install \
  prometheus prometheus-alertmanager prometheus-node-exporter \
  prometheus-mysqld-exporter prometheus-nginx-exporter prometheus-bind-exporter \
  prometheus-postfix-exporter prometheus-phpfpm-exporter mtail grafana
REMOTE
}

# Ecrit toute la configuration (ecoute sur 127.0.0.1 uniquement). Ne demarre ni ne recharge aucun service.
configure() {
  tar cf - -C "${WORKDIR}/monitoring" . | ${SSH} "rm -rf /tmp/mon && mkdir /tmp/mon && tar xf - -C /tmp/mon" || exit 1
  cat "${WORKDIR}/nginx/grafana.lslinux.org.conf" | ${SSH} "cat > /tmp/mon/grafana.lslinux.org.conf" || exit 1
  ${SUSSH} "sh -s" <<'REMOTE' || exit 1
set -e
M=/tmp/mon
setargs() { sed -i "s|^ARGS=.*|ARGS=\"$2\"|" "/etc/default/$1"; }

# Prometheus + exporters (127.0.0.1)
setargs prometheus "--web.listen-address=127.0.0.1:9090 --storage.tsdb.retention.time=30d"
setargs prometheus-alertmanager "--web.listen-address=127.0.0.1:9093 --cluster.listen-address="
setargs prometheus-node-exporter "--web.listen-address=127.0.0.1:9100 --collector.textfile.directory=/var/lib/prometheus/node-exporter"
setargs prometheus-mysqld-exporter "--web.listen-address=127.0.0.1:9104 --config.my-cnf=/etc/prometheus/mysqld.cnf"
setargs prometheus-nginx-exporter "--web.listen-address=127.0.0.1:9113 --nginx.scrape-uri=http://127.0.0.1:8080/stub_status"
setargs prometheus-bind-exporter "--web.listen-address=127.0.0.1:9119 --bind.stats-url=http://127.0.0.1:8053/"
setargs prometheus-postfix-exporter "--web.listen-address=127.0.0.1:9154 --postfix.logfile_path=/var/log/mail.log"
setargs prometheus-phpfpm-exporter "--web.listen-address=127.0.0.1:9253 --phpfpm.socket-paths=/run/php/php8.4-fpm.sock"
printf '[client]\nuser=prometheus\nsocket=/run/mysqld/mysqld.sock\n' > /etc/prometheus/mysqld.cnf
chown root:prometheus /etc/prometheus/mysqld.cnf
chmod 0640 /etc/prometheus/mysqld.cnf
install -m 0644 -o root -g root $M/prometheus.yml /etc/prometheus/prometheus.yml
install -m 0644 -o root -g root $M/alerts.yml /etc/prometheus/alerts.yml
install -m 0644 -o root -g root $M/alertmanager.yml /etc/prometheus/alertmanager.yml
promtool check config /etc/prometheus/prometheus.yml
amtool check-config /etc/prometheus/alertmanager.yml

# MariaDB : utilisateur de monitoring (socket unix, sans mot de passe)
mariadb -e "CREATE USER IF NOT EXISTS 'prometheus'@'localhost' IDENTIFIED VIA unix_socket; GRANT PROCESS, REPLICATION CLIENT, SELECT ON *.* TO 'prometheus'@'localhost';"

# Droits de lecture : mail.log (adm), socket php-fpm (www-data)
usermod -aG adm,www-data prometheus

# nginx : stub_status local + vhost Grafana (nginx -t, pas de reload)
install -m 0644 $M/stub_status.conf /etc/nginx/conf.d/stub_status.conf
install -m 0644 $M/grafana.lslinux.org.conf /etc/nginx/sites-available/grafana.lslinux.org
ln -sfn ../sites-available/grafana.lslinux.org /etc/nginx/sites-enabled/grafana.lslinux.org
nginx -t

# php-fpm : page de statut (joignable uniquement via la socket FastCGI)
sed -i 's|^;pm.status_path = .*|pm.status_path = /status|' /etc/php/8.4/fpm/pool.d/www.conf
php-fpm8.4 -t

# bind : canal de statistiques sur 127.0.0.1:8053
install -m 0644 -o root -g bind $M/named.conf.stats /etc/bind/named.conf.stats
grep -q 'named.conf.stats' /etc/bind/named.conf || echo 'include "/etc/bind/named.conf.stats";' >> /etc/bind/named.conf
named-checkconf

# Grafana : 127.0.0.1:3000, pas d'inscription, mot de passe admin genere
install -d -m 0755 /etc/grafana/provisioning/datasources /etc/systemd/system/grafana-server.service.d
install -m 0644 $M/grafana-datasource.yml /etc/grafana/provisioning/datasources/prometheus.yml
install -d -m 0755 /etc/grafana/provisioning/dashboards /var/lib/grafana/dashboards
install -m 0644 $M/grafana-dashboards.yml /etc/grafana/provisioning/dashboards/lslng.yml
rm -f /var/lib/grafana/dashboards/*.json
install -m 0644 $M/dashboards/*.json /var/lib/grafana/dashboards/
if [ ! -f /etc/grafana/grafana.env ]; then
  umask 077
  cat > /etc/grafana/grafana.env <<ENV
GF_SERVER_HTTP_ADDR=127.0.0.1
GF_SERVER_DOMAIN=grafana.lslinux.org
GF_SERVER_ROOT_URL=https://grafana.lslinux.org/
GF_USERS_ALLOW_SIGN_UP=false
GF_AUTH_ANONYMOUS_ENABLED=false
GF_ANALYTICS_REPORTING_ENABLED=false
GF_ANALYTICS_CHECK_FOR_UPDATES=false
GF_SECURITY_DISABLE_GRAVATAR=true
GF_SECURITY_ADMIN_PASSWORD=$(openssl rand -base64 18)
ENV
  chown root:grafana /etc/grafana/grafana.env
  chmod 0640 /etc/grafana/grafana.env
fi
printf '[Service]\nEnvironmentFile=/etc/grafana/grafana.env\n' > /etc/systemd/system/grafana-server.service.d/override.conf
systemctl daemon-reload

# mtail (logs nginx) : 127.0.0.1:3903, un fichier de log = un vhost
install -d -m 0755 /etc/mtail
install -m 0644 $M/nginx.mtail /etc/mtail/nginx.mtail
cat > /etc/default/mtail <<MTAIL
HOST=127.0.0.1
PORT=3903
LOGS=/var/log/nginx/*.access.log
MTAIL

# fail2ban -> collecteur textfile de node-exporter (chaque minute)
install -m 0750 $M/fail2ban-textfile.sh /usr/local/sbin/fail2ban-textfile
cat > /etc/systemd/system/fail2ban-textfile.service <<SVC
[Unit]
Description=Metriques fail2ban pour node-exporter

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/fail2ban-textfile
SVC
cat > /etc/systemd/system/fail2ban-textfile.timer <<TMR
[Unit]
Description=Metriques fail2ban chaque minute

[Timer]
OnBootSec=1min
OnUnitActiveSec=1min

[Install]
WantedBy=timers.target
TMR

# MAJ Nextcloud (core + apps) -> collecteur textfile, 1x/jour. Les paquets Debian
# sont couverts par prometheus-node-exporter-apt (apt.prom), pas de doublon.
install -m 0750 $M/nextcloud-updates-textfile.sh /usr/local/sbin/nextcloud-updates-textfile
cat > /etc/systemd/system/nextcloud-updates-textfile.service <<SVC
[Unit]
Description=Metriques MAJ Nextcloud pour node-exporter

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/nextcloud-updates-textfile
SVC
cat > /etc/systemd/system/nextcloud-updates-textfile.timer <<TMR
[Unit]
Description=Metriques MAJ Nextcloud chaque jour

[Timer]
OnBootSec=10min
OnUnitActiveSec=1d

[Install]
WantedBy=timers.target
TMR
systemctl daemon-reload
rm -rf $M
REMOTE
  printf "\n=> Configuration ecrite, rien de demarre. Ensuite : sh %s activate (recharge php-fpm, nginx, bind ; demarre les services)\n" "$(basename "${0}")"
}

# A lancer apres validation d'Eric : recharges et demarrages.
activate() {
  ${SUSSH} "sh -s" <<'REMOTE' || exit 1
set -e
systemctl reload php8.4-fpm
nginx -t && systemctl reload nginx
rndc reconfig
systemctl enable --now rsyslog
systemctl enable --now prometheus-node-exporter prometheus-mysqld-exporter prometheus-nginx-exporter \
  prometheus-bind-exporter prometheus-postfix-exporter prometheus-phpfpm-exporter \
  prometheus-alertmanager prometheus grafana-server
systemctl enable --now prometheus-node-exporter-smartmon.timer prometheus-node-exporter-nvme.timer prometheus-node-exporter-apt.timer
REMOTE
}

# Applique une modification de config monitoring (alertes, dashboards, datasource).
reload() {
  ${SUSSH} "sh -s" <<'REMOTE' || exit 1
set -e
systemctl enable --now mtail fail2ban-textfile.timer nextcloud-updates-textfile.timer
systemctl reload prometheus
systemctl restart prometheus-alertmanager
systemctl restart grafana-server
REMOTE
}

status() {
  ${SSH} "systemctl is-active prometheus prometheus-alertmanager prometheus-node-exporter prometheus-mysqld-exporter prometheus-nginx-exporter prometheus-bind-exporter prometheus-postfix-exporter prometheus-phpfpm-exporter mtail grafana-server; sudo ss -tlnp | grep -E ':(9090|9093|9100|9104|9113|9119|9154|9253|3000) '"
}


case "${1}" in
  packages)  packages;;
  configure) configure;;
  activate)  activate;;
  reload)    reload;;
  status)   status;;
  *)        usage;;
esac
