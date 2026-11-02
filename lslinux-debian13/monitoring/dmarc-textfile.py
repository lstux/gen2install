#!/usr/bin/env python3
# Installe sur lslng : /usr/local/sbin/dmarc-textfile (timer dmarc-textfile.timer, toutes les heures).
# Lit les rapports DMARC agreges (RFC 7489, XML) recus dans la boite el@ruedesrancy.org,
# les archive en XML brut, puis ecrit des metriques dans le collecteur textfile de node-exporter.
#
# - Dedoublonnage : un rapport = (organisation, report_id) ; le nom du fichier archive le porte.
#   Si le fichier existe, le rapport est deja pris en compte.
# - Retention : les XML archives sont supprimes au-dela de DMARC_RETENTION_DAYS (mtime).
# - Purge (DMARC_PURGE=1) : une fois le rapport archive, le message est retire de la boite via
#   doveadm expunge (pas de unlink : l'index Dovecot reste coherent). Desactive par defaut.
# - Les Maildirs sont lus, jamais deplaces (mailbox.Maildir).
import gzip
import io
import mailbox
import os
import re
import subprocess
import sys
import time
import zipfile
import xml.etree.ElementTree as ET

MAILDIR = os.environ.get("DMARC_MAILDIR", "/var/lib/vmail/vhosts/ruedesrancy.org/el/mail")
MAILUSER = os.environ.get("DMARC_MAILUSER", "el@ruedesrancy.org")
STORE = os.environ.get("DMARC_STORE", "/var/lib/dmarc/reports")
PROM = os.environ.get("DMARC_PROM", "/var/lib/prometheus/node-exporter/dmarc.prom")
RETENTION_DAYS = int(os.environ.get("DMARC_RETENTION_DAYS", "30"))
WINDOW_DAYS = int(os.environ.get("DMARC_WINDOW_DAYS", "7"))
PURGE = os.environ.get("DMARC_PURGE", "0") == "1"
TOP_FAILING = 20

DAY = 86400
NOW = time.time()


def safe(text):
    return re.sub(r"[^A-Za-z0-9._@-]", "_", text or "")


def esc(value):
    return str(value).replace("\\", "\\\\").replace('"', '\\"').replace("\n", " ")


def xml_from_part(part):
    """XML bruts contenus dans une piece jointe (brut, gzip ou zip)."""
    name = (part.get_filename() or "").lower()
    payload = part.get_payload(decode=True)
    if not payload:
        return []
    if name.endswith(".zip") or payload[:2] == b"PK":
        with zipfile.ZipFile(io.BytesIO(payload)) as zf:
            return [zf.read(n) for n in zf.namelist() if n.lower().endswith(".xml")]
    if name.endswith(".gz") or payload[:2] == b"\x1f\x8b":
        return [gzip.decompress(payload)]
    if name.endswith(".xml") or part.get_content_type() in ("application/xml", "text/xml"):
        return [payload]
    return []


def feedback_reports(msg):
    """Rapports DMARC (racine <feedback>) d'un message : liste de (report_id, org, xml_bytes)."""
    found = []
    for part in msg.walk():
        if part.is_multipart():
            continue
        for raw in xml_from_part(part):
            try:
                root = ET.fromstring(raw)
            except ET.ParseError:
                continue
            if root.tag != "feedback":
                continue
            meta = root.find("report_metadata")
            rid = meta.findtext("report_id", default="").strip()
            if rid:
                found.append((rid, meta.findtext("org_name", default="unknown"), raw))
    return found


def archive(rid, org, raw):
    """Ecrit le rapport s'il n'existe pas. Retourne True si nouveau."""
    path = os.path.join(STORE, "%s!%s.xml" % (safe(org), safe(rid)))
    if os.path.exists(path):
        return False
    tmp = path + ".tmp"
    with open(tmp, "wb") as f:
        f.write(raw)
    os.chmod(tmp, 0o640)
    os.replace(tmp, path)
    return True


def ingest():
    """Archive les nouveaux rapports. Retourne (nb_nouveaux, Message-ID des messages traites)."""
    new = 0
    done = []
    box = mailbox.Maildir(MAILDIR, create=False)
    for key in box.keys():
        msg = box.get_message(key)
        reports = feedback_reports(msg)
        if not reports:
            continue
        for rid, org, raw in reports:
            if archive(rid, org, raw):
                new += 1
        mid = (msg.get("Message-ID") or "").strip()
        if mid:
            done.append(mid)
    return new, done


def purge(message_ids):
    """Retire de l'INBOX les messages archives (doveadm expunge par Message-ID)."""
    for mid in message_ids:
        subprocess.run(
            ["doveadm", "expunge", "-u", MAILUSER, "mailbox", "INBOX", "header", "Message-ID", mid],
            check=True,
        )


def prune():
    for name in os.listdir(STORE):
        path = os.path.join(STORE, name)
        if name.endswith(".xml") and NOW - os.path.getmtime(path) > RETENTION_DAYS * DAY:
            os.remove(path)


def load_reports():
    """Rapports archives : liste de (org, date de fin, domaine, records)."""
    out = []
    for name in sorted(os.listdir(STORE)):
        if not name.endswith(".xml"):
            continue
        root = ET.parse(os.path.join(STORE, name)).getroot()
        meta = root.find("report_metadata")
        end = int(meta.findtext("date_range/end", default="0"))
        org = meta.findtext("org_name", default="unknown")
        domain = root.findtext("policy_published/domain", default="unknown")
        out.append((org, end, domain, root.findall("record")))
    return out


def build_metrics(reports):
    """Lignes du fichier textfile, sur la fenetre WINDOW_DAYS."""
    window_start = NOW - WINDOW_DAYS * DAY
    msgs = {}        # (domain, dkim, spf, disposition, dmarc) -> count
    failing = {}     # (domain, source_ip) -> count
    nb_reports = {}  # (domain, org) -> reports dans la fenetre
    last = {}        # domain -> date de fin la plus recente (tous rapports)

    for org, end, domain, records in reports:
        last[domain] = max(last.get(domain, 0), end)
        if end < window_start:
            continue
        nb_reports[(domain, org)] = nb_reports.get((domain, org), 0) + 1
        for rec in records:
            row = rec.find("row")
            pol = row.find("policy_evaluated")
            dkim = pol.findtext("dkim", default="none")
            spf = pol.findtext("spf", default="none")
            disp = pol.findtext("disposition", default="none")
            count = int(row.findtext("count", default="0"))
            ip = row.findtext("source_ip", default="")
            dmarc = "pass" if "pass" in (dkim, spf) else "fail"
            key = (domain, dkim, spf, disp, dmarc)
            msgs[key] = msgs.get(key, 0) + count
            if dmarc == "fail":
                fkey = (domain, ip)
                failing[fkey] = failing.get(fkey, 0) + count

    lines = [
        "# HELP dmarc_messages Messages des rapports DMARC sur la fenetre, par resultat",
        "# TYPE dmarc_messages gauge",
    ]
    for (domain, dkim, spf, disp, dmarc), n in sorted(msgs.items()):
        lines.append(
            'dmarc_messages{domain="%s",dkim="%s",spf="%s",disposition="%s",dmarc="%s"} %d'
            % (esc(domain), dkim, spf, disp, dmarc, n)
        )
    lines.append("# TYPE dmarc_failing_messages gauge")
    top = sorted(failing.items(), key=lambda kv: -kv[1])[:TOP_FAILING]
    for (domain, ip), n in top:
        lines.append('dmarc_failing_messages{domain="%s",source_ip="%s"} %d' % (esc(domain), esc(ip), n))
    lines.append("# TYPE dmarc_reports gauge")
    for (domain, org), n in sorted(nb_reports.items()):
        lines.append('dmarc_reports{domain="%s",org="%s"} %d' % (esc(domain), esc(org), n))
    lines.append("# TYPE dmarc_last_report_timestamp_seconds gauge")
    for domain, end in sorted(last.items()):
        lines.append('dmarc_last_report_timestamp_seconds{domain="%s"} %d' % (esc(domain), end))
    return lines


def write_prom(lines):
    tmp = PROM + ".%d" % os.getpid()
    with open(tmp, "w") as f:
        f.write("\n".join(lines) + "\n")
    os.chmod(tmp, 0o644)
    os.replace(tmp, PROM)


def main():
    os.makedirs(STORE, mode=0o750, exist_ok=True)
    new, done = ingest()
    if PURGE and done:
        purge(done)
    prune()
    lines = ["dmarc_parse_ok 1", "dmarc_new_reports %d" % new, "dmarc_run_timestamp_seconds %d" % NOW]
    lines += build_metrics(load_reports())
    write_prom(lines)


if __name__ == "__main__":
    try:
        main()
    except Exception as exc:  # toute erreur doit remonter en metrique
        sys.stderr.write("dmarc-textfile: %s\n" % exc)
        try:
            write_prom(["dmarc_parse_ok 0", "dmarc_run_timestamp_seconds %d" % NOW])
        except OSError:
            pass
        sys.exit(1)
