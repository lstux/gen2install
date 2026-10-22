#!/bin/sh
# Installe sur lslng : /usr/local/sbin/mariadb-dump-all (declenche par mariadb-dump-all.timer).
# Un dump complet par jour de semaine dans /var/backups/mariadb, repris ensuite par le snapshot nsbox.
set -e
umask 077
d=/var/backups/mariadb
mkdir -p "${d}"
f="${d}/all_$(date +%a).sql"
mariadb-dump --all-databases --single-transaction --events --routines --triggers > "${f}.tmp"
test -s "${f}.tmp"
mv "${f}.tmp" "${f}"
gzip -f "${f}"
