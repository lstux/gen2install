#!/bin/sh
# A lancer en ROOT sur lslng. Fixe le CNAME d'un nom d'une zone : remplace la cible
# d'un CNAME existant (TTL conserve) ou ajoute la ligne en fin de zone si le nom
# n'existe pas du tout. Refuse si le nom porte deja d'autres enregistrements (un CNAME
# ne cohabite avec rien) ou plusieurs CNAME. Le nom peut etre "*" (wildcard).
# Jamais de CNAME en cible MX.
# Serial lu par named-checkzone, incremente sur sa premiere occurrence.
# Sauvegarde, validation, diff, reload de la zone seule. Idempotent.
#
# Usage : sh set_cname.sh <domaine> <nom> <cible>      (cible relative ou FQDN avec point final)
#   ex. : sh set_cname.sh lslinux.org www lslng
#         sh set_cname.sh lslinux.org '*' www
# Variables : ZONEDIR (defaut /etc/bind/zones), BACKUPDIR (defaut /root/zone_backups)

set -u
ZONEDIR="${ZONEDIR:-/etc/bind/zones}"
BACKUPDIR="${BACKUPDIR:-/root/zone_backups}"

[ "$#" -eq 3 ] || { printf "Usage : %s <domaine> <nom> <cible>\n" "$(basename "$0")" >&2; exit 1; }
domain="$1"; name="$2"; target="$3"
case "${domain}" in *[!A-Za-z0-9.-]*|'') printf "Domaine invalide : %s\n" "${domain}" >&2; exit 1 ;; esac
case "${name}"   in '*'|'*'.[A-Za-z0-9_.-]*) ;; *[!A-Za-z0-9_.-]*|''|@|.*|*.) printf "Nom invalide : %s\n" "${name}" >&2; exit 1 ;; esac
case "${target}" in *[!A-Za-z0-9_.-]*|''|.*) printf "Cible invalide : %s\n" "${target}" >&2; exit 1 ;; esac

zf="${ZONEDIR}/${domain}.zone"
[ -f "${zf}" ] || { printf "[%s] fichier introuvable : %s\n" "${domain}" "${zf}" >&2; exit 1; }

# Pour chaque ligne : proprietaire (herite si ligne indentee) + type -> compte CNAME et autres types du nom
stats="$(awk -v nm="${name}" '
  BEGIN { split("A AAAA CNAME MX NS TXT SRV CAA PTR SPF DS TLSA", T, " "); for (k in T) typ[T[k]] = 1 }
  /^[ \t]*$/ || /^[ \t]*;/ || /^\$/ { next }
  { if (substr($0,1,1) !~ /[ \t]/) own = $1
    if (own != nm) next
    for (i = 1; i <= NF; i++) if ($i in typ) { if ($i == "CNAME") c++; else o++; break } }
  END { print c + 0, o + 0 }' "${zf}")"
# REPLACE_ADDR=1 : les A/AAAA du nom (et eux seuls) sont remplaces par le CNAME
if [ "${REPLACE_ADDR:-0}" = 1 ]; then
  naddr="$(awk -v nm="${name}" '
    /^[ \t]*$/ || /^[ \t]*;/ || /^\$/ { next }
    { if (substr($0,1,1) !~ /[ \t]/) own = $1
      if (own != nm) next
      for (i = 1; i <= NF; i++) if ($i == "A" || $i == "AAAA") { n++; break } }
    END { print n + 0 }' "${zf}")"
  stats="${stats% *} $(( ${stats#* } - naddr ))"
fi
ncname="${stats% *}"; nother="${stats#* }"
[ "${nother}" -eq 0 ] || { printf "[%s] %s porte deja %s enregistrement(s) non CNAME : refus.\n" "${domain}" "${name}" "${nother}" >&2; exit 1; }
[ "${ncname}" -le 1 ] || { printf "[%s] %s : %s CNAME (attendu 0 ou 1), rien n'est touche.\n" "${domain}" "${name}" "${ncname}" >&2; exit 1; }

if [ "${ncname}" -eq 1 ]; then
  curt="$(awk -v nm="${name}" '
    substr($0,1,1) !~ /[ \t;$]/ && $1 == nm { for (i = 1; i < NF; i++) if ($i == "CNAME") { print $(i+1); exit } }' "${zf}")"
  [ "${curt}" = "${target}" ] && { printf "[%s] %s deja CNAME %s, rien a faire.\n" "${domain}" "${name}" "${target}"; exit 0; }
fi

cur_serial="$(named-checkzone "${domain}" "${zf}" 2>/dev/null | sed -n 's/.*loaded serial \([0-9]*\).*/\1/p')"
[ -n "${cur_serial}" ] || { printf "[%s] zone actuelle invalide ou serial illisible, rien n'est touche.\n" "${domain}" >&2; exit 1; }
new_serial=$((cur_serial + 1))

mkdir -p "${BACKUPDIR}"
bak="${BACKUPDIR}/${domain}.zone.bak.$(date +%Y%m%d%H%M%S).$$"
cp -p "${zf}" "${bak}"
tmp="${zf}.tmp.$$"
log="/tmp/set_cname.$$.log"

awk -v old="${cur_serial}" -v new="${new_serial}" -v nm="${name}" -v tg="${target}" -v exists="${ncname}" -v repl="${REPLACE_ADDR:-0}" '
  !sdone && $0 ~ ("(^|[^0-9])" old "([^0-9]|$)") { sub(old, new); sdone=1 }
  repl == 1 && $0 !~ /^[ \t]*($|;)/ && $0 !~ /^\$/ {
    if (substr($0,1,1) !~ /[ \t]/) own = $1
    if (own == nm) { isaddr = 0; for (i = 1; i <= NF; i++) if ($i == "A" || $i == "AAAA") isaddr = 1; if (isaddr) next }
  }
  exists == 1 && substr($0,1,1) !~ /[ \t;$]/ && $1 == nm {
    for (i = 1; i < NF; i++) if ($i == "CNAME") { $(i+1) = tg; break }
    printf "%s\t", $1; for (j = 2; j <= NF; j++) printf "%s%s", $j, (j < NF ? "\t" : "\n"); next
  }
  { print }
  END { if (exists != 1) printf "%s\tIN\tCNAME\t%s\n", nm, tg }
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
