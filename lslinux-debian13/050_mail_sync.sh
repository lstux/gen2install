#!/bin/sh
# A lancer en ROOT SUR lslng (pas depuis le PC, pas via le server.conf habituel).
# Pull les maildirs depuis genserv vers vmail, pour les mailboxes deja
# presentes dans vmail.db. Reutilisable : relancer juste avant chaque bascule
# pour recuperer le delta final.
#
# --delete est actif en sync : un message lu/repondu change de nom cote genserv
# (suffixe :2,S...), sans --delete l'ancien nom resterait ici = doublon.
# DANGER apres la bascule d'un domaine : du courrier arrive directement sur
# lslng et --delete l'effacerait. D'ou le marquage : 'mark <domaine>' juste
# avant de basculer, et ce domaine n'est plus jamais synchronise par sync.
#
# rescue : apres la bascule, rapatrie seulement le courrier arrive sur genserv
# depuis la derniere passe sync de chaque boite (horodatage par boite). Pas de
# --delete, et on saute tout message dont la base de nom Maildir existe deja ici
# (les flags changent le suffixe :2,... cote lslng, pas la base).
#
# Usage : sh 050_mail_sync.sh {dryrun|sync} [domaine]
#         sh 050_mail_sync.sh {mark|unmark} <domaine>
#         sh 050_mail_sync.sh {rescuedry|rescue} <domaine>
#   dryrun    : simulation (rsync -n), rien n'est ecrit, juste le resume.
#   sync      : fait vraiment le transfert + chown vmail final.
#   mark      : declare le domaine "bascule" (sync/dryrun l'ignorent ensuite).
#   unmark    : retire la marque (a n'utiliser que si on revient en arriere).
#   rescuedry : liste ce que rescue rapatrierait, sans rien copier.
#   rescue    : rapatrie le courrier arrive sur genserv depuis la derniere sync.
#   [domaine] : optionnel pour dryrun/sync, sans argument = tout vmail.db.

set -u

OLD_SSH_TARGET="root@www.lslinux.org"
OLD_VMAIL_BASE="/var/spool/vmail"
NEW_VMAIL_BASE="/var/lib/vmail/vhosts"
CUTOVER_DIR="/var/lib/vmail/.cutover"
STAMP_DIR="/var/lib/vmail/.syncstamp"
VMAIL_DB="/var/lib/vmail/vmail.db"
VMAIL_UID=5000
VMAIL_GID=5000

usage() {
  exec >&2
  printf "Usage : %s {dryrun|sync} [domaine]\n" "$(basename "$0")"
  printf "        %s {mark|unmark} <domaine>\n" "$(basename "$0")"
  printf "        %s {rescuedry|rescue} <domaine>\n" "$(basename "$0")"
  exit 1
}

MODE="${1:-}"
FILTER_DOMAIN="${2:-}"

case "${FILTER_DOMAIN}" in
  *[!A-Za-z0-9.-]*) printf "Nom de domaine invalide : %s\n" "${FILTER_DOMAIN}" >&2; exit 1 ;;
esac

case "${MODE}" in
  dryrun) RSYNC_OPTS="-azn" ;;
  sync)   RSYNC_OPTS="-az" ;;
  rescue|rescuedry)
    [ -n "${FILTER_DOMAIN}" ] || usage
    [ -e "${CUTOVER_DIR}/${FILTER_DOMAIN}" ] || {
      printf "%s n'est pas marque 'bascule' : rescue refuse.\n" "${FILTER_DOMAIN}" >&2
      exit 1
    }
    ;;
  mark)
    [ -n "${FILTER_DOMAIN}" ] || usage
    mkdir -p "${CUTOVER_DIR}" && touch "${CUTOVER_DIR}/${FILTER_DOMAIN}"
    printf "%s marque 'bascule' : plus aucune synchro ne le touchera.\n" "${FILTER_DOMAIN}"
    exit 0 ;;
  unmark)
    [ -n "${FILTER_DOMAIN}" ] || usage
    rm -f "${CUTOVER_DIR}/${FILTER_DOMAIN}"
    printf "Marque retiree pour %s.\n" "${FILTER_DOMAIN}"
    exit 0 ;;
  *) usage ;;
esac

if [ -n "${FILTER_DOMAIN}" ]; then
  WHERE="WHERE domain='${FILTER_DOMAIN}'"
else
  WHERE=""
fi

LIST="/tmp/mailsync_list.$$"
OUT="/tmp/mailsync_out.$$"
sqlite3 "${VMAIL_DB}" "SELECT email, domain FROM mailboxes ${WHERE} ORDER BY domain, email;" > "${LIST}"

if [ ! -s "${LIST}" ]; then
  printf "Aucune mailbox trouvee (filtre domaine = '%s'). Rien a faire.\n" "${FILTER_DOMAIN}" >&2
  rm -f "${LIST}"
  exit 1
fi

rescue_one() {
  domain="$1"
  localpart="$2"
  src_dir="${OLD_VMAIL_BASE}/${domain}/${localpart}"
  dst="${NEW_VMAIL_BASE}/${domain}/${localpart}/mail"
  stamp_file="${STAMP_DIR}/${domain}/${localpart}"
  candidates="/tmp/rescue_cand.$$"
  todo="/tmp/rescue_todo.$$"

  if [ ! -s "${stamp_file}" ]; then
    printf "  ECHEC : pas d'horodatage de derniere synchro (%s), rien n'est touche.\n" "${stamp_file}" >&2
    return 1
  fi
  stamp=$(cat "${stamp_file}")

  if ! ssh -n -4 -o BatchMode=yes "${OLD_SSH_TARGET}" "cd '${src_dir}' && find cur new -type f -newermt @${stamp}" > "${candidates}" 2>/dev/null; then
    printf "  ECHEC : listing genserv impossible pour %s@%s, rien n'est touche.\n" "${localpart}" "${domain}" >&2
    rm -f "${candidates}"
    return 1
  fi

  : > "${todo}"
  while IFS= read -r rel; do
    [ -n "${rel}" ] || continue
    name="${rel##*/}"
    base="${name%%:2,*}"
    if ls "${dst}"/cur/"${base}"* "${dst}"/new/"${base}"* >/dev/null 2>&1; then
      continue
    fi
    printf '%s\n' "${rel}" >> "${todo}"
  done < "${candidates}"

  n=$(wc -l < "${todo}" | tr -d ' ')
  printf "  %s message(s) a rapatrier (arrives sur genserv depuis le %s)\n" "${n}" "$(date -d "@${stamp}" '+%d/%m %H:%M')"

  if [ "${n}" -eq 0 ] || [ "${MODE}" = "rescuedry" ]; then
    [ "${n}" -gt 0 ] && head -n 5 "${todo}" | sed 's/^/    /'
    rm -f "${candidates}" "${todo}"
    return 0
  fi

  mkdir -p "${dst}/cur" "${dst}/new" "${dst}/tmp"
  rsync -a --files-from="${todo}" -e "ssh -4" "${OLD_SSH_TARGET}:${src_dir}/" "${dst}/" </dev/null
  rc=$?
  rm -f "${candidates}" "${todo}"
  if [ "${rc}" -ne 0 ]; then
    printf "  ECHEC rsync (code %s) pour %s@%s\n" "${rc}" "${localpart}" "${domain}" >&2
    return 1
  fi
  return 0
}

FAILED=0

while IFS='|' read -r email domain; do
  localpart="${email%@*}"
  src="${OLD_SSH_TARGET}:${OLD_VMAIL_BASE}/${domain}/${localpart}/"
  dst="${NEW_VMAIL_BASE}/${domain}/${localpart}/mail/"

  printf "=== %s ===\n" "${email}"

  case "${MODE}" in
    rescue|rescuedry)
      rescue_one "${domain}" "${localpart}" || FAILED=1
      continue ;;
  esac

  if [ -e "${CUTOVER_DIR}/${domain}" ]; then
    printf "  IGNORE : %s est marque 'bascule', plus de synchro.\n" "${domain}"
    continue
  fi

  if [ "${MODE}" = "sync" ]; then
    mkdir -p "${dst}" "${STAMP_DIR}/${domain}"
    date +%s > "${STAMP_DIR}/${domain}/${localpart}"
  fi

  # Garde-fou : jamais de --delete depuis une source introuvable/vide.
  if ! ssh -n -4 -o BatchMode=yes "${OLD_SSH_TARGET}" "test -d '${OLD_VMAIL_BASE}/${domain}/${localpart}/cur'"; then
    # Boite jamais utilisee : dossier present mais sans structure Maildir.
    # Acceptable seulement si la destination n'a rien a perdre.
    if ssh -n -4 -o BatchMode=yes "${OLD_SSH_TARGET}" "test -d '${OLD_VMAIL_BASE}/${domain}/${localpart}'" \
       && [ ! -d "${dst}cur" ]; then
      printf "  Boite vide cote source (jamais de courrier), rien a faire.\n"
      continue
    fi
    printf "  ECHEC : source introuvable (%s/%s/%s/cur), rien n'est touche.\n" "${OLD_VMAIL_BASE}" "${domain}" "${localpart}" >&2
    FAILED=1
    continue
  fi

  rsync ${RSYNC_OPTS} --delete \
        --exclude='courier*' --exclude='dovecot*' --exclude='subscriptions' \
        -e "ssh -4" --stats "${src}" "${dst}" > "${OUT}" 2>&1
  rc=$?

  grep -E "Number of files|Number of deleted files|Total transferred file size" "${OUT}"
  if [ "${rc}" -ne 0 ]; then
    printf "  ECHEC rsync (code %s) pour %s :\n" "${rc}" "${email}" >&2
    grep -E "rsync(:| error)" "${OUT}" | head -5 >&2
    FAILED=1
  fi
done < "${LIST}"
rm -f "${LIST}" "${OUT}"

if [ "${MODE}" = "sync" ] || [ "${MODE}" = "rescue" ]; then
  chown -R "${VMAIL_UID}:${VMAIL_GID}" "${NEW_VMAIL_BASE}"
  printf "\nTermine, proprietes vmail reappliquees sur %s.\n" "${NEW_VMAIL_BASE}"
fi
if [ "${MODE}" = "sync" ]; then
  printf "Avant la bascule d'un domaine : derniere passe 'sync', puis 'mark <domaine>'.\n"
elif [ "${MODE}" = "dryrun" ]; then
  printf "\nDry-run termine, rien n'a ete ecrit.\n"
fi

if [ "${FAILED}" -ne 0 ]; then
  printf "ATTENTION : au moins une mailbox en echec, voir les messages ci-dessus.\n" >&2
  exit 1
fi
