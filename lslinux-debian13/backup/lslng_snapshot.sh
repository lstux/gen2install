#!/bin/sh
# Installe sur nsbox : /backup/lslng/00_snapshot.sh (root). Snapshots quotidiens de lslng (pull rsync --link-dest).
# Layout : /backup/lslng/YYYYMMDD/<dest>/ + lien "latest". Retention : 7 jours + 4 dimanches.
SRV="debian@lslng.lslinux.org"
BKPDIR="/backup/lslng"
KEY="/root/.ssh/id_lslng"
KEEP_DAYS=7
KEEP_WEEKS=4
SSHCMD="ssh -i ${KEY} -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=20"

SOURCES="
/etc                      etc
/var/lib/nextcloud/data   nextcloud
/var/lib/vmail            vmail
/var/www                  www
/var/lib/rspamd           rspamd
/var/backups/mariadb      mysql_dumps
/root                     root
"

if [ "$(id -un)" != "root" ]; then
  printf "This script should be run as root...\n" >&2
  exit 1
fi

install -d -m 0750 "${BKPDIR}" "${BKPDIR}/logs"
exec 9>"${BKPDIR}/.lock"
flock -n 9 || { printf "Sauvegarde deja en cours\n" >&2; exit 1; }

today="$(date +%Y%m%d)"
new="${BKPDIR}/.inprogress"
log="${BKPDIR}/logs/${today}.log"
prev="$(readlink "${BKPDIR}/latest" 2>/dev/null)"

if [ -d "${BKPDIR}/${today}" ]; then
  printf "Snapshot %s deja fait\n" "${today}"
  exit 0
fi

excludes() {
  case "${1}" in
    nextcloud) printf -- "--exclude=appdata_*/preview/ --exclude=nextcloud.log*";;
  esac
}

fail=0
echo "$(date) snapshot ${today} (base: ${prev:-aucune})" > "${log}"
echo "${SOURCES}" | while read src dest; do
  [ -n "${src}" ] && [ -n "${dest}" ] || continue
  link=""
  [ -n "${prev}" ] && [ -d "${BKPDIR}/${prev}/${dest}" ] && link="--link-dest=${BKPDIR}/${prev}/${dest}"
  mkdir -p "${new}/${dest}"
  # shellcheck disable=SC2046
  rsync -aH --numeric-ids --delete ${link} $(excludes "${dest}") \
    -e "${SSHCMD}" --rsync-path="sudo rsync" \
    "${SRV}:${src}/" "${new}/${dest}/" >> "${log}" 2>&1
  e=$?
  # 24 = fichiers disparus pendant la copie (normal sur un serveur en service)
  if [ ${e} -ne 0 ] && [ ${e} -ne 24 ]; then
    printf "EE=%d %s => %s\n" "${e}" "${src}" "${dest}" | tee -a "${log}"
    touch "${new}/.failed"
  else
    printf "OK    %s => %s\n" "${src}" "${dest}" >> "${log}"
  fi
done

if [ -e "${new}/.failed" ]; then
  printf "Snapshot %s incomplet : %s conserve pour reprise\n" "${today}" "${new}" >&2
  exit 1
fi

mv "${new}" "${BKPDIR}/${today}"
ln -sfn "${today}" "${BKPDIR}/latest"

now="$(date +%s)"
for s in "${BKPDIR}"/[0-9]*; do
  [ -d "${s}" ] || continue
  n="$(basename "${s}")"
  [ "${n}" = "$(readlink "${BKPDIR}/latest")" ] && continue
  ts="$(date -d "${n}" +%s 2>/dev/null)" || continue
  age=$(( (now - ts) / 86400 ))
  [ "${age}" -lt "${KEEP_DAYS}" ] && continue
  [ "$(date -d "${n}" +%u)" = "7" ] && [ "${age}" -lt $(( KEEP_WEEKS * 7 )) ] && continue
  rm -rf "${s}"
  echo "purge ${n}" >> "${log}"
done
echo "$(date) fin OK" >> "${log}"
