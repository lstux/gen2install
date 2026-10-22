#!/bin/sh
# certbot --manual-auth-hook. Deploye en /etc/letsencrypt/hooks/auth.sh sur
# lslng. Variables fournies par certbot : CERTBOT_DOMAIN, CERTBOT_VALIDATION
set -u

DOMAIN="${CERTBOT_DOMAIN#\*.}"
VALUE="${CERTBOT_VALIDATION}"

echo "[auth-hook] ${CERTBOT_DOMAIN} -> ajout TXT sur ${DOMAIN}"

ACME_ZONEDIR=/etc/bind/zones /root/acme_txt.sh add "${DOMAIN}" "${VALUE}"
ssh -4 -o BatchMode=yes root@www.lslinux.org "ACME_ZONEDIR=/var/bind/pri /root/acme_txt.sh add '${DOMAIN}' '${VALUE}'"

echo "[auth-hook] attente propagation DNS (30s)..."
sleep 30
