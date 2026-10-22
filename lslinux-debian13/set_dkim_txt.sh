#!/bin/sh
# A lancer en ROOT. Remplace (ou cree) l'enregistrement <selecteur>._domainkey
# d'une zone par une cle publique RSA, en une seule ligne avec plusieurs chaines
# (une cle 2048 bits depasse les 255 caracteres d'une chaine TXT). TTL explicite
# 3600 pour pouvoir faire tourner la cle sans attendre le TTL par defaut de la zone.
# Exactement 0 ou 1 ligne existante attendue, sinon rien n'est touche.
#
# Usage : sh set_dkim_txt.sh <domaine> <selecteur> <cle-publique-base64>
# Variables : ZONEDIR (defaut /var/bind/pri), BACKUPDIR (defaut /root/zone_backups)

set -u

ZONEDIR="${ZONEDIR:-/var/bind/pri}"
BACKUPDIR="${BACKUPDIR:-/root/zone_backups}"

[ "$#" -eq 3 ] || { printf "Usage: %s <domaine> <selecteur> <cle-base64>\n" "$0" >&2; exit 1; }
domain="$1"; sel="$2"; key="$3"
case "${domain}" in *[!A-Za-z0-9.-]*) printf "Domaine invalide\n" >&2; exit 1 ;; esac
case "${sel}"    in *[!a-z0-9]*|'') printf "Selecteur invalide\n" >&2; exit 1 ;; esac
case "${key}"    in *[!A-Za-z0-9+/=]*|'') printf "Cle invalide (base64 attendu)\n" >&2; exit 1 ;; esac
[ "${#key}" -ge 200 ] || { printf "Cle trop courte (%s caracteres)\n" "${#key}" >&2; exit 1; }

zf="${ZONEDIR}/${domain}.zone"
[ -f "${zf}" ] || { printf "[%s] fichier introuvable : %s\n" "${domain}" "${zf}" >&2; exit 1; }
mkdir -p "${BACKUPDIR}"

RX="^${sel}\\._domainkey[[:space:]]"
n="$(grep -cE "${RX}" "${zf}")"
[ "${n}" -le 1 ] || { printf "[%s] %s lignes %s._domainkey (attendu 0 ou 1), rien n'est touche.\n" "${domain}" "${n}" "${sel}" >&2; exit 1; }
if [ "${n}" -eq 1 ] && ! grep -E "${RX}" "${zf}" | grep -q 'TXT'; then
  printf "[%s] la ligne existante n'est pas un TXT sur une seule ligne, rien n'est touche.\n" "${domain}" >&2; exit 1
fi

# Decoupe en chaines de 200 caracteres ; la 1ere porte le prefixe "v=DKIM1; k=rsa; p="
rr="$(printf '%s' "${key}" | awk -v sel="${sel}" '{
  line = sel "._domainkey\t3600\tIN\tTXT\t\"v=DKIM1; k=rsa; p="
  rest = $0; first = 1
  while (length(rest) > 0) {
    chunk = substr(rest, 1, 200); rest = substr(rest, 201)
    if (first) { line = line chunk "\""; first = 0 } else { line = line " \"" chunk "\"" }
  }
  print line }')"

cur_serial="$(awk 'NR==2{getline; gsub(/[^0-9]/,""); print; exit}' "${zf}")"
new_serial=$((cur_serial + 1))
bak="${BACKUPDIR}/${domain}.zone.bak.$(date +%Y%m%d%H%M%S)"
cp "${zf}" "${bak}"

{
  awk -v old="${cur_serial}" -v new="${new_serial}" -v pfx="${sel}._domainkey" '
    !done && NR > 2 && $0 ~ old { sub(old, new); done=1 }
    index($0, pfx) == 1 && substr($0, length(pfx) + 1, 1) ~ /[ \t]/ { next }
    { print }
  ' "${zf}"
  printf '%s\n' "${rr}"
} > "${zf}.tmp"

if named-checkzone "${domain}" "${zf}.tmp" >/tmp/set_dkim.$$.log 2>&1; then
  mv "${zf}.tmp" "${zf}"
  printf "[%s] OK, serial %s -> %s, cle %s caracteres. Diff (cle abregee) :\n" "${domain}" "${cur_serial}" "${new_serial}" "${#key}"
  diff -u "${bak}" "${zf}" | sed -E 's/p=[A-Za-z0-9+\/=]{20}[A-Za-z0-9+\/=]*/p=<...>/g; s/^/    /'
  rm -f /tmp/set_dkim.$$.log
  rndc reload >/dev/null 2>&1 && printf "rndc reload OK\n" || { printf "ECHEC rndc reload\n" >&2; exit 1; }
else
  printf "[%s] ECHEC validation, zone NON modifiee :\n" "${domain}" >&2
  cat /tmp/set_dkim.$$.log >&2
  rm -f "${zf}.tmp" /tmp/set_dkim.$$.log
  exit 1
fi
