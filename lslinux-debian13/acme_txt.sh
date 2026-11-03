#!/bin/sh
# A lancer en ROOT. Ajoute/retire un enregistrement _acme-challenge TXT sur
# une zone, bump le serial, valide, reload. Meme script sur genserv
# (ZONEDIR=/var/bind/pri) et lslng (ZONEDIR=/etc/bind/zones), fourni via la
# variable d'environnement ACME_ZONEDIR (sinon defaut genserv).
#
# Usage : sh acme_txt.sh {add|remove} <domaine> <valeur>

set -u

ZONEDIR="${ACME_ZONEDIR:-/var/bind/pri}"
BACKUPDIR="${ACME_BACKUPDIR:-/root/zone_backups}"

ACTION="${1:-}"
DOMAIN="${2:-}"
VALUE="${3:-}"

if [ -z "${ACTION}" ] || [ -z "${DOMAIN}" ] || [ -z "${VALUE}" ]; then
  printf "Usage: %s {add|remove} <domaine> <valeur>\n" "$0" >&2
  exit 1
fi

zonefile="${ZONEDIR}/${DOMAIN}.zone"
record="_acme-challenge	IN	TXT	\"${VALUE}\""

mkdir -p "${BACKUPDIR}"

cur_serial="$(awk 'NR==2{getline; gsub(/[^0-9]/,""); print; exit}' "${zonefile}")"
new_serial=$((cur_serial + 1))

cp "${zonefile}" "${BACKUPDIR}/${DOMAIN}.zone.bak.$(date +%Y%m%d%H%M%S)"

if [ "${ACTION}" = "add" ]; then
  awk -v old="${cur_serial}" -v new="${new_serial}" '
    !done && $0 ~ old { sub(old, new); done=1 }
    { print }
  ' "${zonefile}" > "${zonefile}.tmp"
  printf '%s\n' "${record}" >> "${zonefile}.tmp"
else
  awk -v old="${cur_serial}" -v new="${new_serial}" -v val="${VALUE}" '
    !done && $0 ~ old { sub(old, new); done=1 }
    index($0, val) > 0 { next }
    { print }
  ' "${zonefile}" > "${zonefile}.tmp"
fi
mv "${zonefile}.tmp" "${zonefile}"

if named-checkzone "${DOMAIN}" "${zonefile}" >/tmp/acme_check.$$.log 2>&1; then
  if rndc reload >/tmp/acme_reload.$$.log 2>&1; then
    printf "[%s] %s OK, serial %s -> %s\n" "${DOMAIN}" "${ACTION}" "${cur_serial}" "${new_serial}"
  else
    printf "[%s] ECHEC rndc reload apres %s\n" "${DOMAIN}" "${ACTION}" >&2
    cat /tmp/acme_reload.$$.log >&2
    rm -f /tmp/acme_reload.$$.log /tmp/acme_check.$$.log
    exit 1
  fi
  rm -f /tmp/acme_reload.$$.log
else
  printf "[%s] ECHEC validation apres %s\n" "${DOMAIN}" "${ACTION}" >&2
  cat /tmp/acme_check.$$.log >&2
  rm -f /tmp/acme_check.$$.log
  exit 1
fi
rm -f /tmp/acme_check.$$.log
