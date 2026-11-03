#!/bin/sh
# certbot --manual-cleanup-hook. Deploye en /etc/letsencrypt/hooks/cleanup.sh
# sur lslng. Variables fournies par certbot : CERTBOT_DOMAIN, CERTBOT_VALIDATION.
set -u

VALUE="${CERTBOT_VALIDATION}"

echo "[cleanup-hook] ${CERTBOT_DOMAIN} -> retrait TXT sur acme.lslinux.org"

ACME_ZONEDIR=/etc/bind/zones /root/acme_txt.sh remove acme.lslinux.org "${VALUE}"
