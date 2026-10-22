#!/bin/sh
# Installe sur lslng : /usr/local/sbin/mailpw (root, appele par www-data via sudo).
# Usage : echo NOUVEAU_MDP | sudo mailpw user@domaine
set -eu
DB=/var/lib/vmail/vmail.db

user="${1:-}"
case "${user}" in
  *[!A-Za-z0-9._@+-]*|"") exit 2;;
esac
case "${user}" in
  *@*.*) ;;
  *) exit 2;;
esac

IFS= read -r pw || exit 2
[ "${#pw}" -ge 10 ] || exit 3

hash="$(printf '%s\n' "${pw}" | openssl passwd -6 -stdin)"
case "${hash}" in
  '$6$'*) ;;
  *) exit 4;;
esac
case "${hash}" in
  *\'*|*\"*) exit 4;;
esac

changed="$(runuser -u vmail -- sqlite3 "${DB}" "UPDATE mailboxes SET password='${hash}' WHERE email='${user}' AND active=1; SELECT changes();")"
[ "${changed}" = "1" ] || exit 5
