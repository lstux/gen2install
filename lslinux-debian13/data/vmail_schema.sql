-- /etc/mail/vmail.db

CREATE TABLE domains (
    domain      TEXT PRIMARY KEY,
    active      INTEGER NOT NULL DEFAULT 1
);

CREATE TABLE mailboxes (
    email       TEXT PRIMARY KEY,        -- user@domain.tld
    domain      TEXT NOT NULL REFERENCES domains(domain),
    password    TEXT NOT NULL,           -- hash doveadm (SHA512-CRYPT par ex.)
    maildir     TEXT NOT NULL,           -- ex: domain.tld/user/
    active      INTEGER NOT NULL DEFAULT 1,
    quota_mb    INTEGER DEFAULT 0        -- 0 = illimité, pratique si tu veux limiter plus tard
);

CREATE TABLE aliases (
    source      TEXT NOT NULL,           -- alias@domain.tld ou @domain.tld (catch-all)
    destination TEXT NOT NULL,           -- adresse(s) cible, une ligne par destination
    domain      TEXT NOT NULL REFERENCES domains(domain),
    active      INTEGER NOT NULL DEFAULT 1
);

CREATE INDEX idx_mailboxes_domain ON mailboxes(domain);
CREATE INDEX idx_aliases_domain ON aliases(domain);
CREATE INDEX idx_aliases_source ON aliases(source);
