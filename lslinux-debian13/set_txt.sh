#!/bin/sh
# A lancer en ROOT sur lslng. Remplace (ou cree) l'enregistrement TXT <nom> d'une
# zone. Nom explicite et relatif a la zone (pas l'apex : une ligne sans nom
# reprend celui de la precedente). Exactement 0 ou 1 ligne existante attendue,
# sur une seule ligne, sinon rien n'est touche. Idempotent.
# Serial : lu par named-checkzone (independant de la mise en forme de la SOA),
# incremente sur sa premiere occurrence. Sauvegarde, validation, diff, reload
# de la zone seule.
#
# Usage : sh set_txt.sh <domaine> <nom> <valeur> [ttl]
#   ex. : sh set_txt.sh lslinux.org _dmarc "v=DMARC1; p=none; rua=mailto:el@ruedesrancy.org"
# Variables : ZONEDIR (defaut /etc/bind/zones), BACKUPDIR (defaut /root/zone_backups)

set -u

ZONEDIR="${ZONEDIR:-/etc/bind/zones}"
BACKUPDIR="${BACKUPDIR:-/root/zone_backups}"

usage() {
  printf "Usage : %s <domaine> <nom> <valeur> [ttl]\n" "$(basename "$0")" >&2
  exit 1
}

[ "$#" -eq 3 ] || [ "$#" -eq 4 ] || usage
domain="$1"; name="$2"; value="$3"; ttl="${4:-}"
case "${domain}" in *[!A-Za-z0-9.-]*|'') printf "Domaine invalide : %s\n" "${domain}" >&2; exit 1 ;; esac
case "${name}"   in *[!A-Za-z0-9_.-]*|''|@|.*|*.) printf "Nom invalide : %s\n" "${name}" >&2; exit 1 ;; esac
case "${value}"  in *[\"\\]*|'') printf "Valeur invalide (ni guillemet ni antislash)\n" >&2; exit 1 ;; esac
[ "${#value}" -le 255 ] || { printf "Valeur > 255 caracteres, non geree ici\n" >&2; exit 1; }
case "${ttl}"    in *[!0-9]*) printf "TTL invalide : %s\n" "${ttl}" >&2; exit 1 ;; esac

zf="${ZONEDIR}/${domain}.zone"
[ -f "${zf}" ] || { printf "[%s] fichier introuvable : %s\n" "${domain}" "${zf}" >&2; exit 1; }

# Nom echappe pour la regex (les points)
ename="$(printf '%s' "${name}" | sed 's/\./\\./g')"
RX="^${ename}[[:space:]]"
n="$(grep -cE "${RX}" "${zf}")"
[ "${n}" -le 1 ] || { printf "[%s] %s lignes '%s' (attendu 0 ou 1), rien n'est touche.\n" "${domain}" "${n}" "${name}" >&2; exit 1; }
if [ "${n}" -eq 1 ]; then
  line="$(grep -E "${RX}" "${zf}")"
  printf '%s' "${line}" | grep -qE '[[:space:]]TXT[[:space:]]+"[^"]*"[[:space:]]*$' || {
    printf "[%s] la ligne '%s' existante n'est pas un TXT simple sur une ligne, rien n'est touche :\n    %s\n" "${domain}" "${name}" "${line}" >&2
    exit 1
  }
  if [ "$(printf '%s' "${line}" | sed -E 's/.*TXT[[:space:]]+"([^"]*)".*/\1/')" = "${value}" ]; then
    printf "[%s] %s TXT deja a la bonne valeur, rien a faire.\n" "${domain}" "${name}"
    exit 0
  fi
fi

cur_serial="$(named-checkzone "${domain}" "${zf}" 2>/dev/null | sed -n 's/.*loaded serial \([0-9]*\).*/\1/p')"
[ -n "${cur_serial}" ] || { printf "[%s] zone actuelle invalide ou serial illisible, rien n'est touche.\n" "${domain}" >&2; exit 1; }
new_serial=$((cur_serial + 1))

if [ -n "${ttl}" ]; then
  rr="$(printf '%s\t%s\tIN\tTXT\t"%s"' "${name}" "${ttl}" "${value}")"
else
  rr="$(printf '%s\tIN\tTXT\t"%s"' "${name}" "${value}")"
fi

mkdir -p "${BACKUPDIR}"
# PID en suffixe : deux appels dans la meme seconde ne s'ecrasent pas
bak="${BACKUPDIR}/${domain}.zone.bak.$(date +%Y%m%d%H%M%S).$$"
cp -p "${zf}" "${bak}"
tmp="${zf}.tmp.$$"
log="/tmp/set_txt.$$.log"

# Remplacement en place si la ligne existe, sinon ajout en fin de zone
awk -v old="${cur_serial}" -v new="${new_serial}" -v nm="${name}" -v rr="${rr}" '
  !sdone && $0 ~ ("(^|[^0-9])" old "([^0-9]|$)") { sub(old, new); sdone=1 }
  index($0, nm) == 1 && substr($0, length(nm) + 1, 1) ~ /[ \t]/ { print rr; rdone=1; next }
  { print }
  END { if (!rdone) print rr }
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
