#!/bin/sh
# A lancer en ROOT sur lslng. Remplace les enregistrements A et AAAA d'un nom
# relatif d'une zone (exactement 1 A et 1 AAAA attendus, sur une ligne chacun,
# sinon rien n'est touche ; un A sans AAAA est accepte : le AAAA est alors ajoute
# juste apres la ligne A). Le TTL existant de la ligne est conserve.
# Nom "@" = sommet de zone : lignes A/AAAA du bloc qui suit le SOA (proprietaire
# vide, "@" ou "<domaine>.") jusqu'au premier autre nom.
# Serial lu par named-checkzone, incremente sur sa premiere occurrence.
# Sauvegarde, validation, diff, reload de la zone seule. Idempotent.
#
# Usage : sh set_addr.sh <domaine> <nom|@> <ipv4> <ipv6>
#   ex. : sh set_addr.sh lslinux.org mail 145.239.67.105 2001:41d0:303:3669::1
# Variables : ZONEDIR (defaut /etc/bind/zones), BACKUPDIR (defaut /root/zone_backups)

set -u

ZONEDIR="${ZONEDIR:-/etc/bind/zones}"
BACKUPDIR="${BACKUPDIR:-/root/zone_backups}"

[ "$#" -eq 4 ] || { printf "Usage : %s <domaine> <nom|@> <ipv4> <ipv6>\n" "$(basename "$0")" >&2; exit 1; }
domain="$1"; name="$2"; v4="$3"; v6="$4"
case "${domain}" in *[!A-Za-z0-9.-]*|'') printf "Domaine invalide : %s\n" "${domain}" >&2; exit 1 ;; esac
case "${name}"   in @) ;; *[!A-Za-z0-9_.-]*|''|.*|*.) printf "Nom invalide : %s\n" "${name}" >&2; exit 1 ;; esac
case "${v4}"     in *[!0-9.]*|'') printf "IPv4 invalide : %s\n" "${v4}" >&2; exit 1 ;; esac
case "${v6}"     in *[!0-9a-fA-F:]*|'') printf "IPv6 invalide : %s\n" "${v6}" >&2; exit 1 ;; esac

zf="${ZONEDIR}/${domain}.zone"
[ -f "${zf}" ] || { printf "[%s] fichier introuvable : %s\n" "${domain}" "${zf}" >&2; exit 1; }

# Fonctions awk communes : track() suit le bloc "sommet de zone", mine() dit si la ligne est a nous
AWKLIB='
function track(l,   c, t) {
  c = substr(l, 1, 1)
  if (l ~ /^[ \t]*$/ || c == ";" || c == "$" || c == " " || c == "\t") return
  t = l; sub(/[ \t].*/, "", t)
  if (!seen) { seen = 1; ap = 1 } else ap = (t == "@" || t == dom ".")
}
function mine(l) {
  if (nm == "@") return ap
  return (index(l, nm) == 1 && substr(l, length(nm) + 1, 1) ~ /[ \t]/)
}'

count() {
  awk -v nm="${name}" -v dom="${domain}" -v ty="$1" "${AWKLIB}"'
    { track($0) }
    mine($0) { for (i = 1; i <= NF; i++) if ($i == ty) { n++; break } }
    END { print n + 0 }' "${zf}"
}
cur() {
  awk -v nm="${name}" -v dom="${domain}" -v ty="$1" "${AWKLIB}"'
    { track($0) }
    mine($0) { for (i = 1; i < NF; i++) if ($i == ty) { print $(i+1); exit } }' "${zf}"
}
na="$(count A)"; n6="$(count AAAA)"
[ "${na}" -eq 1 ] && [ "${n6}" -le 1 ] || {
  printf "[%s] %s : %s ligne(s) A et %s AAAA (attendu 1 et 0 ou 1), rien n'est touche.\n" "${domain}" "${name}" "${na}" "${n6}" >&2; exit 1; }
add6=0; [ "${n6}" -eq 0 ] && add6=1

cur4="$(cur A)"; cur6="$(cur AAAA)"
if [ "${cur4}" = "${v4}" ] && [ "${cur6}" = "${v6}" ] && [ "${add6}" -eq 0 ]; then
  printf "[%s] %s deja sur %s / %s, rien a faire.\n" "${domain}" "${name}" "${v4}" "${v6}"; exit 0
fi

cur_serial="$(named-checkzone "${domain}" "${zf}" 2>/dev/null | sed -n 's/.*loaded serial \([0-9]*\).*/\1/p')"
[ -n "${cur_serial}" ] || { printf "[%s] zone actuelle invalide ou serial illisible, rien n'est touche.\n" "${domain}" >&2; exit 1; }
new_serial=$((cur_serial + 1))

mkdir -p "${BACKUPDIR}"
bak="${BACKUPDIR}/${domain}.zone.bak.$(date +%Y%m%d%H%M%S).$$"
cp -p "${zf}" "${bak}"
tmp="${zf}.tmp.$$"
log="/tmp/set_addr.$$.log"

awk -v old="${cur_serial}" -v new="${new_serial}" -v nm="${name}" -v dom="${domain}" -v v4="${v4}" -v v6="${v6}" -v add6="${add6}" "${AWKLIB}"'
  { track($0) }
  !sdone && $0 ~ ("(^|[^0-9])" old "([^0-9]|$)") { sub(old, new); sdone=1 }
  mine($0) {
    lead = (substr($0, 1, 1) ~ /[ \t]/); hit = 0; isA = 0
    for (i = 1; i < NF; i++) {
      if ($i == "A")    { $(i+1) = v4; hit = 1; isA = 1; break }
      if ($i == "AAAA") { $(i+1) = v6; hit = 1; break }
    }
    if (hit) {
      owner = $1
      if (lead) printf "\t"
      for (j = 1; j <= NF; j++) printf "%s%s", $j, (j < NF ? "\t" : "\n")
      if (add6 && isA) printf "%sIN\tAAAA\t%s\n", (lead ? "\t" : owner "\t"), v6
      next
    }
  }
  { print }
' "${zf}" > "${tmp}"

got="$(named-checkzone "${domain}" "${tmp}" 2>"${log}" | sed -n 's/.*loaded serial \([0-9]*\).*/\1/p')"
if [ "${got}" = "${new_serial}" ]; then
  cat "${tmp}" > "${zf}" && rm -f "${tmp}" "${log}"
  printf "[%s] OK, serial %s -> %s. Diff :\n" "${domain}" "${cur_serial}" "${new_serial}"
  diff -u "${bak}" "${zf}" | sed 's/^/    /'
  rndc reload "${domain}" >/dev/null 2>&1 && printf "rndc reload %s OK\n" "${domain}" || { printf "ECHEC rndc reload %s\n" "${domain}" >&2; exit 1; }
else
  printf "[%s] ECHEC validation (serial attendu %s, lu '%s'), zone NON modifiee :\n" "${domain}" "${new_serial}" "${got}" >&2
  cat "${log}" >&2
  rm -f "${tmp}" "${log}"
  exit 1
fi
