<?php

// Driver du plugin password : delegue l'ecriture au helper root /usr/local/sbin/mailpw (sudo).
// Installe par 110_roundcube.sh dans /usr/share/roundcube/plugins/password/drivers/.

class rcube_mailpw_password
{
    public function save($currpass, $newpass, $username)
    {
        $handle = popen('sudo /usr/local/sbin/mailpw ' . escapeshellarg($username) . ' 2>/dev/null', 'w');
        if (!$handle) {
            return PASSWORD_ERROR;
        }

        fwrite($handle, "$newpass\n");

        return pclose($handle) === 0 ? PASSWORD_SUCCESS : PASSWORD_ERROR;
    }
}
