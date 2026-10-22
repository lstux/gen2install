#!/bin/sh
# A lancer en ROOT sur lslng. Dovecot (Maildir++) attend des noms de dossiers en
# UTF-7 modifie (Co&AOs-t) ; certains dossiers herites de genserv sont en UTF-8
# brut (Coët) : listes mais inaccessibles en IMAP. Ce script les renomme.
# A lancer APRES la derniere passe 050_mail_sync.sh (sinon --delete les efface
# et le sync les recree) ; une fois le domaine marque 'bascule' plus rien ne
# les recree.
#
# Usage : sh fix_utf8_folders.sh {dry|apply} [domaine]
#   dry   : liste ce qui serait renomme.
#   apply : renomme (mv ne remplace jamais : refus si la cible existe).
# Ne touche que les repertoires de premier niveau de mail/ dont le nom commence
# par '.', contient un octet non ASCII et aucun '&' (deja encode ou ambigu).

set -u

BASE="/var/lib/vmail/vhosts"
MODE="${1:-}"
DOM="${2:-*}"
case "${MODE}" in dry|apply) ;; *) printf "Usage : %s {dry|apply} [domaine]\n" "$(basename "$0")" >&2; exit 1 ;; esac
case "${DOM}" in *[!A-Za-z0-9.*-]*) printf "Domaine invalide\n" >&2; exit 1 ;; esac
command -v python3 >/dev/null 2>&1 || { printf "python3 requis\n" >&2; exit 1; }

RC=0
for dir in "${BASE}"/${DOM}/*/mail/.*; do
  [ -d "${dir}" ] || continue
  name="${dir##*/}"
  case "${name}" in .|..) continue ;; esac
  # non ASCII ?
  printf '%s' "${name}" | LC_ALL=C grep -q '[^ -~]' || continue
  case "${name}" in *\&*) printf "IGNORE (contient &) : %s\n" "${dir}" >&2; continue ;; esac
  new="$(python3 -I - "${name}" <<'PY'
import sys, base64
s = sys.argv[1].encode('utf-8', 'surrogateescape').decode('utf-8')
out, buf = [], []
def flush():
    if buf:
        b = ''.join(buf).encode('utf-16-be')
        out.append('&' + base64.b64encode(b).decode().rstrip('=').replace('/', ',') + '-')
        buf.clear()
for c in s:
    if 0x20 <= ord(c) <= 0x7e:
        flush(); out.append(c)
    else:
        buf.append(c)
flush()
print(''.join(out))
PY
)" || { printf "ECHEC conversion : %s\n" "${dir}" >&2; RC=1; continue; }
  target="${dir%/*}/${new}"
  if [ -e "${target}" ]; then
    # Cible deja la (ex. creee par Dovecot) : fusion des messages, a condition
    # qu'aucun nom de base (avant ':2,') ne soit commun, sinon on ne touche a rien.
    common="$( { ls "${dir}/cur" "${dir}/new" 2>/dev/null; echo ---; ls "${target}/cur" "${target}/new" 2>/dev/null; } \
      | sed 's/:.*//' | awk '/^---$/ {t=1; next} /^[^ ]+$/ { if (t) { if (seen[$0]) c++ } else seen[$0]=1 } END {print c+0}')"
    if [ "${common}" -ne 0 ]; then
      printf "ECHEC cible existe et %s nom(s) en commun : %s\n" "${common}" "${target}" >&2; RC=1; continue
    fi
    printf "%s\n   => FUSION dans %s (%s msg)\n" "${dir}" "${target}" "$(ls "${dir}/cur" "${dir}/new" 2>/dev/null | grep -vc ':$')"
    if [ "${MODE}" = "apply" ]; then
      for sub in cur new; do
        [ -d "${dir}/${sub}" ] || continue
        find "${dir}/${sub}" -mindepth 1 -maxdepth 1 -type f -exec mv -n -t "${target}/${sub}" -- {} + \
          || { printf "ECHEC mv dans %s\n" "${dir}/${sub}" >&2; RC=1; }
      done
      # Le dossier d'origine ne doit plus contenir de message avant suppression
      if [ -z "$(find "${dir}/cur" "${dir}/new" -type f 2>/dev/null)" ]; then
        rm -rf -- "${dir}"
      else
        printf "ECHEC : %s non vide, conserve.\n" "${dir}" >&2; RC=1
      fi
    fi
    continue
  fi
  printf "%s\n   -> %s\n" "${dir}" "${target}"
  if [ "${MODE}" = "apply" ]; then
    mv -n -- "${dir}" "${target}" || { printf "ECHEC mv\n" >&2; RC=1; }
  fi
done
exit "${RC}"
