#!/bin/sh
# Installe sur lslng : /usr/local/sbin/lslng-admin (root, par 140_admin.sh install).
# Administration courante de lslng, facon armbian-config : menu whiptail, ou sous-commande.
#   sudo lslng-admin              menu
#   sudo lslng-admin status       resume (lecture seule)
#   sudo lslng-admin updates      mises a jour disponibles : apt (apres apt-get update) + Nextcloud
#   sudo lslng-admin aide         methode et commandes manuelles equivalentes
#   sudo lslng-admin help         liste des sous-commandes
# Chaque commande lancee est affichee avant execution ("$ ...", recopiable a la main).
# Toute action qui modifie quelque chose demande confirmation et est tracee dans /var/log/lslng-admin.log.
# Les redemarrages de services ne sont jamais implicites (sauf ceux faits par les postinst Debian pendant apt).
set -u

ZONES="lslinux.org ruedesrancy.org ossn.info saintmarc.bzh"
SECONDARY="sdns2.ovh.net"
SERVICES="named postfix dovecot rspamd clamav-daemon nginx php8.4-fpm mariadb redis-server fail2ban prometheus prometheus-alertmanager grafana-server mtail"
NC=/var/www/nextcloud
NC_GPG_FPR="28806A878AE423A28372792ED75899B9A724937A"
NC_URL="https://download.nextcloud.com/server/releases"
NC_SRC=/root/nc-src
NC_PROM=/var/lib/prometheus/node-exporter/nextcloud_updates.prom
VMAIL_DB=/var/lib/vmail/vmail.db
SITES_BASE=/var/www/lstux
SITES_CONF=/etc/lstux/sites.d
DUMP_DIR=/var/backups/mariadb
LOG=/var/log/lslng-admin.log

[ "$(id -u)" -eq 0 ] || { echo "A lancer en root : sudo $(basename "${0}")" >&2; exit 1; }
export LC_ALL=C.UTF-8
WT=""
[ -t 0 ] && [ -t 1 ] && command -v whiptail >/dev/null && WT=1
C=""; N=""
[ -t 2 ] && { C="$(printf '\033[36m')"; N="$(printf '\033[0m')"; }

# ---------------------------------------------------------------- outils

log() { printf '%s %s %s\n' "$(date '+%F %T')" "${SUDO_USER:-root}" "$*" >> "${LOG}"; }
ok()  { printf '  [OK] %s\n' "$*"; }
ko()  { printf '  [!!] %s\n' "$*"; }
hdr() { printf '\n== %s\n' "$*"; }

# Affichage des commandes : show "ligne shell telle quelle", x cmd args (affiche puis execute)
show() { printf '%s$ %s%s\n' "${C}" "$*" "${N}" >&2; }
q() {
  case "$1" in
    ''|*[!A-Za-z0-9_./:@%+=,-]*) printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")";;
    *) printf '%s' "$1";;
  esac
}
x() {
  _xs=""
  for _xa in "$@"; do _xs="${_xs:+${_xs} }$(q "${_xa}")"; done
  show "${_xs}"
  "$@"
}

pause() { [ -t 0 ] || return 0; printf '\nEntree pour continuer...'; read -r _; }
# Sortie courte : affichee puis "Entree" (sinon le menu whiptail repart sans laisser le temps de lire).
# Sortie longue : less. Hors terminal : cat.
page() {
  if [ -t 1 ]; then
    _pg="$(mktemp)"; cat > "${_pg}"
    if [ "$(wc -l < "${_pg}")" -lt "$(tput lines 2>/dev/null || echo 24)" ]; then cat "${_pg}"; pause; else less -FRX "${_pg}"; fi
    rm -f "${_pg}"
  else
    cat
  fi
}

# confirm "question" : non par defaut
confirm() {
  if [ -n "${WT}" ]; then
    whiptail --title lslng-admin --defaultno --yesno "$1" 20 78
  else
    printf '%s [o/N] ' "$1"; read -r r; case "${r}" in [oOyY]*) return 0;; *) return 1;; esac
  fi
}

# ask "question" [defaut] -> stdout
ask() {
  if [ -n "${WT}" ]; then
    whiptail --title lslng-admin --inputbox "$1" 12 76 "${2:-}" 3>&1 1>&2 2>&3
  else
    printf '%s [%s] ' "$1" "${2:-}" >&2; read -r r; printf '%s\n' "${r:-${2:-}}"
  fi
}

# menu "titre" tag desc [tag desc ...] -> tag choisi sur stdout (vide = retour)
menu() {
  t="$1"; shift
  if [ -n "${WT}" ]; then
    whiptail --title lslng-admin --cancel-button Retour --menu "${t}" 24 78 15 "$@" 3>&1 1>&2 2>&3
  else
    printf '\n%s\n' "${t}" >&2
    while [ $# -ge 2 ]; do printf '  %-10s %s\n' "$1" "$2" >&2; shift 2; done
    printf 'Choix (vide = retour) : ' >&2; read -r r; printf '%s\n' "${r}"
  fi
}

# occ : affiche et execute ; occq : silencieux, pour lire une valeur
occ()  { x runuser -u www-data -- php "${NC}/occ" "$@"; }
occq() { runuser -u www-data -- php "${NC}/occ" "$@"; }

# Test de conf avant (re)chargement d'un service
conftest_cmd() {
  case "${1%.service}" in
    nginx)       echo "nginx -t";;
    postfix)     echo "postfix check";;
    dovecot)     echo "doveconf -n >/dev/null";;
    named|bind9) echo "named-checkconf -z >/dev/null";;
    php8.4-fpm)  echo "php-fpm8.4 -t";;
    rspamd)      echo "rspamadm configtest";;
    fail2ban)    echo "fail2ban-client -t >/dev/null";;
    prometheus)  echo "promtool check config /etc/prometheus/prometheus.yml";;
    prometheus-alertmanager) echo "amtool check-config /etc/prometheus/alertmanager.yml";;
  esac
}
conftest() {
  c="$(conftest_cmd "$1")"
  [ -n "${c}" ] || { echo "(pas de test de conf connu pour $1)"; return 0; }
  show "${c}"
  eval "${c}"
}

# ---------------------------------------------------------------- etat

kernel_check() {
  latest="$(ls /boot/vmlinuz-* 2>/dev/null | sed 's#.*/vmlinuz-##' | sort -V | tail -1)"
  if [ -n "${latest}" ] && [ "${latest}" != "$(uname -r)" ]; then
    ko "noyau ${latest} installe, $(uname -r) en cours : reboot a prevoir"
  else
    ok "noyau $(uname -r)"
  fi
  [ -e /run/reboot-required ] && ko "/run/reboot-required present"
  return 0
}

# Unites systemd dont un processus utilise un binaire ou une bibliotheque supprimes (apres mise a jour)
stale_units() {
  for p in /proc/[0-9]*; do
    if readlink "${p}/exe" 2>/dev/null | grep -q ' (deleted)$' || \
       grep -qE ' /(usr/)?(lib|lib64|bin|sbin|libexec)/[^ ]* \(deleted\)$' "${p}/maps" 2>/dev/null; then
      c="$(sed -n 's#^0::##p' "${p}/cgroup" 2>/dev/null)"
      case "${c}" in
        /init.scope)          echo "systemd(init)";;
        *.service*)           echo "${c}" | sed 's#.*/\([^/]*\.service\).*#\1#';;
        /user.slice/*)        echo "session-utilisateur";;
        "")                   ;;
        *)                    echo "${c##*/}";;
      esac
    fi
  done | sort -u
}

certs_check() {
  now="$(date +%s)"
  for c in /etc/letsencrypt/live/*/cert.pem; do
    [ -e "${c}" ] || continue
    end="$(openssl x509 -enddate -noout -in "${c}" | cut -d= -f2)"
    days=$(( ($(date -d "${end}" +%s) - now) / 86400 ))
    n="$(basename "$(dirname "${c}")")"
    if [ "${days}" -lt 20 ]; then ko "certificat ${n} : ${days} jours"; else ok "certificat ${n} : ${days} jours"; fi
  done
}

soa_check() {
  for z in ${ZONES}; do
    a="$(dig +short +time=2 +tries=1 SOA "${z}" @127.0.0.1 | awk '{print $3}')"
    b="$(dig +short +time=3 +tries=1 SOA "${z}" @"${SECONDARY}" | awk '{print $3}')"
    if [ -n "${a}" ] && [ "${a}" = "${b}" ]; then ok "${z} : serial ${a} (lslng = ${SECONDARY})"
    else ko "${z} : lslng ${a:-?} / ${SECONDARY} ${b:-?}"; fi
  done
}

nc_updates_cached() {
  [ -r "${NC_PROM}" ] || { ko "Nextcloud : pas de verif. en cache (${NC_PROM})"; return; }
  core="$(awk '$1=="nextcloud_core_update_available"{print $2}' "${NC_PROM}")"
  apps="$(awk '$1=="nextcloud_apps_updates_available"{print $2}' "${NC_PROM}")"
  ts="$(awk '$1=="nextcloud_update_check_timestamp_seconds"{print $2}' "${NC_PROM}")"
  when="$(date -d "@${ts:-0}" '+%F %H:%M')"
  if [ "${core:-0}" -gt 0 ] || [ "${apps:-0}" -gt 0 ]; then
    ko "Nextcloud : ${core:-?} maj du coeur, ${apps:-?} maj d'apps (verif. du ${when})"
  else ok "Nextcloud : a jour (verif. du ${when})"; fi
}

# Resume en lecture seule ; les commandes equivalentes sont dans la page "aide"
status() {
  hdr "Systeme"
  printf '  %s, Debian %s, %s\n' "$(hostname -f)" "$(cat /etc/debian_version)" "$(uptime -p)"
  printf '  charge %s, RAM dispo %s\n' "$(cut -d' ' -f1-3 /proc/loadavg)" "$(free -h | awk '/^Mem/{print $7 " / " $2}')"
  kernel_check
  if grep -q '\[[U]*_[U_]*\]' /proc/mdstat; then ko "RAID degrade (/proc/mdstat)"; else ok "RAID : $(grep -c '^md' /proc/mdstat) grappes [UU]"; fi
  df -P / /var/lib/nextcloud | awk 'NR>1{u=$5+0; printf "  [%s] %s %s utilise\n", (u>=85?"!!":"OK"), $6, $5}'

  hdr "Services"
  f="$(systemctl --failed --no-legend --plain | awk '{print $1}' | tr '\n' ' ')"
  if [ -n "${f}" ]; then ko "unites en echec : ${f}"; else ok "aucune unite en echec"; fi
  down=""
  for s in ${SERVICES}; do systemctl is-active -q "${s}" || down="${down} ${s}"; done
  if [ -n "${down}" ]; then ko "inactifs :${down}"; else ok "services vitaux actifs"; fi
  st="$(stale_units | tr '\n' ' ')"
  [ -n "${st}" ] && ko "a redemarrer (bibliotheques remplacees) : ${st}"

  hdr "Mises a jour"
  n="$(apt list --upgradable 2>/dev/null | grep -c /)"
  if [ "${n}" -gt 0 ]; then ko "${n} paquet(s) Debian a mettre a jour (cache apt du $(date -r /var/lib/apt/lists '+%F %H:%M'))"
  else ok "paquets Debian a jour (cache apt du $(date -r /var/lib/apt/lists '+%F %H:%M'))"; fi
  nc_updates_cached
  printf '  Nextcloud installe : %s (%s)\n' "$(nc_cur 2>/dev/null)" "$(readlink "${NC}")"

  hdr "Mail / DNS / certificats"
  nq="$(postqueue -j 2>/dev/null | wc -l)"
  if [ "${nq}" -gt 0 ]; then ko "file Postfix : ${nq} message(s)"; else ok "file Postfix vide"; fi
  certs_check
  soa_check

  hdr "Sauvegardes"
  last="$(ls -t "${DUMP_DIR}"/*.sql.gz 2>/dev/null | head -1)"
  if [ -n "${last}" ] && [ -n "$(find "${last}" -mmin -1560)" ]; then ok "dernier dump MariaDB : $(basename "${last}") ($(date -r "${last}" '+%F %H:%M'))"
  else ko "pas de dump MariaDB de moins de 26 h dans ${DUMP_DIR}"; fi
  b="$(fail2ban-client banned 2>/dev/null | grep -o "'[0-9a-f.:]*'" | wc -l)"
  printf '  fail2ban : %s IP bannie(s)\n' "${b}"
  printf '\n(detail des verifications et commandes manuelles : lslng-admin aide)\n'
}

# ---------------------------------------------------------------- apt

apt_refresh() {
  log "apt-get update"
  x apt-get update
  echo
  x apt list --upgradable 2>/dev/null | grep / || echo "Aucune mise a jour Debian."
}

apt_upgrade() {
  mode="${1:-upgrade}"
  x apt-get update -q >/dev/null || { echo "apt-get update en echec" >&2; return 1; }
  show "apt-get -s ${mode}    # simulation"
  sim="$(apt-get -s "${mode}" | grep '^Inst ' | awk '{print $2}' | tr '\n' ' ')"
  rem="$(apt-get -s "${mode}" | grep '^Remv ' | awk '{print $2}' | tr '\n' ' ')"
  if [ -z "${sim}${rem}" ]; then echo "Rien a faire (apt-get ${mode})."; return 0; fi
  apt-get -s "${mode}" | grep -E '^(Inst|Remv) ' | page
  msg="Commande : apt-get ${mode}
$(echo "${sim}" | wc -w) paquet(s) installe(s)/mis a jour${rem:+, SUPPRESSION de : ${rem}}

Les postinst Debian redemarrent leurs propres services (nginx, postfix...).
Ensuite : recherche des services sur d'anciennes bibliotheques.
Continuer ?"
  confirm "${msg}" || return 0
  log "apt-get ${mode} : ${sim}${rem:+ / remv ${rem}}"
  x apt-get "${mode}"
  echo
  after_upgrade
}

# Apres une mise a jour : noyau, services qui tournent sur d'anciennes bibliotheques
after_upgrade() {
  hdr "Apres mise a jour"
  show "ls /boot/vmlinuz-* ; uname -r ; ls /run/reboot-required    # noyau en attente ?"
  kernel_check
  show "grep -l ' (deleted)\$' /proc/[0-9]*/maps    # processus sur des fichiers remplaces, unite via /proc/PID/cgroup"
  st="$(stale_units)"
  if [ -z "${st}" ]; then ok "aucun service sur d'anciennes bibliotheques"; return 0; fi
  ko "services sur d'anciennes bibliotheques :"
  printf '     %s\n' ${st}
  for u in ${st}; do
    case "${u}" in
      systemd\(init\))      echo "  -> systemd : 'systemctl daemon-reexec' (sans risque, a faire a la main)";;
      session-utilisateur)  echo "  -> sessions ouvertes : se reconnecter";;
      dbus.service)         echo "  -> dbus : pas de redemarrage a chaud, attendre le prochain reboot";;
      *.service)            restart_unit "${u}";;
    esac
  done
}

restart_unit() {
  c="$(conftest_cmd "${1}")"
  confirm "Redemarrer ${1} ?

Commandes :${c:+
  ${c}}
  systemctl restart ${1}" || return 0
  if ! conftest "${1}"; then echo "Test de conf ${1} en ECHEC : pas de redemarrage." >&2; return 1; fi
  log "systemctl restart ${1}"
  x systemctl restart "${1}" && x systemctl is-active "${1}"
}

apt_history() {
  {
    hdr "dpkg/apt (history.log)"
    show "grep -E '^(Start-Date|Commandline|Upgrade|Install|Remove):' /var/log/apt/history.log | tail -40"
    grep -E '^(Start-Date|Commandline|Upgrade|Install|Remove):' /var/log/apt/history.log 2>/dev/null | tail -40 | cut -c1-300
    hdr "unattended-upgrades"
    x tail -30 /var/log/unattended-upgrades/unattended-upgrades.log
  } 2>&1 | page
}

# ---------------------------------------------------------------- Nextcloud

nc_cur() { occq status --output=json | python3 -c 'import json,sys; print(json.load(sys.stdin)["versionstring"])'; }

nc_check() {
  occ status
  echo
  occ update:check
  # Met aussi a jour la metrique Prometheus (meme commande que le timer quotidien)
  [ -x /usr/local/sbin/nextcloud-updates-textfile ] && x /usr/local/sbin/nextcloud-updates-textfile >/dev/null 2>&1
  return 0
}

nc_core_available() {
  occq update:check 2>/dev/null | sed -n 's/^\(Update to \)\{0,1\}Nextcloud \([0-9][0-9.]*\).*/\2/p' | head -1 | cut -d. -f1-3
}

nc_dump() {
  f="/root/nc-pre-${1}-$(date +%Y%m%d%H%M).sql"
  show "(umask 077; mariadb-dump --single-transaction nextcloud > ${f}) && gzip ${f}"
  ( umask 077; mariadb-dump --single-transaction nextcloud > "${f}" ) && test -s "${f}" && gzip -f "${f}"
}

nc_apps_update() {
  show "runuser -u www-data -- php ${NC}/occ update:check"
  list="$(occq update:check 2>/dev/null | sed -n 's/^Update for \([^ ]*\) to version \([^ ]*\) is available.*/\1 -> \2/p')"
  [ -n "${list}" ] || { echo "Aucune mise a jour d'app."; return 0; }
  confirm "Mettre a jour les apps Nextcloud :
${list}

Commandes :
  mariadb-dump --single-transaction nextcloud > /root/nc-pre-apps-<date>.sql
  runuser -u www-data -- php ${NC}/occ app:update --all" || return 0
  nc_dump apps || { echo "Dump en echec : abandon." >&2; return 1; }
  log "nextcloud app:update --all : $(echo "${list}" | tr '\n' ' ')"
  occ app:update --all
  occ app:list --shipped=false
}

# Mise a jour du coeur : meme methode que 090_nextcloud.sh upgrade (code dans /var/www/nextcloud-<ver>,
# bascule du lien), mais en local et aussi pour une version mineure. Une majeure a la fois.
nc_core_update() {
  cur="$(nc_cur)" || { echo "occ status en echec" >&2; return 1; }
  avail="$(nc_core_available)"
  ver="${1:-}"
  [ -n "${ver}" ] || ver="$(ask "Nextcloud installe : ${cur}
Proposee par update:check : ${avail:-aucune}
Version cible (x.y.z) :" "${avail}")" || return 0
  case "${ver}" in
    ''|*[!0-9.]*) echo "Version invalide : ${ver}" >&2; return 1;;
  esac
  case "${ver}" in [0-9]*.[0-9]*.[0-9]*) ;; *) echo "Format x.y.z attendu" >&2; return 1;; esac
  cm="${cur%%.*}"; vm="${ver%%.*}"
  if [ "${vm}" -ne "${cm}" ] && [ "${vm}" -ne $((cm + 1)) ]; then
    echo "Une majeure a la fois : ${cur} -> ${ver} refuse." >&2; return 1
  fi
  dest="/var/www/nextcloud-${ver}"
  [ -L "${NC}" ] || { echo "${NC} n'est pas un lien : abandon" >&2; return 1; }
  [ "$(readlink -f "${NC}")" != "${dest}" ] || { echo "${ver} deja en service." >&2; return 1; }
  [ -e "${dest}" ] && { echo "${dest} existe deja (essai precedent ?) : a examiner/supprimer d'abord." >&2; return 1; }
  free="$(df -Pm /var/www | awk 'NR==2{print $4}')"
  [ "${free}" -ge 2048 ] || { echo "Moins de 2 Go libres sur /var/www : abandon." >&2; return 1; }

  confirm "Mise a jour de Nextcloud ${cur} -> ${ver}

1. telechargement dans ${NC_SRC}, verif. SHA256 + GPG (${NC_GPG_FPR})
2. extraction dans un dossier temporaire puis ${dest}
   (liens config -> /etc/nextcloud, apps-extra -> /var/lib/nextcloud/apps)
3. systemctl stop nextcloud-cron.timer ; occ maintenance:mode --on ; dump
4. ln -sfn nextcloud-${ver} ${NC} ; occ upgrade ; occ maintenance:mode --off
5. (sur confirmation) reload php8.4-fpm ; occ db:add-missing-* ; apps

Chaque commande est affichee au moment ou elle est lancee. Continuer ?" || return 0
  log "nextcloud core ${cur} -> ${ver} : debut"

  f="nextcloud-${ver}.tar.bz2"
  mkdir -p "${NC_SRC}" && x cd "${NC_SRC}" || return 1
  if [ ! -s "${f}" ]; then x curl -fsSLO "${NC_URL}/${f}" || { echo "Telechargement en echec : ${NC_URL}/${f}" >&2; return 1; }; fi
  x curl -fsSLO "${NC_URL}/${f}.sha256" && x curl -fsSLO "${NC_URL}/${f}.asc" || return 1
  show "grep ' ${f}\$' ${f}.sha256 | sha256sum -c -"
  grep " ${f}\$" "${f}.sha256" | sha256sum -c - || { echo "SHA256 KO" >&2; return 1; }
  g="$(mktemp -d)"
  show "export GNUPGHOME=\$(mktemp -d)    # trousseau jetable"
  show "curl -fsSL https://nextcloud.com/nextcloud.asc | gpg --batch --import"
  curl -fsSL https://nextcloud.com/nextcloud.asc | GNUPGHOME="${g}" gpg --batch -q --import 2>/dev/null
  show "gpg --batch --status-fd 1 --verify ${f}.asc ${f} | grep 'VALIDSIG ${NC_GPG_FPR}'"
  if ! GNUPGHOME="${g}" gpg --batch --status-fd 1 --verify "${f}.asc" "${f}" 2>/dev/null | grep -q "VALIDSIG ${NC_GPG_FPR}"; then
    rm -rf "${g}"; echo "Signature GPG KO (empreinte attendue ${NC_GPG_FPR})" >&2; return 1
  fi
  rm -rf "${g}"
  echo "Archive verifiee (SHA256 + GPG)."

  # Extraction en dehors de /var/www/nextcloud : tar remplacerait sinon le lien par un dossier
  tmp="$(mktemp -d /var/www/.nc-extract.XXXXXX)"
  show "tmp=\$(mktemp -d /var/www/.nc-extract.XXXXXX)    # ${tmp}"
  if ! x tar -xjf "${f}" -C "${tmp}"; then rm -rf "${tmp}"; return 1; fi
  x mv "${tmp}/nextcloud" "${dest}" && x rm -rf "${tmp}"
  x rm -rf "${dest}/config"
  x ln -sfn /etc/nextcloud "${dest}/config"
  x ln -sfn /var/lib/nextcloud/apps "${dest}/apps-extra"
  x chown -R www-data:www-data "${dest}"
  echo "Code installe : ${dest}"

  old="$(readlink "${NC}")"
  x systemctl stop nextcloud-cron.timer
  occ maintenance:mode --on || return 1
  if ! nc_dump "${ver}"; then
    echo "Dump en echec. Maintenance active, timer cron arrete. Pour annuler : occ maintenance:mode --off ; systemctl start nextcloud-cron.timer" >&2
    return 1
  fi
  x ln -sfn "nextcloud-${ver}" "${NC}"
  log "nextcloud lien ${old} -> nextcloud-${ver}"
  if ! occ upgrade; then
    log "nextcloud core ${ver} : ECHEC occ upgrade"
    echo "
ECHEC occ upgrade. Maintenance laissee active, timer cron arrete.
Retour arriere : ln -sfn ${old} ${NC} ; restaurer le dernier /root/nc-pre-${ver}-*.sql.gz ;
occ maintenance:mode --off ; systemctl reload php8.4-fpm ; systemctl start nextcloud-cron.timer" >&2
    return 1
  fi
  occ maintenance:mode --off
  x systemctl start nextcloud-cron.timer
  log "nextcloud core ${ver} : ok"

  # Sans reload, opcache sert l'ancien code ("Downgrading is not supported")
  if confirm "Mise a jour faite. Recharger php8.4-fpm maintenant (necessaire, sinon opcache sert l'ancien code) ?

  php-fpm8.4 -t && systemctl reload php8.4-fpm"; then
    x php-fpm8.4 -t && x systemctl reload php8.4-fpm && log "reload php8.4-fpm"
  else
    echo "=> A faire : systemctl reload php8.4-fpm"
  fi
  occ db:add-missing-indices
  occ db:add-missing-columns
  occ db:add-missing-primary-keys
  echo
  echo "Apps desactivees par la montee (incompatibles) : a mettre a jour depuis l'app store."
  occ app:list --disabled | head -40
  nc_apps_update
  occ status
}

nc_maintenance() {
  cur="$(occq config:system:get maintenance 2>/dev/null)"
  if [ "${cur}" = "true" ]; then
    confirm "Maintenance ACTIVE. La desactiver ?

  occ maintenance:mode --off" && { log "nextcloud maintenance off"; occ maintenance:mode --off; }
  else
    confirm "Activer le mode maintenance de Nextcloud ?

  occ maintenance:mode --on" && { log "nextcloud maintenance on"; occ maintenance:mode --on; }
  fi
}

# Anciennes versions du code et dumps pre-montee (jamais l'instance en service)
nc_cleanup() {
  live="$(readlink -f "${NC}")"
  for d in /var/www/nextcloud-*; do
    [ -d "${d}" ] && [ ! -L "${d}" ] && [ "${d}" != "${live}" ] || continue
    confirm "Supprimer l'ancien code ${d} ($(du -sh "${d}" | cut -f1)) ?

  rm -rf ${d}" && { log "rm -rf ${d}"; x rm -rf "${d}"; }
  done
  for f in /root/nc-pre-*.sql.gz "${NC_SRC}"/nextcloud-*.tar.bz2; do
    [ -f "${f}" ] || continue
    confirm "Supprimer ${f} ($(du -h "${f}" | cut -f1), $(date -r "${f}" '+%F')) ?" && { log "rm ${f}"; x rm -f "${f}" "${f}.sha256" "${f}.asc"; }
  done
  echo "En service : ${live}"
}

nc_log() {
  f="$(occq config:system:get logfile 2>/dev/null)"
  [ -n "${f}" ] || f="$(occq config:system:get datadirectory)/nextcloud.log"
  echo "Journal ${f} : $(du -h "${f}" | cut -f1)"
  show "tail -n 300 ${f} | (JSON, niveau >= 2 : WARN, ERROR, FATAL)"
  show "  manuel : tail -n 300 ${f} | jq -r 'select(.level>=2) | [.time,.level,.app,.message] | @tsv'"
  tail -n 300 "${f}" | python3 -c '
import json, sys
lv = {0: "DEBUG", 1: "INFO", 2: "WARN", 3: "ERROR", 4: "FATAL"}
for l in sys.stdin:
    try:
        e = json.loads(l)
    except ValueError:
        continue
    if e.get("level", 0) >= 2:
        print(e.get("time", "")[:19], lv.get(e.get("level"), "?"), e.get("app", ""), str(e.get("message", ""))[:160])
' | tail -40
}

# ---------------------------------------------------------------- services

svc_reload() {
  set -- $(for s in ${SERVICES} ssh; do printf '%s %s ' "${s}" "$(systemctl is-active "${s}")"; done)
  s="$(menu "Service a recharger / redemarrer (test de conf avant)" "$@")" || return 0
  [ -n "${s}" ] || return 0
  a="$(menu "${s}" reload "recharger la conf" restart "redemarrer" status "etat")" || return 0
  case "${a}" in
    status) x systemctl status "${s}" --no-pager 2>&1 | page; return 0;;
    reload|restart) ;;
    *) return 0;;
  esac
  c="$(conftest_cmd "${s}")"
  conftest "${s}" || { echo "Test de conf ${s} en ECHEC : rien n'est fait." >&2; return 1; }
  confirm "Test de conf OK${c:+ (${c})}.

  systemctl ${a} ${s}

Continuer ?" || return 0
  log "systemctl ${a} ${s}"
  x systemctl "${a}" "${s}" && x systemctl is-active "${s}"
}

svc_conftest() {
  for s in nginx postfix dovecot named php8.4-fpm rspamd fail2ban prometheus prometheus-alertmanager; do
    c="$(conftest_cmd "${s}")"
    if eval "${c}" >/dev/null 2>&1; then ok "${s}  (${c})"; else ko "${s}  (${c})"; eval "${c}" 2>&1 | tail -5 | sed 's/^/       /'; fi
  done
}

# ---------------------------------------------------------------- mail

mail_passwd() {
  u="$(ask "Adresse de la boite (user@domaine) :")" || return 0
  [ -n "${u}" ] || return 0
  sql="SELECT count(*) FROM mailboxes WHERE email='$(printf '%s' "${u}" | tr -d "'")' AND active=1;"
  show "runuser -u vmail -- sqlite3 ${VMAIL_DB} \"${sql}\""
  n="$(runuser -u vmail -- sqlite3 "${VMAIL_DB}" "${sql}")"
  [ "${n}" = "1" ] || { echo "Boite inconnue ou inactive : ${u}" >&2; return 1; }
  if [ -n "${WT}" ]; then
    p1="$(whiptail --title lslng-admin --passwordbox "Nouveau mot de passe (10 car. min.) pour ${u} :" 10 70 3>&1 1>&2 2>&3)" || return 0
    p2="$(whiptail --title lslng-admin --passwordbox "Confirmation :" 10 70 3>&1 1>&2 2>&3)" || return 0
  else
    stty -echo; printf 'Nouveau mot de passe : '; read -r p1; printf '\nConfirmation : '; read -r p2; stty echo; echo
  fi
  [ "${p1}" = "${p2}" ] || { echo "Les mots de passe different." >&2; return 1; }
  # Meme outil que le plugin password de Roundcube (hash SHA512-CRYPT via openssl passwd -6, 10 caracteres min.)
  show "printf '%s\\n' '<mot de passe>' | /usr/local/sbin/mailpw ${u}    # openssl passwd -6 + UPDATE mailboxes"
  if printf '%s\n' "${p1}" | /usr/local/sbin/mailpw "${u}"; then
    log "mot de passe change : ${u}"; echo "Mot de passe change pour ${u}."
  else
    echo "Echec mailpw (code $?) : 3 = trop court, 5 = boite introuvable." >&2
  fi
}

mail_list() {
  x runuser -u vmail -- sqlite3 -column -header "${VMAIL_DB}" \
    "SELECT email, active, quota_mb FROM mailboxes ORDER BY domain, email; SELECT ''; SELECT source, destination, active FROM aliases ORDER BY domain, source;" 2>&1 | page
}

# ---------------------------------------------------------------- fail2ban

f2b_unban() {
  ip="$(ask "IP a debannir :")" || return 0
  case "${ip}" in ''|*[!0-9a-fA-F.:]*) echo "IP invalide" >&2; return 1;; esac
  log "fail2ban unban ${ip}"
  x fail2ban-client unban "${ip}"
}

f2b_status() {
  show "fail2ban-client status ; fail2ban-client status <jail>"
  for j in $(fail2ban-client status | sed -n 's/.*Jail list:[[:space:]]*//p' | tr ',' ' '); do
    fail2ban-client status "${j}" | awk -v j="${j}" '/Currently banned/{c=$NF} /Total banned/{t=$NF} /Banned IP list/{sub(/.*list:[ \t]*/,""); l=$0} END{printf "%-14s bannies %s (total %s) %s\n", j, c, t, l}'
  done
}

# ---------------------------------------------------------------- sites GitHub

# Meme bac a sable que 120_sites.sh
sites_sandbox() {
  x systemd-run --pipe --wait --quiet --uid=lstux --gid=lstux -p NoNewPrivileges=yes -p ProtectSystem=strict \
    -p ReadWritePaths="${SITES_BASE}" -p ProtectHome=yes -p PrivateTmp=yes -p PrivateDevices=yes \
    -p CapabilityBoundingSet= -p RestrictAddressFamilies='AF_INET AF_INET6 AF_UNIX' -p MemoryMax=2G \
    -p RuntimeMaxSec=1800 "${SITES_BASE}/publish-github" "$@"
}

sites_publish() {
  set --
  for c in "${SITES_CONF}"/*.json; do [ -f "${c}" ] && set -- "$@" "$(basename "${c}")" "republier"; done
  [ $# -gt 0 ] || { echo "Aucune conf dans ${SITES_CONF}"; return 0; }
  c="$(menu "Site a republier (clone + build + bascule)" "$@")" || return 0
  [ -n "${c}" ] && [ -f "${SITES_CONF}/${c}" ] || return 0
  confirm "Republier ${c} ?

  systemd-run (bac a sable, utilisateur lstux) ${SITES_BASE}/publish-github ${SITES_CONF}/${c}" || return 0
  log "publish-github ${c}"
  sites_sandbox "${SITES_CONF}/${c}"
}

sites_rollback() {
  s="$(ask "Site a ramener a la release precedente :")" || return 0
  case "${s}" in ''|*[!a-z0-9-]*) echo "Nom invalide" >&2; return 1;; esac
  confirm "Rollback de ${s} ?

  systemd-run (bac a sable, utilisateur lstux) ${SITES_BASE}/publish-github --rollback ${s}" || return 0
  log "publish-github --rollback ${s}"
  sites_sandbox --rollback "${s}"
}

# ---------------------------------------------------------------- aide

aide() {
  cat <<EOF
lslng-admin : methode et commandes manuelles equivalentes (en root)
==================================================================
Pendant l'execution, chaque commande est affichee avant d'etre lancee : "\$ ...".
Journal des actions : ${LOG}

ETAT GENERAL (status, lecture seule)
  Noyau en attente     ls /boot/vmlinuz-* ; uname -r ; ls /run/reboot-required
  RAID                 cat /proc/mdstat            (un "_" dans [UU] = disque sorti)
  Disques              df -h / /var/lib/nextcloud  (alerte a 85 %)
  Unites en echec      systemctl --failed
  Services vitaux      systemctl is-active ${SERVICES}
  Anciennes biblio.    processus dont /proc/PID/maps ou /proc/PID/exe contient "(deleted)",
                       unite lue dans /proc/PID/cgroup (equivalent de "needrestart -r l",
                       paquet needrestart non installe)
  Maj Debian           apt list --upgradable        (cache apt, pas de apt-get update)
  Maj Nextcloud        cat ${NC_PROM}
                       (ecrit chaque jour par nextcloud-updates-textfile.timer)
  File Postfix         postqueue -p
  Certificats          openssl x509 -enddate -noout -in /etc/letsencrypt/live/<nom>/cert.pem
  DNS                  dig +short SOA <zone> @127.0.0.1 ; dig +short SOA <zone> @${SECONDARY}
                       zones : ${ZONES}
  Dumps MariaDB        ls -lt ${DUMP_DIR}          (alerte si > 26 h)
  fail2ban             fail2ban-client banned

MISES A JOUR DEBIAN
  apt-get update ; apt list --upgradable
  apt-get -s upgrade                  simulation (Inst/Remv)
  apt-get upgrade                     (ou full-upgrade : nouveau noyau, paquets retenus)
  Les postinst Debian redemarrent leurs services. Apres coup, pour chaque service
  sur d'anciennes bibliotheques : <test de conf> puis systemctl restart <service>.
  systemd : systemctl daemon-reexec. dbus : seulement par reboot.
  Historique : /var/log/apt/history.log, /var/log/unattended-upgrades/unattended-upgrades.log
  Les maj de securite passent seules (unattended-upgrades, apt-daily-upgrade.timer).

NEXTCLOUD (occ = runuser -u www-data -- php ${NC}/occ)
  Etat / maj           occ status ; occ update:check
  Apps                 mariadb-dump --single-transaction nextcloud > /root/nc-pre-apps-<date>.sql
                       occ app:update --all
  Coeur (x.y.z, meme majeure ou majeure+1 seulement) :
    cd ${NC_SRC}
    curl -fsSLO ${NC_URL}/nextcloud-x.y.z.tar.bz2  (+ .sha256, .asc)
    grep ' nextcloud-x.y.z.tar.bz2\$' nextcloud-x.y.z.tar.bz2.sha256 | sha256sum -c -
    export GNUPGHOME=\$(mktemp -d)
    curl -fsSL https://nextcloud.com/nextcloud.asc | gpg --batch --import
    gpg --batch --status-fd 1 --verify nextcloud-x.y.z.tar.bz2.asc nextcloud-x.y.z.tar.bz2 \\
      | grep 'VALIDSIG ${NC_GPG_FPR}'
    tmp=\$(mktemp -d /var/www/.nc-extract.XXXXXX)   # JAMAIS extraire directement dans /var/www
    tar -xjf nextcloud-x.y.z.tar.bz2 -C \$tmp && mv \$tmp/nextcloud /var/www/nextcloud-x.y.z
    rm -rf /var/www/nextcloud-x.y.z/config
    ln -sfn /etc/nextcloud /var/www/nextcloud-x.y.z/config
    ln -sfn /var/lib/nextcloud/apps /var/www/nextcloud-x.y.z/apps-extra
    chown -R www-data:www-data /var/www/nextcloud-x.y.z
    systemctl stop nextcloud-cron.timer ; occ maintenance:mode --on
    mariadb-dump --single-transaction nextcloud > /root/nc-pre-x.y.z-<date>.sql
    ln -sfn nextcloud-x.y.z ${NC} ; occ upgrade
    occ maintenance:mode --off ; systemctl start nextcloud-cron.timer
    php-fpm8.4 -t && systemctl reload php8.4-fpm     # sinon opcache sert l'ancien code
    occ db:add-missing-indices ; occ db:add-missing-columns ; occ db:add-missing-primary-keys
    occ app:list --disabled ; occ app:update --all
  Retour arriere : ln -sfn <ancien> ${NC} ; restaurer le dump ; maintenance off ; reload php-fpm
  Journal              <datadirectory>/nextcloud.log (JSON) ; niveaux 2 WARN, 3 ERROR, 4 FATAL
  Cron                 systemctl list-timers nextcloud-cron.timer ; journalctl -u nextcloud-cron.service

SERVICES : test de conf avant tout reload/restart
  nginx -t | postfix check | doveconf -n | named-checkconf -z | php-fpm8.4 -t
  rspamadm configtest | fail2ban-client -t
  promtool check config /etc/prometheus/prometheus.yml
  amtool check-config /etc/prometheus/alertmanager.yml
  puis systemctl reload|restart <service>
  Erreurs du boot : journalctl -p err -b

MAIL
  postqueue -p ; postqueue -f
  Mot de passe : printf '%s\n' 'MOTDEPASSE' | /usr/local/sbin/mailpw user@domaine
                 (openssl passwd -6 puis UPDATE mailboxes dans ${VMAIL_DB}, en vmail)
  Boites/alias : runuser -u vmail -- sqlite3 ${VMAIL_DB} 'SELECT email FROM mailboxes;'

DNS / CERTIFICATS / FAIL2BAN
  named-checkconf -z ; certbot certificates ; certbot renew --dry-run
  fail2ban-client status [<jail>] ; fail2ban-client unban <ip>
  Edition de zone : set_txt.sh, set_addr.sh, set_cname.sh (hors de cet outil)

SAUVEGARDES
  ls -lh ${DUMP_DIR} ; systemctl start mariadb-dump-all.service

SITES GITHUB
  runuser -u lstux -- ${SITES_BASE}/publish-github --list
  publication / rollback : meme systemd-run que 120_sites.sh (sandbox(), utilisateur lstux)
EOF
}

# ---------------------------------------------------------------- menus

m_updates() {
  while :; do
    c="$(menu "Mises a jour" \
      check   "Verifier tout (apt-get update + Nextcloud)" \
      upgrade "Appliquer les mises a jour Debian (apt-get upgrade)" \
      full    "apt-get full-upgrade (paquets retenus, nouveau noyau...)" \
      restart "Services a redemarrer / reboot necessaire ?" \
      ncapps  "Nextcloud : mettre a jour les apps" \
      nccore  "Nextcloud : mettre a jour le coeur" \
      history "Historique apt / unattended-upgrades")" || return 0
    case "${c}" in
      check)   apt_refresh; echo; nc_check; pause;;
      upgrade) apt_upgrade upgrade; pause;;
      full)    apt_upgrade full-upgrade; pause;;
      restart) after_upgrade; pause;;
      ncapps)  nc_apps_update; pause;;
      nccore)  nc_core_update; pause;;
      history) apt_history;;
      *)       return 0;;
    esac
  done
}

m_nextcloud() {
  while :; do
    c="$(menu "Nextcloud ($(readlink "${NC}"))" \
      status  "Etat + mises a jour disponibles" \
      maint   "Mode maintenance on/off" \
      log     "Journal : taille + derniers avertissements/erreurs" \
      cron    "Timer cron : etat et derniers passages" \
      clean   "Nettoyer anciennes versions du code et dumps" \
      db      "Index/colonnes/cles manquants (occ db:add-missing-*)")" || return 0
    case "${c}" in
      status) nc_check; pause;;
      maint)  nc_maintenance; pause;;
      log)    nc_log 2>&1 | page;;
      cron)   { x systemctl list-timers nextcloud-cron.timer --no-pager; x journalctl -u nextcloud-cron.service -n 20 --no-pager; } 2>&1 | page;;
      clean)  nc_cleanup; pause;;
      db)     log "occ db:add-missing-*"; occ db:add-missing-indices; occ db:add-missing-columns; occ db:add-missing-primary-keys; pause;;
      *)      return 0;;
    esac
  done
}

m_services() {
  while :; do
    c="$(menu "Services" \
      state   "Etat des services vitaux" \
      test    "Tester toutes les confs (nginx -t, postfix check...)" \
      reload  "Recharger / redemarrer un service" \
      errors  "Erreurs du journal depuis le boot")" || return 0
    case "${c}" in
      state)  { x systemctl --failed --no-pager; echo; show "systemctl is-active <service>"; for s in ${SERVICES}; do printf '  %-26s %s\n' "${s}" "$(systemctl is-active "${s}")"; done; } 2>&1 | page;;
      test)   svc_conftest; pause;;
      reload) svc_reload; pause;;
      errors) { show "journalctl -p err -b --no-pager | tail -100"; journalctl -p err -b --no-pager | tail -100; } 2>&1 | page;;
      *)      return 0;;
    esac
  done
}

m_mail() {
  while :; do
    c="$(menu "Mail" \
      queue  "File d'attente Postfix" \
      flush  "Relancer la file (postqueue -f)" \
      passwd "Changer le mot de passe d'une boite" \
      list   "Boites et alias (vmail.db)" \
      log    "Dernieres lignes de mail.log")" || return 0
    case "${c}" in
      queue)  { show "postqueue -p | tail -40"; postqueue -p | tail -40; } 2>&1 | page;;
      flush)  confirm "Relancer la file Postfix ?

  postqueue -f" && { log "postqueue -f"; x postqueue -f; }; pause;;
      passwd) mail_passwd; pause;;
      list)   mail_list;;
      log)    x tail -n 80 /var/log/mail.log 2>&1 | page;;
      *)      return 0;;
    esac
  done
}

m_security() {
  while :; do
    c="$(menu "DNS, certificats, fail2ban" \
      soa    "Serials SOA lslng / ${SECONDARY}" \
      named  "named-checkconf -z" \
      certs  "Certificats : echeances" \
      renew  "certbot renew --dry-run" \
      f2b    "fail2ban : jails et IP bannies" \
      unban  "fail2ban : debannir une IP")" || return 0
    case "${c}" in
      soa)   show "dig +short SOA <zone> @127.0.0.1 ; dig +short SOA <zone> @${SECONDARY}"; soa_check; pause;;
      named) x named-checkconf -z 2>&1 | page;;
      certs) show "openssl x509 -enddate -noout -in /etc/letsencrypt/live/<nom>/cert.pem"; certs_check; pause;;
      renew) log "certbot renew --dry-run"; x certbot renew --dry-run; pause;;
      f2b)   f2b_status 2>&1 | page;;
      unban) f2b_unban; pause;;
      *)     return 0;;
    esac
  done
}

m_backups() {
  while :; do
    c="$(menu "Sauvegardes" \
      list "Dumps MariaDB (${DUMP_DIR}) et dumps Nextcloud (/root)" \
      dump "Lancer un dump MariaDB maintenant")" || return 0
    case "${c}" in
      list) { x ls -lh "${DUMP_DIR}"; echo; show "ls -lh /root/nc-pre-*.sql.gz"; ls -lh /root/nc-pre-*.sql.gz 2>/dev/null; echo; x systemctl list-timers mariadb-dump-all.timer --no-pager; } 2>&1 | page;;
      dump) confirm "Lancer un dump complet maintenant ?

  systemctl start mariadb-dump-all.service
  (= /usr/local/sbin/mariadb-dump-all -> ${DUMP_DIR}/all_<jour>.sql.gz)" && { log "mariadb-dump-all"; x systemctl start mariadb-dump-all.service && x ls -lh "${DUMP_DIR}"; }; pause;;
      *)    return 0;;
    esac
  done
}

m_sites() {
  while :; do
    c="$(menu "Sites GitHub (*.lslinux.org)" \
      list     "Releases publiees" \
      publish  "Republier un site" \
      rollback "Revenir a la release precedente")" || return 0
    case "${c}" in
      list)     x runuser -u lstux -- "${SITES_BASE}/publish-github" --list 2>&1 | page;;
      publish)  sites_publish; pause;;
      rollback) sites_rollback; pause;;
      *)        return 0;;
    esac
  done
}

main_menu() {
  while :; do
    c="$(menu "lslng - $(hostname -f) - $(uptime -p)" \
      status    "Etat general (resume)" \
      updates   "Mises a jour (Debian + Nextcloud)" \
      nextcloud "Nextcloud" \
      services  "Services : etat, tests de conf, reload" \
      mail      "Mail : file, mots de passe, boites" \
      security  "DNS, certificats, fail2ban" \
      backups   "Sauvegardes" \
      sites     "Sites GitHub" \
      journal   "Journal de lslng-admin" \
      aide      "Aide : methode et commandes manuelles")" || exit 0
    case "${c}" in
      status)    status | page;;
      updates)   m_updates;;
      nextcloud) m_nextcloud;;
      services)  m_services;;
      mail)      m_mail;;
      security)  m_security;;
      backups)   m_backups;;
      sites)     m_sites;;
      journal)   tail -n 100 "${LOG}" 2>/dev/null | page;;
      aide)      aide | page;;
      "")        exit 0;;
    esac
  done
}

usage() {
  printf 'Usage : %s [commande]\n' "$(basename "${0}")"
  printf '  (sans argument)     menu\n'
  printf '  status              resume de l etat (lecture seule)\n'
  printf '  updates             apt-get update + liste, verif. Nextcloud\n'
  printf '  apt-upgrade         apt-get upgrade (simulation + confirmation)\n'
  printf '  apt-full-upgrade    apt-get full-upgrade (simulation + confirmation)\n'
  printf '  restart-check       services sur d anciennes bibliotheques, noyau\n'
  printf '  nc-apps             mise a jour des apps Nextcloud\n'
  printf '  nc-upgrade [x.y.z]  mise a jour du coeur Nextcloud (une majeure a la fois)\n'
  printf '  conftest            tests de conf de tous les services\n'
  printf '  mailpw              changer le mot de passe d une boite\n'
  printf '  aide                methode et commandes manuelles equivalentes\n'
}

case "${1:-}" in
  "")               [ -n "${WT}" ] || [ -t 0 ] || { usage; exit 1; }; main_menu;;
  status)           status;;
  updates)          apt_refresh; echo; nc_check;;
  apt-upgrade)      apt_upgrade upgrade;;
  apt-full-upgrade) apt_upgrade full-upgrade;;
  restart-check)    after_upgrade;;
  nc-apps)          nc_apps_update;;
  nc-upgrade)       nc_core_update "${2:-}";;
  conftest)         svc_conftest;;
  mailpw)           mail_passwd;;
  aide)             aide;;
  *)                usage;;
esac
