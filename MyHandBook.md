## Create partitions

fdisk "${GENTOO_INSTALL_DISK}"
* EFI partition (mkfs.vfat -F 32 "${GENTOO_EFI_PART}"
* LVM parition
  * VG vgsys
    * LV genroot ext4
    * LV swap
    * LV home ext4

## Mount partitions

* mount /dev/vgsys/genroot /mnt/gentoo
* mkdir /mnt/gentoo/efi && mount "${GENTOO_EFI_PART}" /mnt/gentoo/efi

## Install stage file

./src/stage3get.sh -OD -x /mnt/gentoo/

## Configure portage

./src/portageconfig.sh
./src/chrootrun.sh /mnt/gentoo getuto
./src/chrootrun.sh /mnt/gentoo emerge -DuNav world

## Misc (in chroot)
ln -sf /usr/share/zoneinfo/Europe/Paris /etc/localtime
nano /etc/locale.gen && locale-gen
emerge linux-firmware installkernel gentoo-kernel dhcpcd netifrc -av

nano /etc/fstab
PARTUUID=......  /efi  vfat umask=0077 0 2
LABEL=GENROOT    /     ext4 defaults   0 1
LABEL=HOME       /home ext4 defaults   0 0
LABEL=SWAP       none  sw   defaults   0 0

echo ${HOSTNAME} > /etc/hostname
grep "${HOSTNAME}" /etc/hosts || sed -i "/^127\.0\.0\.1/s/localhost/${HOSTNAME} localhost/" /etc/hosts
sed -i "s/keymap=\".\+\"/keymap=\"fr\"/" /etc/conf.d/keymaps

(emerge dhcpcd netifrc -av)

Set root password
Create unpriviliged user

## Installing tools (in chroot)

emerge -av syslog-ng logrotate cronie mlocate bash-completion chrony e2fsprogs dosfstools ntfs3g io-scheduler-udev-rules wpa_supplicant
for s in dhcpcd syslog-ng cronie chronyd sshd; do rc-update add "${s}" default; done

emerge grub -av && grub-install --efi-directory=/efi && grub-mkconfig -o /boot/grub/grub.cfg

reboot?
