#!/bin/sh

systemctl reload postfix dovecot
systemctl is-active --quiet nginx && systemctl reload nginx
exit 0
