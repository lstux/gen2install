#!/bin/sh
WORKDIR="$(dirname "${0}")"
. "${WORKDIR}/server.conf"

BASE=/var/www/lstux
CONFDIR=/etc/lstux/sites.d

usage() {
  exec >&2
  printf "Usage : %s {packages|install|vhost|homepage|publish <conf.json>|rollback <site>|list|backup|restore|status}\n" "$(basename "${0}")"
  printf "  Sites statiques GitHub sur <site>.lslinux.org (%s)\n" "${BASE}"
  printf "  packages: apt install git python3-pil fonts-noto-color-emoji (builds des sites ; a lancer apres accord)\n"
  printf "  install : utilisateur lstux, dossiers, publish-github (rien n'est demarre)\n"
  printf "  homepage: genere (sites/gen-index.sh) et depose www/lslinux.org/index.html dans /var/www/lslinux.org (ancienne page sauvegardee)\n"
  printf "  vhost   : depose nginx/lstux-sites.conf, nginx -t (retour arriere si KO), PAS de reload\n"
  printf "  publish : copie la conf dans %s, clone + build + publie, en lstux dans un bac a sable systemd\n" "${CONFDIR}"
}

packages() {
  ${SUSSH} "apt-get install -y --no-install-recommends git python3-pil fonts-noto-color-emoji"
}

# Bac a sable : utilisateur lstux, systeme en lecture seule sauf ${BASE}, pas de capacites
sandbox() {
  printf "sudo systemd-run --pipe --wait --quiet --uid=lstux --gid=lstux -p NoNewPrivileges=yes -p ProtectSystem=strict -p ReadWritePaths=${BASE} -p ProtectHome=yes -p PrivateTmp=yes -p PrivateDevices=yes -p CapabilityBoundingSet= -p RestrictAddressFamilies='AF_INET AF_INET6 AF_UNIX' -p MemoryMax=2G -p RuntimeMaxSec=1800 ${BASE}/publish-github"
}

install_all() {
  ${SUSSH} "/usr/sbin/adduser --system --group --home ${BASE} --no-create-home --shell /usr/sbin/nologin lstux" || exit 1
  ${SUSSH} "install -d -o lstux -g lstux -m 0755 ${BASE} ${BASE}/.releases" && \
  ${SUSSH} "install -d -o root -g root -m 0755 /etc/lstux ${CONFDIR}" && \
  cat "${WORKDIR}/sites/publish-github" | ${SSH} "cat > /tmp/publish-github && sudo install -o root -g root -m 0755 /tmp/publish-github ${BASE}/publish-github && rm -f /tmp/publish-github" && \
  ${SSH} "sudo sh -n ${BASE}/publish-github" && printf "=> publish-github installe : %s/publish-github\n" "${BASE}"
}

vhost() {
  cat "${WORKDIR}/nginx/lstux-sites.conf" | ${SSH} "cat > /tmp/lstux.vhost" || exit 1
  ${SSH} 'sudo sh -s' <<'REMOTE'
set -u
f=/etc/nginx/sites-available/lstux-sites
bak=""
[ -f "${f}" ] && { bak="/root/lstux-sites.bak.$(date +%Y%m%d%H%M%S)"; cp -p "${f}" "${bak}"; }
install -m 0644 /tmp/lstux.vhost "${f}"; rm -f /tmp/lstux.vhost
ln -sfn ../sites-available/lstux-sites /etc/nginx/sites-enabled/lstux-sites
if ! nginx -t; then
  if [ -n "${bak}" ]; then cp -p "${bak}" "${f}"; else rm -f "${f}" /etc/nginx/sites-enabled/lstux-sites; fi
  echo "nginx -t KO : vhost retire/restaure" >&2; exit 1
fi
echo "nginx -t OK"
REMOTE
  [ $? -eq 0 ] && printf "\n=> Ready! Pas de reload fait. Quand tu valides : %s systemctl reload nginx\n" "${SUSSH}"
}

homepage() {
  sh "${WORKDIR}/sites/gen-index.sh" || exit 1
  cat "${WORKDIR}/www/lslinux.org/index.html" | ${SSH} "cat > /tmp/lslinux-index.html" || exit 1
  ${SSH} 'sudo sh -s' <<'REMOTE'
set -eu
d=/var/www/lslinux.org
[ -f "${d}/index.html" ] && cp -p "${d}/index.html" "/root/lslinux-index.html.bak.$(date +%Y%m%d%H%M%S)"
install -o root -g root -m 0644 /tmp/lslinux-index.html "${d}/index.html"
rm -f /tmp/lslinux-index.html
echo "page deposee : ${d}/index.html"
REMOTE
}

publish() {
  [ -f "${1:-}" ] || { printf "conf introuvable : %s\n" "${1:-}" >&2; exit 1; }
  b="$(basename "${1}")"
  case "${b}" in *[!A-Za-z0-9._-]*) printf "nom de fichier invalide\n" >&2; exit 1 ;; esac
  cat "${1}" | ${SSH} "sudo tee ${CONFDIR}/${b} >/dev/null" && \
  ${SSH} "$(sandbox) ${CONFDIR}/${b}"
}

rollback() {
  case "${1:-}" in ''|*[!a-z0-9-]*) printf "site invalide\n" >&2; exit 1 ;; esac
  ${SSH} "$(sandbox) --rollback ${1}"
}

backup() {
  d="$(date +%Y%m%d)"
  ${SSH} "sudo tar cvpz -C / etc/lstux etc/nginx/sites-available/lstux-sites" \
  > "${WORKDIR}/data/sites_etc_${d}.tgz" && \
  ln -sf "sites_etc_${d}.tgz" "${WORKDIR}/data/sites_etc.tgz"
}

restore() {
  install_all && \
  cat "${WORKDIR}/data/sites_etc.tgz" | ${SSH} "sudo tar xvzpf - -C /" && \
  ${SUSSH} "nginx -t" && \
  printf "\n=> Ready! Republier chaque site : %s publish %s/sites/sites.d/<site>.json\n" "$(basename "${0}")" "${WORKDIR}"
}

status() {
  ${SSH} "ls -l ${BASE}; echo; sudo -u lstux ${BASE}/publish-github --list; echo; ls ${CONFDIR}"
}

case "${1}" in
  packages) packages;;
  install)  install_all;;
  vhost)    vhost;;
  homepage) homepage;;
  publish)  publish "${2:-}";;
  rollback) rollback "${2:-}";;
  list)     ${SSH} "sudo -u lstux ${BASE}/publish-github --list";;
  backup)   backup;;
  restore)  restore;;
  status)   status;;
  *)        usage;;
esac
