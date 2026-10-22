#!/bin/sh
# Installe sur lslng : /usr/local/sbin/fail2ban-textfile (timer fail2ban-textfile.timer, chaque minute).
# Ecrit les metriques fail2ban dans le collecteur textfile de node-exporter.
out=/var/lib/prometheus/node-exporter/fail2ban.prom
tmp="${out}.$$"
{
  if jails="$(fail2ban-client status 2>/dev/null | sed -n 's/.*Jail list:[[:space:]]*//p' | tr -d ',')"; then
    echo "fail2ban_up 1"
  else
    echo "fail2ban_up 0"
    jails=""
  fi
  for j in ${jails}; do
    st="$(fail2ban-client status "${j}" 2>/dev/null)" || continue
    v() { printf '%s\n' "${st}" | sed -n "s/.*$1:[[:space:]]*//p" | head -n1; }
    echo "fail2ban_failed_current{jail=\"${j}\"} $(v 'Currently failed')"
    echo "fail2ban_failed_total{jail=\"${j}\"} $(v 'Total failed')"
    echo "fail2ban_banned_current{jail=\"${j}\"} $(v 'Currently banned')"
    echo "fail2ban_banned_total{jail=\"${j}\"} $(v 'Total banned')"
  done
} > "${tmp}"
chmod 0644 "${tmp}"
mv "${tmp}" "${out}"
