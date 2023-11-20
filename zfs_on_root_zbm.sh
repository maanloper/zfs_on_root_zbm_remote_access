#!/bin/bash
#
export RELEASE="mantic"
export DISK="/dev/disk/by-id/"
export PASSPHRASE="SomeRandomKey"
export PASSWORD="mypassword"
export HOSTNAME="myhost"
export username="diego"

source /etc/os-release
export ID
export BOOT_DISK="${DISK}"
export BOOT_PART="1"
export BOOT_DEVICE="${BOOT_DISK}-part${BOOT_PART}"

export SWAP_DISK="${DISK}"
export SWAP_PART="2"
export SWAP_DEVICE="${SWAP_DISK}-part${SWAP_PART}"

export POOL_DISK="${DISK}"
export POOL_PART="3"
export POOL_DEVICE="${POOL_DISK}-part${POOL_PART}"

# Swapsize autocalculated to be = Mem size
export SWAPSIZE=`free --giga|grep Mem|awk '{OFS="";print "+", $2 ,"G"}'`

# Start installation

apt update
apt -y install debootstrap gdisk zfsutils-linux vim git

zgenhostid -f 0x00bab10c

# Disk preparation
wipefs -a ${DISK}
blkdiscard -f ${DISK}
sgdisk --zap-all ${DISK}
sync; sleep 2

sgdisk -n "${BOOT_PART}:1m:+512m" -t "${BOOT_PART}:EF00" "${BOOT_DISK}"
sgdisk -n "${SWAP_PART}:0:${SWAPSIZE}" -t "${SWAP_PART}:8200" "${SWAP_DISK}" 
sgdisk -n "${POOL_PART}:0:-10m" -t "${POOL_PART}:BF00" "${POOL_DISK}"
sync; sleep 2

# ZFS pool creation
# Create the zpool
echo "${PASSPHRASE}" > /etc/zfs/zroot.key
chmod 000 /etc/zfs/zroot.key

zpool create -f -o ashift=12 \
 -O compression=lz4 \
 -O acltype=posixacl \
 -O xattr=sa \
 -O relatime=on \
 -O encryption=aes-256-gcm \
 -O keylocation=file:///etc/zfs/zroot.key \
 -O keyformat=passphrase \
 -o autotrim=on \
 -o compatibility=openzfs-2.1-linux \
 -m none zroot "$POOL_DEVICE"

sync; sleep 2

# Create initial file systems
zfs create -o mountpoint=none zroot/ROOT
zfs create -o mountpoint=/ -o canmount=noauto zroot/ROOT/${ID}
zfs create -o mountpoint=/home zroot/home

zpool set bootfs=zroot/ROOT/${ID} zroot

# Export, then re-import with a temporary mountpoint of /mnt
zpool export zroot
zpool import -N -R /mnt zroot
zfs load-key -L prompt zroot

zfs mount zroot/ROOT/${ID}
zfs mount zroot/home


# Update device symlinks
udevadm trigger

# Install Ubuntu
debootstrap ${RELEASE} /mnt

# Copy files into the new install
cp /etc/hostid /mnt/etc/hostid
cp /etc/resolv.conf /mnt/etc/
mkdir /mnt/etc/zfs
cp /etc/zfs/zroot.key /mnt/etc/zfs

# Chroot into the new OS
mount -t proc proc /mnt/proc
mount -t sysfs sys /mnt/sys
mount -B /dev /mnt/dev
mount -t devpts pts /mnt/dev/pts

# Set a hostname
echo "$hostname" > /mnt/etc/hostname
echo "127.0.1.1       $hostname" >> /mnt/etc/hosts

# Set root passwd
chroot /mnt /bin/bash -x <<-EOCHROOT
  echo -e "root:$PASSWORD" | chpasswd -c SHA256
EOCHROOT

# Set up APT sources
cat <<EOF > /mnt/etc/apt/sources.list
# Uncomment the deb-src entries if you need source packages

deb http://archive.ubuntu.com/ubuntu/ ${RELEASE} main restricted universe multiverse
# deb-src http://archive.ubuntu.com/ubuntu/ ${RELEASE} main restricted universe multiverse

deb http://archive.ubuntu.com/ubuntu/ ${RELEASE}-updates main restricted universe multiverse
# deb-src http://archive.ubuntu.com/ubuntu/ ${RELEASE}-updates main restricted universe multiverse

deb http://archive.ubuntu.com/ubuntu/ ${RELEASE}-security main restricted universe multiverse
# deb-src http://archive.ubuntu.com/ubuntu/ ${RELEASE}-security main restricted universe multiverse

deb http://archive.ubuntu.com/ubuntu/ ${RELEASE}-backports main restricted universe multiverse
# deb-src http://archive.ubuntu.com/ubuntu/ ${RELEASE}-backports main restricted universe multiverse
EOF

# Update the repository cache and system, install base packages, set up
# console properties
chroot /mnt /bin/bash -x <<-EOCHROOT
  apt update
  apt upgrade -y
  apt install -y --no-install-recommends linux-generic locales keyboard-configuration console-setup
  #dpkg-reconfigure locales tzdata keyboard-configuration console-setup
EOCHROOT

chroot "$mountpoint" /bin/bash -x <<-EOCHROOT
		##4.5 configure basic system
		locale-gen en_US.UTF-8 $locale
		echo 'LANG="$locale"' > /etc/default/locale

		##set timezone
		ln -fs /usr/share/zoneinfo/"$timezone" /etc/localtime
		dpkg-reconfigure tzdata
EOCHROOT

# ZFS Configuration
chroot /mnt /bin/bash -x <<-EOCHROOT
  apt install -y dosfstools zfs-initramfs zfsutils-linux curl vim wget
  systemctl enable zfs.target
  systemctl enable zfs-import-cache
  systemctl enable zfs-mount
  systemctl enable zfs-import.target
  echo "UMASK=0077" > /etc/initramfs-tools/conf.d/umask.conf
  update-initramfs -c -k all
EOCHROOT

# Install and configure ZFSBootMenu
# Set ZFSBootMenu properties on datasets
# Create a vfat filesystem
# Create an fstab entry and mount
chroot /mnt /bin/bash -x <<-EOCHROOT
  zfs set org.zfsbootmenu:commandline="quiet loglevel=4" zroot/ROOT
  zfs set org.zfsbootmenu:keysource="zroot/ROOT/${ID}" zroot
  mkfs.vfat -F32 "$BOOT_DEVICE"
EOCHROOT

cat << EOF >> /etc/fstab
$( blkid | grep "$BOOT_DEVICE" | cut -d ' ' -f 2 ) /boot/efi vfat defaults 0 0
EOF

mkdir -p /mnt/boot/efi

# Install ZBM and configure EFI boot entries
chroot /mnt /bin/bash -x <<-EOCHROOT
  mount /boot/efi
  mkdir -p /boot/efi/EFI/ZBM
  curl -o /boot/efi/EFI/ZBM/VMLINUZ.EFI -L https://get.zfsbootmenu.org/efi
  cp /boot/efi/EFI/ZBM/VMLINUZ.EFI /boot/efi/EFI/ZBM/VMLINUZ-BACKUP.EFI
  mount -t efivarfs efivarfs /sys/firmware/efi/efivars
  apt install -y efibootmgr refind
  efibootmgr -c -d "$BOOT_DISK" -p "$BOOT_PART" \
    -L "ZFSBootMenu (Backup)" \
    -l '\EFI\ZBM\VMLINUZ-BACKUP.EFI'

  efibootmgr -c -d "$BOOT_DISK" -p "$BOOT_PART" \
    -L "ZFSBootMenu" \
    -l '\EFI\ZBM\VMLINUZ.EFI'

  refind-install
  rm /boot/refind_linux.conf
EOCHROOT

cat << EOF >> /boot/efi/EFI/ZBM/refind_linux.conf
menuentry "Ubuntu (ZBM)" {
    loader /EFI/ZBM/VMLINUZ.EFI
    icon /EFI/refind/themes/refind-theme-regular/icons/256-96/os_ubuntu.png
    options "quit loglevel=0 zbm.skip"
}

menuentry "Ubuntu (ZBM Menu)" {
    loader /EFI/ZBM/VMLINUZ.EFI
    icon /EFI/refind/themes/refind-theme-regular/icons/256-96/os_ubuntu.png
    options "quit loglevel=0 zbm.show"
}
EOF

# Setup swap partition
echo swap ${DISK}-part2 /dev/urandom \
      swap,cipher=aes-xts-plain64:sha256,size=512 >> /mnt/etc/crypttab
echo /dev/mapper/swap none swap defaults 0 0 >> /mnt/etc/fstab

chroot /mnt /bin/bash -x <<-EOCHROOT
  cp /usr/share/systemd/tmp.mount /etc/systemd/system/
  systemctl enable tmp.mount
  addgroup --system lpadmin
  addgroup --system lxd
  addgroup --system sambashare

  echo "network:" >/etc/netplan/01-network-manager-all.yaml
  echo "  version: 2" >>/etc/netplan/01-network-manager-all.yaml
  echo "  renderer: NetworkManager" >>/etc/netplan/01-network-manager-all.yaml
EOCHROOT

# Create user
chroot /mnt /bin/bash -x <<-EOCHROOT
  adduser $username
  cp -a /etc/skel/. /home/$username
  chown -R $username:$username /home/$username
  usermod -a -G adm,cdrom,dip,lpadmin,lxd,plugdev,sambashare,sudo $username
  echo "diego ALL=(ALL) NOPASSWD: ALL" >/etc/sudoers.d/${username}
  chown root:root /etc/sudoers.d/${username}
  chmod 400 /etc/sudoers.d/${username}
  echo -e "$username:$PASSWORD" | chpasswd
EOCHROOT

# Install desktop bundle
chroot /mnt /bin/bash -x <<-EOCHROOT
  apt install -y nala
  nala dist-upgrade -y
  nala install -y ubuntu-desktop
EOCHROOT

# Disable log gzipping as we already use compresion at filesystem level
chroom /mnt /bin/bash -x <<-EOCHROOT
  for file in /etc/logrotate.d/* ; do
    if grep -Eq "(^|[^#y])compress" "$file" ; then
        sed -i -r "s/(^|[^#y])(compress)/\1#\2/" "$file"
    fi
EOCHROOT

umount -n -R /mnt
sync; sleep 5
umount -n -R /mnt

zpool export zroot
reboot