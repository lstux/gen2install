#!/bin/sh
# certbot --manual-cleanup-hook. Deploye en /etc/letsencrypt/hooks/cleanup.sh
# sur lslng. Variables fournies par certbot : CERTBOT_DOMAIN, CERTBOT_VALIDATION
set -u

DOMAIN="${CERTBOT_DOMAIN#\*.}"
VALUE="${CERTBOT_VALIDATION}"

echo "[cleanup-hook] ${CERTBOT_DOMAIN} -> retrait TXT sur ${DOMAIN}"

ACME_ZONEDIR=/etc/bind/zones /root/acme_txt.sh remove "${DOMAIN}" "${VALUE}"
ssh -4 -o BatchMode=yes root@www.lslinux.org "ACME_ZONEDIR=/var/bind/pri /root/acme_txt.sh remove '${DOMAIN}' '${VALUE}'"
