## Create partitions
fdisk "${GENTOO_INSTALL_DISK}"
|-> EFI partition (mkfs.vfat -F 32 "${GENTOO_EFI_PART}"
|-> LVM parition -> VG vgsys --> LV genroot ext4
                             |-> LV swap
                             |-> LV home ext4

## Mount partitions
