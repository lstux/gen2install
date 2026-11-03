#!/bin/sh
# Installe sur lslng : /usr/local/sbin/nextcloud-updates-textfile (timer quotidien).
# Ecrit dans le collecteur textfile de node-exporter les mises a jour Nextcloud
# disponibles (core et apps), via 'occ update:check'. Lecture seule : n'installe rien.
# Les paquets Debian sont deja couverts par prometheus-node-exporter-apt (apt.prom).
out=/var/lib/prometheus/node-exporter/nextcloud_updates.prom
tmp="${out}.$$"
occ=/var/www/nextcloud/occ
res="$(cd /var/www/nextcloud && timeout 300 runuser -u www-data -- php "${occ}" update:check 2>&1)"
rc=$?
{
  if [ "${rc}" -eq 0 ]; then
    apps="$(printf '%s\n' "${res}" | grep -c '^Update for ')"
    core="$(printf '%s\n' "${res}" | grep -c '^Update to Nextcloud\|^Nextcloud .* is available')"
    echo "nextcloud_update_check_ok 1"
    echo "nextcloud_core_update_available ${core}"
    echo "nextcloud_apps_updates_available ${apps}"
    echo "nextcloud_update_check_timestamp_seconds $(date +%s)"
  else
    echo "nextcloud_update_check_ok 0"
  fi
} > "${tmp}"
chmod 0644 "${tmp}"
mv "${tmp}" "${out}"
