<?php
// Gere par 110_roundcube.sh configure. Les credentials DB restent dans debian-db.php (dbconfig-common).
require_once '/etc/roundcube/debian-db.php';

$config = [];

$config['des_key'] = '__DES_KEY__';

$config['db_dsnw'] = "mysql://$dbuser:$dbpass@$dbserver/$dbname";

// IMAP local (Dovecot de lslng) en TLS ; le nom doit correspondre au certificat lslinux (*.lslinux.org).
$config['imap_host'] = 'ssl://lslng.lslinux.org:993';
$config['imap_conn_options'] = [
    'ssl' => ['verify_peer' => true, 'verify_peer_name' => true],
];

// Envoi via la soumission Postfix (587, STARTTLS, auth Dovecot).
$config['smtp_host'] = 'tls://lslng.lslinux.org:587';
$config['smtp_user'] = '%u';
$config['smtp_pass'] = '%p';
$config['smtp_conn_options'] = [
    'ssl' => ['verify_peer' => true, 'verify_peer_name' => true],
];

$config['login_autocomplete'] = 0;

$config['product_name'] = 'Webmail lslinux.org';
$config['enable_installer'] = false;
$config['log_driver'] = 'file';
$config['log_dir'] = '/var/log/roundcube/';
$config['temp_dir'] = '/var/lib/roundcube/temp/';
$config['plugins'] = ['password', 'archive', 'zipdownload', 'vcard_attachments', 'attachment_reminder'];

$config['password_driver'] = 'mailpw';
$config['password_minimum_length'] = 10;
$config['password_confirm_current'] = true;
$config['upload_max_filesize'] = '25M';
$config['default_charset'] = 'UTF-8';
