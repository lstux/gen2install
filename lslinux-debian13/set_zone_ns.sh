#!/bin/sh
# A lancer en ROOT. Remplace le jeu de NS du haut de zone (lignes "IN NS" sans
# nom, donc rattachees au domaine) par la liste donnee, a la place de la
# premiere. Necessaire car le registrar (OVH) verifie que chaque serveur DNS
# declare figure dans le jeu de NS de la zone.
#
# Usage : sh set_zone_ns.sh <domaine> <ns1.> <ns2.> [<ns3.>...]   (noms absolus, point final)
# Variables : ZONEDIR (defaut /var/bind/pri), BACKUPDIR (defaut /root/zone_backups)

set -u

ZONEDIR="${ZONEDIR:-/var/bind/pri}"
BACKUPDIR="${BACKUPDIR:-/root/zone_backups}"
RX='^[[:space:]]+IN[[:space:]]+NS[[:space:]]'

[ "$#" -ge 2 ] || { printf "Usage: %s <domaine> <ns1.> [<ns2.>...]\n" "$0" >&2; exit 1; }
domain="$1"; shift
for ns in "$@"; do
  case "${ns}" in *.) ;; *) printf "Nom NS sans point final : %s\n" "${ns}" >&2; exit 1 ;; esac
  case "${ns}" in *[!A-Za-z0-9.-]*) printf "Nom NS invalide : %s\n" "${ns}" >&2; exit 1 ;; esac
done
NSLIST="$*"

zf="${ZONEDIR}/${domain}.zone"
[ -f "${zf}" ] || { printf "[%s] fichier introuvable : %s\n" "${domain}" "${zf}" >&2; exit 1; }
mkdir -p "${BACKUPDIR}"

n="$(grep -cE "${RX}" "${zf}")"
if [ "${n}" -lt 1 ]; then
  printf "[%s] aucune ligne NS de haut de zone trouvee, rien n'est touche.\n" "${domain}" >&2
  exit 1
fi

cur_serial="$(awk 'NR==2{getline; gsub(/[^0-9]/,""); print; exit}' "${zf}")"
new_serial=$((cur_serial + 1))
bak="${BACKUPDIR}/${domain}.zone.bak.$(date +%Y%m%d%H%M%S)"
cp "${zf}" "${bak}"

awk -v old="${cur_serial}" -v new="${new_serial}" -v nsl="${NSLIST}" '
  BEGIN { cnt = split(nsl, a, " ") }
  !done && $0 ~ old { sub(old, new); done=1 }
  /^[[:space:]]+IN[[:space:]]+NS[[:space:]]/ {
    if (!emitted) { for (i = 1; i <= cnt; i++) printf "\t\tIN\tNS\t%s\n", a[i]; emitted=1 }
    next
  }
  { print }
' "${zf}" > "${zf}.tmp"

if named-checkzone "${domain}" "${zf}.tmp" >/tmp/set_ns.$$.log 2>&1; then
  mv "${zf}.tmp" "${zf}"
  printf "[%s] OK, serial %s -> %s, NS = %s. Diff :\n" "${domain}" "${cur_serial}" "${new_serial}" "${NSLIST}"
  diff -u "${bak}" "${zf}" | sed 's/^/    /'
  rm -f /tmp/set_ns.$$.log
  rndc reload >/dev/null 2>&1 && printf "rndc reload OK\n" || { printf "ECHEC rndc reload\n" >&2; exit 1; }
else
  printf "[%s] ECHEC validation, zone NON modifiee :\n" "${domain}" >&2
  cat /tmp/set_ns.$$.log >&2
  rm -f "${zf}.tmp" /tmp/set_ns.$$.log
  exit 1
fi
