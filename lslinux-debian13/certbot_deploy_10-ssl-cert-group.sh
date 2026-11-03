#!/bin/sh

chown root:ssl-cert /etc/letsencrypt/live /etc/letsencrypt/archive && \
chmod 750 /etc/letsencrypt/live /etc/letsencrypt/archive && \
chmod 640 /etc/letsencrypt/archive/*/privkey*.pem
