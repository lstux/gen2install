# Brief : migration lslinux.org (Gentoo → Debian 13)

Salut, collègue. Tu bosses avec Eric sur la migration de son serveur perso/hébergement `lslinux.org`. On se tutoie, ton détendu. Profil sysadmin : on préfère le **stable et robuste** aux étoiles filantes. Eric est à l'aise en bas niveau (AppArmor, named-checkconf, AXFR, SMART, Portage...), pas besoin de lui expliquer les bases.

## Contexte

- **Ancien serveur** : Gentoo, disque en piteux état (SMART critique). À décommissionner.
- **Nouveau serveur** : Kimsufi KS-1 (OVH), 16 Go de RAM, 2×480 Go SSD en RAID logiciel, **Debian 13**, installation **par apt**.
- **Contrainte d'archi** : bien séparer **conf / data / app** (il envisage un retour sur Gentoo plus tard, donc rien de "magique" Debian-spécifique non documenté).
- **Accès** : `ssh debian@lslng.lslinux.org` (cf. `server.conf`), sudo dispo.

## Services vitaux

Bind9, Nginx, PHP-FPM, MariaDB, Postfix (domaines virtuels) + IMAP, Nextcloud. Aussi WordPress et Piwigo.

**Domaines hébergés** : lslinux.org, ruedesrancy.org, ossn.info, saintmarc.bzh (sans certificat pour l'instant). jumalee.com est abandonné (hors migration).
DNS secondaire chez OVH (IPs déjà configurées côté OVH).

## Organisation des scripts (sur le PC, dans `$WORKDIR`)

- Scripts shell POSIX (`#!/bin/sh`), numérotés (`010_bind9.sh`, `020_postfix_dovecot.sh`, ...), lancés **depuis le PC**.
- Ils sourcent `$WORKDIR/server.conf` (`SSH_USER`, `SSH_HOST`, `SSH`, `SUSSH="${SSH} sudo"`).
- Argument obligatoire : `backup` | `restore` | `status` (+ `upgrade`, `dbfix`, `save`, `tune`, `vhost`, `rowformat`, `mimetypes`, `phpini`, `apps` pour `090_nextcloud.sh` ; `tune` pour `080_mariadb.sh` ; `install-lslng|install-nsbox|access|cron-nsbox|run` pour `95` ; `packages|configure|activate|reload` pour `100`).
- Scripts actuels : 10 bind9, 20 postfix_dovecot, 30 fail2ban, 40 rspamd_clamav, 50 mail_sync, 60 certbot_dns01, 70 nginx (+ vhosts dans `nginx/`), 80 mariadb, 90 nextcloud, 95 backup_nsbox, 100 monitoring (configs dans `monitoring/`, scripts nsbox/lslng dans `backup/`).
- Backups = tarballs dans `$WORKDIR/data/` (`xxx_YYYYMMDD.tgz` + symlink `xxx.tgz`). Schémas SQL gardés en local aussi (ex. `vmail_schema.sql`).
- **Les scripts ne démarrent pas les services** : ils affichent la commande finale, on valide avant de restart.
- `010_bind9.sh` = le modèle à suivre pour les suivants.

### Points à vérifier dans l'existant

- `SUSSH` est maintenant défini dans `server.conf`.
- Motif `tar xvpzf local | ssh ...` dans les `restore` : **corrige** dans 10, 20, 30, 40, 60, 70, 80 (`cat data/xxx.tgz | ${SSH} "sudo tar xvzpf - -C ..."`). Jamais testes en conditions reelles : a rejouer avec prudence.
- `restore` de `010_bind9.sh` pousse les confs **avant** `apt install bind9` : conflit possible avec les fichiers du paquet.
- `usage()` met `$(basename ...)` dans le format du `printf` : à passer en `%s` si on retouche.

## État d'avancement (à vérifier sur le serveur, ne pas supposer)

| Étape | Statut (dernière vérif. 2026-10-21) |
|---|---|
| Bind9 | Migré, fonctionnel (primaire sur lslng, secondaire OVH `sdns2.ovh.net`). Les 4 domaines sont délégués à lslng + sdns2 chez les registres (`saintmarc.bzh` compris, plus de NS à part). Zone `acme.lslinux.org` déléguée à lslng pour le DNS-01. **sdns2 est lent à rattraper les serials** (parfois plusieurs heures malgré les NOTIFY) : toujours comparer `dig +short SOA <zone> @sdns2.ovh.net` à `@lslng.lslinux.org` après une modif. Au 2026-10-21 soir, `lslinux.org` y est encore à 2026101904 (lslng : 905) |
| Certificats | Certificat `lslinux` dans `/etc/letsencrypt/live/lslinux/` (SAN : lslinux.org, ruedesrancy.org, ossn.info + wildcards ; DNS-01 par délégation `acme.`). Renouvellement validé en dry-run |
| fail2ban | Installé, `jail.local` durci, jail sshd. Jails à revoir pour nginx/Nextcloud |
| Mail | Fait : Postfix + Dovecot 2.4 + SQLite (`/var/lib/vmail/vmail.db`, `/var/lib/vmail/vhosts/`, vmail 5000:5000) |
| rspamd (+ClamAV) | Fait (`040_rspamd_clamav.sh`), branché dans Postfix |
| SPF / DKIM / DMARC | Fait et validé en conditions réelles le 2026-10-21 (mail lslng -> Gmail : `dkim=pass` sélecteur `dkim`, `spf=pass`, `dmarc=pass`, TLS 1.3). SPF de `spf.lslinux.org` et des apex avec les IP lslng ; `_dmarc` `p=none` sur les 4 domaines (rapports vers el@ruedesrancy.org, autorisés par les TXT `<dom>._report._dmarc` dans ruedesrancy.org). PTR v4 et v6 de lslng = `lslng.lslinux.org` (v6 posé par Eric dans le manager OVH le 2026-10-21). Premier envoi vers Gmail classé spam (IP neuve, pas de réputation) : à surveiller, Postmaster Tools si ça persiste |
| Bascule mail | **Faite le 2026-10-21 à 20:30 UTC.** `ruedesrancy.org` : MX direct vers lslng (depuis le 15/10). `lslinux.org`, `ossn.info`, `saintmarc.bzh` : MX = `mail.lslinux.org`, dont l'A/AAAA pointe maintenant sur lslng (145.239.67.105 / 2001:41d0:303:3669::1). Dernier `sync` + `mark` des 3 domaines fait avant. Réception testée sur eric@lslinux.org, patrick@saintmarc.bzh, annie.lecat@ossn.info (livrées par LMTP, rspamd propre). `rescuedry` à 22:xx : 0 message à rapatrier. Postfix : `smtp_address_preference = ipv4` (envoi IPv4 d'abord ; repasser à `any` quand la réputation est établie). **À refaire demain : `rescuedry`/`rescue`** (sdns2 sert encore genserv pour `mail.lslinux.org`). Domaines de la table `domain` de genserv sans boîte ici : esthe-tech.com/.fr, studio-cabriolet.com (état à confirmer avec Eric) |
| Nginx / PHP-FPM 8.4 | Fait : vhosts dans `nginx/` (lslinux.org, ruedesrancy.org, ossn.info, saintmarc.bzh, cloud, catchall), `070_nginx.sh` |
| MariaDB | Fait (`080_mariadb.sh`), base `nextcloud`. Réglages Nextcloud dans `mariadb/60-nextcloud.cnf` (buffer pool 1 Go, log 256 Mo, tmp 64 Mo), appliqués le 2026-10-18, MariaDB redémarré |
| Nextcloud | **Migré et en production sur lslng** : `cloud.lslinux.org` -> lslng (DNS A/AAAA, TTL 300). Version **35.0.2.2** (montées 31->35, `dbfix`, `rowformat`, `mimetypes` faits). Cache APCu + Redis, verrouillage Redis, cron par timer systemd (5 min), vhost durci (en-têtes, `.mjs`). **Rétention appliquée le 2026-10-18 : corbeille `auto, 90`, versions `auto, 365`** (validée par Eric/Annie, sans snapshot nsbox préalable ; les originaux restent sur genserv). Apps tierces installées et activées (calendar, integration_github, maps, memories), dans `/var/lib/nextcloud/apps`. Reste : ~80 tables orphelines de vieilles apps |
| WordPress / Piwigo | **Pas à migrer** (décision d'Eric) |
| Backups (nsbox) | Script de snapshot installé : `/backup/lslng/00_snapshot.sh` sur nsbox (pull rsync `--link-dest`, 7 jours + 4 dimanches). **Pas encore actif** : manque la clé SSH (`095_backup_nsbox.sh access`), le 1er snapshot (~85 Go, `run`) et le cron (`cron-nsbox`). Dump MariaDB quotidien sur lslng par timer systemd (`mariadb-dump-all.timer`, 03:30, `/var/backups/mariadb`) : actif |
| Monitoring | **Actif sur lslng** : Prometheus, Alertmanager, node/mysqld/nginx/bind/postfix/phpfpm-exporter, rspamd (endpoint natif :11334/metrics), mtail (logs nginx, :3903), collecteur fail2ban (textfile node-exporter, timer 1 min) — tout en 127.0.0.1 ; Grafana (dépôt apt officiel) sur `https://grafana.lslinux.org`, 8 dashboards dossier « lslng » (Node, MySQL, NGINX, Bind9 de grafana.com + `lslng-services`, `mail`, `fail2ban`, `web` maison). Alertes mail vers webadm@laposte.net testées. Pas de check externe depuis nsbox |
| Proxy genserv -> lslng | genserv relaie `cloud.lslinux.org` vers lslng (nginx, `nginx/genserv_nextcloud.conf`) pour les clients au DNS non à jour. lslng : `trusted_proxies` = 178.32.216.3. À retirer au décommissionnement |
| Bascules DNS web | Mail fait (voir ci-dessus). **Reste le web** : A/AAAA de l'apex et de `www` de lslinux.org, ossn.info, saintmarc.bzh (saintmarc.bzh a son A sur lslng, `www` aussi ; lslinux.org et ossn.info pointent encore sur genserv 178.32.216.3 ; ruedesrancy.org apex et `www` sur 188.165.218.162, autre serveur qui figure aussi dans les SPF : à identifier, hors genserv et lslng). `mail.ossn.info` est un CNAME vers `adm.ossn.info` (A genserv) : à repointer seulement si des clients IMAP l'utilisent (`adm` a d'autres usages, ne pas le basculer pour le mail). `mailadmin` est un CNAME genserv |
| Décommissionnement genserv | À faire en dernier, après un backup complet hors serveur (nsbox). Nextcloud genserv en maintenance, `/var/nextcloud` (40 Go) toujours présent : ne rien supprimer sans demande explicite |

## Pièges déjà rencontrés (à respecter)

**Mail**
- `myhostname` doit être un FQDN (`lslng.lslinux.org`). Retirer `lslinux.org` de `mydestination` (conflit avec les domaines virtuels).
- TLS : utiliser `fullchain.pem` (pas `cert.pem`) pour Postfix et Dovecot.
- Accès à `privkey.pem` : groupe `ssl-cert` sur `/etc/letsencrypt/{live,archive}`, `postfix` (et `dovecot` si besoin) dans ce groupe.
- SQLite choisi plutôt que MariaDB + PostfixAdmin (seul vrai usage de PostfixAdmin : changer les mots de passe).
- genserv : tables MySQL `vmail` (`domain`, `mailbox`, `alias`), PostfixAdmin ; chaque boîte y a un alias vers elle-même (inutile ici). Alias et boîtes vérifiés identiques à `vmail.db` le 2026-10-21 pour lslinux.org, ossn.info, saintmarc.bzh (pas de catch-all, pas de filtres). `postmaster@saintmarc.bzh` -> patrick créé côté lslng (absent de genserv). Lecture MySQL de genserv : `root` refusé, utiliser `vmailro` (mot de passe dans `/etc/postfix/mysql/*.cf`).
- `050_mail_sync.sh` (à lancer en root sur lslng, copié via `cat | ssh`) : `dryrun`, `sync`, `mark <dom>`, `rescuedry`/`rescue <dom>`. Ordre de bascule : dernier `sync`, `mark`, DNS, tests, `rescue`. Après `mark`, jamais de `sync` sur le domaine (`--delete`).
- Premier accès Dovecot à un Maildir hérité de genserv (Courier 2019) : il renomme les doublons de nom de base (« Fixed a duplicate », rien n'est perdu, les messages invisibles réapparaissent). Même un simple `doveadm mailbox status` écrit donc dans les Maildirs.
- Dossiers Maildir de genserv parfois en **UTF-8 brut** (`.Trash.Coët Derv…`, `.Envoyés`) : Dovecot attend l'UTF-7 modifié (`Co&AOs-t`), sinon dossier listé mais inaccessible. `fix_utf8_folders.sh {dry|apply}` (root, sur lslng) renomme, ou fusionne si la cible existe sans nom commun. À lancer après le dernier `sync` du domaine (sinon `--delete` les efface et le sync les recrée). Appliqué le 2026-10-21 (Envoyés d'Eric fusionné, 3 dossiers de Patrick).
- Édition de zone : `set_txt.sh <dom> <nom> <valeur> [ttl]` (TXT simple une ligne), `set_addr.sh <dom> <nom> <v4> <v6>` (A+AAAA), `set_dkim_txt.sh` (clé multi-chaînes). Tous : à lancer en root sur lslng (zones dans `/etc/bind/zones`), serial lu par `named-checkzone`, sauvegarde dans `/root/zone_backups` (suffixe PID), diff, `rndc reload <zone>`. Plusieurs modifs dans la même seconde ne s'écrasent plus (les sauvegardes du 2026-10-21 16:02 de lslinux.org et ruedesrancy.org sont des états intermédiaires).
- Réglage Postfix hors script par paramètre : `020_postfix_dovecot.sh backup` sauvegarde `main.cf` en bloc ; après un `postconf -e`, relancer `backup`.
- Garde-fou de l'outil : les modifications DNS et les commandes `mark`/prod sont parfois refusées par le classifieur automatique de Claude Code ; Eric les lance alors lui-même (`!`). Ne pas imbriquer de `ssh` (lslng -> genserv) : ça bloque sans authentification.

**Dovecot 2.4 (Debian 13) — ruptures vs 2.3**
- Toute doc antérieure est suspecte : valider avec `doveconf -n`, fichier par fichier.
- En tête de `dovecot.conf` : `dovecot_config_version = 2.4.0` et `dovecot_storage_version = 2.4.0`.
- passdb/userdb SQL en ligne (plus de `dovecot-sql.conf.ext`).
- `ssl_server_cert_file` / `ssl_server_key_file`.
- `mail_driver` + `mail_home` à la place de `mail_location`.
- Variables : `%{user}`, `%{user|domain}`, `%{user|username}`.

**Certificats / DNS**
- Hook de renouvellement dans `renewal-hooks/deploy/` (pas `post/`), à réappliquer les permissions `ssl-cert` après renouvellement. **Posés sur lslng** (`10-ssl-cert-group.sh`, `99-services-reload.sh` dans `/etc/letsencrypt/renewal-hooks/deploy/`) mais **pas encore intégrés à `060_certbot_dns01.sh`** : une réinstallation ne les recréerait pas (à faire). Les hooks DNS-01 `auth.sh`/`cleanup.sh` (sources : `certbot_auth_hook.sh`, `certbot_cleanup_hook.sh`, qui appellent `/root/acme_txt.sh`) sont, eux, déployés par ce script.
- Validation DNS-01 préférée (pas de dépendance à Nginx).
- Jamais de CNAME en cible MX.

**Plateforme**
- AppArmor Debian : chemins de logs non standard = override dans `/etc/apparmor.d/local/`.
- Nextcloud : pas de saut de plusieurs versions majeures, on enchaîne chaque majeure.

**Monitoring / backups (lslng)**
- Les paquets Debian démarrent leurs services à l'installation, sur toutes les interfaces : `100_monitoring.sh packages` utilise un `policy-rc.d` temporaire. Tout écoute sur 127.0.0.1, seul Grafana est exposé (nginx).
- mysqld-exporter 0.17 ignore `DATA_SOURCE_NAME` : il lit `/etc/prometheus/mysqld.cnf` (user `prometheus` en `unix_socket`). Métriques php-fpm : `php_fpm_*`.
- postfix-exporter lit `/var/log/mail.log` : il a tiré `rsyslog` (actif). Postfix logge alors aussi dans `mail.log`.
- Grafana : changer l'uid d'un datasource existant le fait planter au démarrage ; il faut un `deleteDatasources`. Mot de passe admin dans `/etc/grafana/grafana.env` (0640).
- Stats web : `monitoring/nginx.mtail` produit `weblog_*` par fichier de log (= vhost) ; chemins limités au 1er segment et aux 2xx/3xx (anti-cardinalité). mtail ne lit les logs qu'à partir de son démarrage. Pas d'exporter Debian pour fail2ban/rspamd/nginxlog : fail2ban via `/usr/local/sbin/fail2ban-textfile`, rspamd via son endpoint natif. Loki/Alloy existent dans Debian 13 mais non retenus (poids).
- Vhost cloud : `set_real_ip_from 178.32.216.3` + `real_ip_header X-Forwarded-For` (vraies IP derrière le proxy genserv ; à retirer avec lui). Attention aux remplacements de texte dans les vhosts : la directive a d'abord atterri dans le `location` du port 80.
- genserv résout `cloud.lslinux.org` vers lui-même (hosts) : ses clients de synchro (Nextcloud mirall) passent par son proxy. À revoir au décommissionnement.
- Disques : 2 NVMe Intel, ~79 500 h chacun (~9 ans), sains. Alertes NVMe via le collecteur textfile `nvme` (pas `smartmon`).
- lslng n'a pas cron : timers systemd. nsbox (Gentoo) a cron (`/etc/cron.d`) ; l'ancien backup genserv est `/backup/genserv/00_sync.sh` (miroir `--delete`, cron commenté).
- Le RAID n'est pas un backup : un backup hors lslng (nsbox) est requis avant d'éteindre genserv.

**Nextcloud (lslng)**
- Layout : code `/var/www/nextcloud-<ver>` + lien `/var/www/nextcloud`, config `/etc/nextcloud/` (lien `config` dans le code), données `/var/lib/nextcloud/data` (LV `lvnextcloud` 60 Go, ext4, fstab `LABEL=nextcloud`), logrotate `/etc/logrotate.d/nextcloud` (loglevel 2).
- **Après chaque montée : `systemctl reload php8.4-fpm`**, sinon opcache sert l'ancien code et Nextcloud affiche « Downgrading is not supported ».
- **Ne jamais extraire une archive Nextcloud directement dans `/var/www/`** : tar remplace le lien `/var/www/nextcloud` par un dossier. `090_nextcloud.sh` extrait dans un répertoire temporaire.
- `090_nextcloud.sh upgrade` (NC_VERSION + NC_GPG_FPR requis) : une majeure à la fois, dump `/root/nc-pre-<ver>.sql.gz`, maintenance, bascule du lien, `occ upgrade`. `dbfix` : index manquants + `convert-filecache-bigint` (base héritée de genserv).
- Vérification d'archive : SHA256 (ligne de l'archive seule dans le `.sha256`) + GPG, empreinte `28806A878AE423A28372792ED75899B9A724937A` (fournie par Eric).
- **Incident 2026-10-18 : ne jamais activer le cron Nextcloud sur une instance migrée sans garde-fou.** Le premier passage (arriéré de 102 000 jobs, cron mort depuis août) a vidé `files_versions` (46 556 fichiers, 6,9 Go) chez eric@ruedesrancy.org. Restauré depuis genserv (rsync), puis rétention mise à `disabled`. Cause exacte non établie (probablement l'expiration `auto`). Avant toute reprise du cron ou changement de rétention : compter les fichiers par `files`/`files_versions`/`files_trashbin` (baseline à 103 783 fichiers au 2026-10-18), lancer un passage unique surveillé, comparer.
- Impact attendu de `auto, 90` / `auto, 365` (appliquée) : 20 561 versions sur 46 559 (44 %) et 133 entrées de corbeille sur 564 (Annie 5,9 Go, Laure, Mag ; rien chez Eric). À valider avec Annie.
- MariaDB 11.8 : `innodb_buffer_pool_size_max` est fixé au démarrage, le buffer pool ne grossit qu'après un restart. L'alerte « Database configuration » de `serverinfo` est mise en cache (`appconfig serverinfo/cached_db_check`) : elle se recalcule avec retard.
- **Apps tierces persistantes** : `apps_paths` dans `/etc/nextcloud/config.php` = code `/var/www/nextcloud/apps` (non inscriptible) + `/var/lib/nextcloud/apps` (url `/apps-extra`, inscriptible). Les apps de l'app store s'installent dans le second. Chaque nouveau code reçoit un lien `apps-extra -> /var/lib/nextcloud/apps` (fait par `remote_install_code`, donc par `upgrade`) pour que nginx serve leurs ressources. Après une majeure, les apps incompatibles sont désactivées par `occ upgrade` : les mettre à jour depuis l'app store.
- PHP-FPM : `memory_limit` Debian = 128M, ce qui donnait une 500 sur `/settings/apps`. `php/99-nextcloud.ini` (512M, uploads 512M, 3600s, opcache interned 16) déployé par `090_nextcloud.sh phpini` ; un `reload php8.4-fpm` reste à faire à la main.
- `090_nextcloud.sh vhost` sauvegarde puis restaure l'ancien vhost si `nginx -t` échoue. `mimetypes` pause le timer cron et le relance via `ExecStopPost`.
- Un log Nextcloud de 52 Go non tourné sur genserv a été supprimé (loglevel 0). Surveiller la taille du log.

## Prochaines étapes (état au 2026-10-21)

1. **Fait le 2026-10-22** : sdns2 a rattrapé les 4 zones (`lslinux.org` 2026101905, `mail` -> lslng) ; `rescue lslinux.org` a rapatrié 1 message d'eric@lslinux.org arrivé sur genserv le 21/10 vers 22:35 UTC (sdns2 encore en retard) ; 0 pour ossn.info et saintmarc.bzh. Reste : un dernier `rescuedry` avant d'éteindre genserv, un envoi DKIM depuis ossn.info et saintmarc.bzh, et surveiller si le courrier Gmail sort toujours en spam.
2. Activer le backup nsbox : `095_backup_nsbox.sh access`, puis `run` (~85 Go), puis `cron-nsbox`. **Prérequis du décommissionnement de genserv** (la boîte mail y est maintenant une copie, les maildirs de lslng sont la référence).
3. Surveiller le cron Nextcloud (rétention active, jobs Maps/métadonnées). `/root/apps-moved-*` supprimé le 2026-10-18.
4. Bascules DNS **web** (apex/`www` de lslinux.org, ossn.info, ruedesrancy.org), décider du sort de `mail.ossn.info`/`adm.ossn.info`, confirmer les domaines esthe-tech.* / studio-cabriolet.com. `110_roundcube.sh` (webmail `wm.lslinux.org`) existe dans le dossier : état non revérifié ce soir.
5. Valider les dashboards Grafana avec Eric (Bind9/MySQL/NGINX de grafana.com non validés ; Mail/fail2ban/Web ajoutés le 2026-10-18, peu de données au départ). GoAccess pour les sites statiques : non retenu pour l'instant.
6. Premier commit git du dossier (aucun commit jusqu'ici), puis décommissionnement de genserv (proxy cloud à retirer).

## Stratégie de migration

1. TTL DNS abaissés en amont.
2. Services sans état d'abord (DNS), puis services à état (mail, bases, web) avec **rsync en deux passes** pour minimiser la fenêtre de perte.
3. MariaDB : `mysqldump` avant toute manip.
4. Nextcloud : mode maintenance pendant la synchro finale.
5. fail2ban : on revoit les jails à chaque nouveau service exposé.
6. Validation incrémentale : `named-checkconf -z`, `doveconf -n`, `postfix check`, `nginx -t` avant tout restart.

## Règles de conduite

- **Lecture seule d'abord.** Premier objectif : un état des lieux (voir ci-dessous), rien de modifié.
- Pas de restart de service, de `apt upgrade`, de modification DNS ni de suppression sans **confirmation explicite** d'Eric.
- Tout ce qui est fait sur le serveur doit pouvoir se rejouer via un script `NN_xxx.sh` (backup/restore/status). Pas de conf "à la main" non tracée.
- Toujours proposer le plan et demander confirmation avant d'agir.
- Pas de bidouille exotique : paquets Debian, chemins standard, conf documentée.

## Première mission : état des lieux (lecture seule) — fait, gardée comme checklist de revalidation

1. Lire `$WORKDIR` : liste des scripts, `server.conf`, contenu de `data/`.
2. Se connecter au nouveau serveur et relever : version Debian, uptime, `lsblk` + `cat /proc/mdstat` (RAID sain ?), `df -h`, `free -h`.
3. `systemctl --failed` et état de : bind9, postfix, dovecot, nginx, php-fpm, mariadb, fail2ban (installés ? actifs ?).
4. Bind9 : `named-checkconf -z`, une requête `dig @localhost` sur chaque domaine, cohérence avec le secondaire OVH.
5. Mail : `postconf -n` (myhostname, mydestination, virtual_*), `doveconf -n`, présence de `/var/lib/vmail/vmail.db`.
6. Certificats : `certbot certificates`, dates d'expiration, permissions groupe `ssl-cert`.
7. Écouter les ports (`ss -tlnp`) et comparer avec ce qui devrait être exposé.
8. Produire un **rapport synthétique** : ce qui est fait / à moitié fait / à faire, écarts avec ce brief, et un **plan proposé pour la suite** (probablement : finir `020_postfix_dovecot.sh`, puis rspamd + DNS mail, puis web). Attendre le feu vert d'Eric.
