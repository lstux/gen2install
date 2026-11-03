#!/bin/sh
WORKDIR="$(dirname "${0}")"
. "${WORKDIR}/server.conf"

# genserv est lu depuis lslng, en root (cle deja en place). Le nom "www.lslinux.org" pointe
# desormais sur lslng : on joint genserv par son nom (/root/.ssh/config de lslng : HostKeyAlias www.lslinux.org).
GS="sudo ssh -4 -n -o BatchMode=yes root@genserv.lslinux.org"
SRC=/var/www/ossn.info/htdocs
DST=/var/www/ossn.info

usage() {
  exec >&2
  printf "Usage : %s {backup|account|restore|vhost|layout|status}\n" "$(basename "${0}")"
  printf "  Site ossn.info (Orchestre Symphonique de Saint-Nazaire, PHP) : genserv -> lslng\n"
  printf "  backup  : tire le docroot de genserv (lecture seule) dans data/ossn_site_<date>.tgz\n"
  printf "  account : compte sftp 'ossn' (chroot %s, cles reprises de genserv), sshd -t, PAS de reload\n" "${DST}"
  printf "  restore : depose data/ossn_site.tgz dans %s/htdocs (ossn:ossn, 0755/0644), ancien htdocs sauvegarde\n" "${DST}"
  printf "  layout  : apres vhost+reload, SUPPRIME l'ancien contenu a plat de %s (tout sauf htdocs/, apres controle de htdocs/)\n" "${DST}"
  printf "  vhost   : depose nginx/ossn.info.conf, nginx -t (retour arriere si KO), PAS de reload\n"
  printf "  status  : tests curl --resolve sur lslng (www, apex, mobile)\n"
}

backup() {
  d="$(date +%Y%m%d)"
  ${SSH} "${GS} 'tar czpf - -C ${SRC} .'" > "${WORKDIR}/data/ossn_site_${d}.tgz" && \
  ln -sf "ossn_site_${d}.tgz" "${WORKDIR}/data/ossn_site.tgz" && \
  ls -l "${WORKDIR}/data/ossn_site.tgz" "${WORKDIR}/data/ossn_site_${d}.tgz"
}

restore() {
  [ -f "${WORKDIR}/data/ossn_site.tgz" ] || { printf "data/ossn_site.tgz absent : lancer backup\n" >&2; exit 1; }
  cat "${WORKDIR}/data/ossn_site.tgz" | ${SSH} "cat > /tmp/ossn_site.tgz" || exit 1
  ${SSH} 'sudo sh -s' <<'REMOTE'
set -eu
d=/var/www/ossn.info
mkdir -p "${d}"
n="$(mktemp -d "${d}/.new.XXXXXX")"
# extraction dans un dossier temporaire (jamais directement dans la cible)
tar xzf /tmp/ossn_site.tgz -C "${n}" --no-same-owner --no-same-permissions
rm -f /tmp/ossn_site.tgz
[ -f "${n}/index.php" ] || { echo "index.php absent : abandon" >&2; rm -rf "${n}"; exit 1; }
# proprietaire : le compte sftp s'il existe (mise a jour par sftp), sinon root ; droits lisibles par nginx
if id ossn >/dev/null 2>&1; then chown -R ossn:ossn "${n}"; else chown -R root:root "${n}"; fi
chmod -R u=rwX,go=rX "${n}"
chmod 0755 "${n}"
if [ -d "${d}/htdocs" ]; then
  bak="/root/ossn.info.htdocs.bak.$(date +%Y%m%d%H%M%S)"
  mv "${d}/htdocs" "${bak}"; echo "ancien htdocs : ${bak}"
fi
mv "${n}" "${d}/htdocs"
echo "site depose : ${d}/htdocs ($(find "${d}/htdocs" -type f | wc -l) fichiers)"
REMOTE
}

account() {
  # cles publiques de genserv (lecture seule), validees par ssh-keygen avant installation
  ${SSH} "${GS} 'cat /home/ossn/.ssh/authorized_keys'" > "${WORKDIR}/data/ossn_authorized_keys" || exit 1
  [ -s "${WORKDIR}/data/ossn_authorized_keys" ] || { printf "authorized_keys vide\n" >&2; exit 1; }
  cat "${WORKDIR}/data/ossn_authorized_keys" | ${SSH} "cat > /tmp/ossn_keys" || exit 1
  cat "${WORKDIR}/sshd/500-user-ossn.conf" | ${SSH} "cat > /tmp/ossn_sshd.conf" || exit 1
  ${SSH} 'sudo sh -s' <<'REMOTE'
set -eu
if ! ssh-keygen -lf /tmp/ossn_keys; then echo "cles invalides : abandon" >&2; rm -f /tmp/ossn_keys /tmp/ossn_sshd.conf; exit 1; fi
if ! id ossn >/dev/null 2>&1; then
  /usr/sbin/adduser --system --group --no-create-home --home /var/www/ossn.info --shell /usr/sbin/nologin ossn
fi
install -d -o root -g root -m 0755 /etc/ssh/authorized_keys
install -o root -g root -m 0644 /tmp/ossn_keys /etc/ssh/authorized_keys/ossn
rm -f /tmp/ossn_keys
f=/etc/ssh/sshd_config.d/500-user-ossn.conf
bak=""; [ -f "${f}" ] && { bak="/root/500-user-ossn.conf.bak.$(date +%Y%m%d%H%M%S)"; cp -p "${f}" "${bak}"; }
install -o root -g root -m 0644 /tmp/ossn_sshd.conf "${f}"; rm -f /tmp/ossn_sshd.conf
if ! /usr/sbin/sshd -t; then
  if [ -n "${bak}" ]; then cp -p "${bak}" "${f}"; else rm -f "${f}"; fi
  echo "sshd -t KO : drop-in retire/restaure" >&2; exit 1
fi
echo "--- configuration effective pour ossn :"
/usr/sbin/sshd -T -C user=ossn,host=lslng,addr=203.0.113.9 | grep -iE "^(chrootdirectory|forcecommand|authorizedkeysfile|passwordauthentication|allowtcpforwarding|permittty) "
echo "sshd -t OK"
REMOTE
  [ $? -eq 0 ] && printf "\n=> Ready! Pas de reload fait. Quand tu valides : %s systemctl reload ssh\n" "${SUSSH}"
}

layout() {
  ${SSH} 'sudo sh -s' <<'REMOTE'
set -eu
d=/var/www/ossn.info
[ -f "${d}/htdocs/index.php" ] || { echo "htdocs absent : lancer restore d'abord" >&2; exit 1; }
nf=$(find "${d}/htdocs" -type f | wc -l)
[ "${nf}" -ge 100 ] || { echo "htdocs ne contient que ${nf} fichiers, abandon" >&2; exit 1; }
n=0
for e in "${d}"/* "${d}"/.[!.]*; do
  [ -e "${e}" ] || continue
  case "${e##*/}" in htdocs) continue ;; esac
  echo "supprime : ${e}"; rm -rf -- "${e}"; n=$((n+1))
done
echo "${n} element(s) supprime(s), htdocs/ : ${nf} fichiers"
REMOTE
}

vhost() {
  cat "${WORKDIR}/nginx/ossn.info.conf" | ${SSH} "cat > /tmp/ossn.vhost" || exit 1
  ${SSH} 'sudo sh -s' <<'REMOTE'
set -u
f=/etc/nginx/sites-available/ossn.info
bak="/root/ossn.info.vhost.bak.$(date +%Y%m%d%H%M%S)"
cp -p "${f}" "${bak}"
install -m 0644 /tmp/ossn.vhost "${f}"; rm -f /tmp/ossn.vhost
if ! nginx -t; then cp -p "${bak}" "${f}"; echo "nginx -t KO : ancien vhost restaure" >&2; exit 1; fi
echo "nginx -t OK"
REMOTE
  [ $? -eq 0 ] && printf "\n=> Ready! Pas de reload fait. Quand tu valides : %s systemctl reload nginx\n" "${SUSSH}"
}

status() {
  IP=145.239.67.105
  for u in https://www.ossn.info/ https://ossn.info/ https://www.ossn.info/presentation.php https://www.ossn.info/contacts.php; do
    h="${u#https://}"; h="${h%%/*}"
    printf "%-45s " "${u}"; curl -s -o /dev/null -w "%{http_code} %{size_download}B -> %{redirect_url}\n" --resolve "${h}:443:${IP}" "${u}"
  done
  printf "%-45s " "mobile (iPhone)"; curl -s -o /dev/null -A "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X)" -w "%{http_code} -> %{redirect_url}\n" --resolve "www.ossn.info:443:${IP}" https://www.ossn.info/
  printf "%-45s " "fichier cache (/.git)"; curl -s -o /dev/null -w "%{http_code}\n" --resolve "www.ossn.info:443:${IP}" https://www.ossn.info/.git/config
}

case "${1}" in
  backup)  backup;;
  account) account;;
  restore) restore;;
  layout)  layout;;
  vhost)   vhost;;
  status)  status;;
  *)       usage;;
esac
