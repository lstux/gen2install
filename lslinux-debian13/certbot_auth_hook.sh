#!/bin/sh
# certbot --manual-auth-hook. Deploye en /etc/letsencrypt/hooks/auth.sh sur
# lslng. Variables fournies par certbot : CERTBOT_DOMAIN, CERTBOT_VALIDATION.
# Chaque domaine a un CNAME _acme-challenge -> _acme-challenge.acme.lslinux.org :
# le TXT est toujours ecrit dans la zone acme.lslinux.org, servie par lslng seul.
set -u

VALUE="${CERTBOT_VALIDATION}"

echo "[auth-hook] ${CERTBOT_DOMAIN} -> TXT sur acme.lslinux.org"

ACME_ZONEDIR=/etc/bind/zones /root/acme_txt.sh add acme.lslinux.org "${VALUE}" || exit 1

i=0
until dig +short TXT _acme-challenge.acme.lslinux.org @127.0.0.1 | grep -qF "${VALUE}"; do
  i=$((i + 1))
  if [ "${i}" -ge 15 ]; then
    echo "[auth-hook] TXT non visible sur lslng" >&2
    exit 1
  fi
  sleep 2
done
