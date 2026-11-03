#!/bin/sh

sed -i "/^lslng/d" ~/.ssh/known_hosts && ssh root@lslng.lslinux.org apt -y install python3-apt

ansible-playbook -i lslng.lslinux.org, lslng_debootstrap.yml -t disks

ssh root@lslng.lslinux.org "cp /mnt/gentoo/usr/local/bin/chrootrun /usr/local/bin/chrootrun"

ssh -t root@lslng.lslinux.org "/usr/local/bin/chrootrun /mnt/gentoo"
