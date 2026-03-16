#!/bin/bash
set -e

DISK1=/dev/nvme0n1
DISK2=/dev/nvme1n1

BOOTSIZE=1G
ROOTSIZE=20G
VGNAME=vg00


echo "=== wipe disks ==="
wipefs -a $DISK1
wipefs -a $DISK2

sgdisk -Z $DISK1
sgdisk -Z $DISK2

echo "=== partition ==="

sgdisk -n1:1M:+${BOOTSIZE} -t1:EF00 ${DISK1}
sgdisk -n2:0:0 -t2:FD00 ${DISK1}

sgdisk -n1:1M:+${BOOTSIZE} -t1:EF00 ${DISK2}
sgdisk -n2:0:0 -t2:FD00 ${DISK2}

partprobe

echo "=== RAID1 ==="

mdadm --create /dev/md0 \
  --level=1 \
  --raid-devices=2 \
  ${DISK1}p2 ${DISK2}p2

echo "=== LVM ==="

pvcreate /dev/md0
vgcreate "${VGNAME}" /dev/md0

lvcreate -L "${ROOTSIZE}" -n root vg0

echo "=== format ==="

mkfs.vfat -F32 ${DISK1}p1
mkfs.vfat -F32 ${DISK2}p1

mkfs.ext4 /dev/${VGNAME}/root

echo "=== mount ==="

mount /dev/${VGNAME}/root /mnt/gentoo
mkdir -p /mnt/gentoo/boot

mount ${DISK1}p1 /mnt/gentoo/boot

echo "=== download stage3 ==="

cd /mnt/gentoo

STAGE3=$(curl -s https://distfiles.gentoo.org/releases/amd64/autobuilds/latest-stage3-amd64-openrc.txt | awk '{print $1}')

wget https://distfiles.gentoo.org/releases/amd64/autobuilds/$STAGE3

tar xpvf stage3-*.tar.xz --xattrs-include='*.*' --numeric-owner

echo "=== prepare chroot ==="

cp --dereference /etc/resolv.conf /mnt/gentoo/etc/

mount --types proc /proc /mnt/gentoo/proc
mount --rbind /sys /mnt/gentoo/sys
mount --make-rslave /mnt/gentoo/sys
mount --rbind /dev /mnt/gentoo/dev
mount --make-rslave /mnt/gentoo/dev

chroot /mnt/gentoo /bin/bash << 'EOF'

source /etc/profile

echo "Europe/Paris" > /etc/timezone
emerge --config sys-libs/timezone-data

echo 'MAKEOPTS="-j8"' >> /etc/portage/make.conf

emerge-webrsync

emerge \
sys-kernel/gentoo-kernel \
sys-boot/grub \
sys-fs/mdadm \
sys-fs/lvm2 \
net-misc/dhcpcd \
sys-fs/dosfstools

rc-update add mdadm boot
rc-update add lvm boot
rc-update add dhcpcd default

echo "root:changeme" | chpasswd

mdadm --detail --scan >> /etc/mdadm.conf

cat <<FSTAB > /etc/fstab
/dev/vg0/root / ext4 defaults 0 1
/dev/nvme0n1p1 /boot vfat defaults 0 2
FSTAB

echo "=== grub ==="

grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=gentoo

mkdir -p /boot/EFI/BOOT
cp /boot/EFI/gentoo/grubx64.efi /boot/EFI/BOOT/BOOTX64.EFI

grub-mkconfig -o /boot/grub/grub.cfg

EOF

echo "=== mirror EFI ==="

mkdir /mnt/boot2
mount ${DISK2}p1 /mnt/boot2

cp -r /mnt/gentoo/boot/* /mnt/boot2/

umount /mnt/boot2

echo "Installation terminée"
echo "Reboot et boot sur disque"
