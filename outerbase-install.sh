#!/bin/sh

### version 0.1

### usage
#
# sh outerbase-install.sh
#   warns about expecting a drive name, shows output of `gpart show`
#
# sh outerbase-install.sh <drive>
#   shows output of `gpart show <drive>`, awaits confirmation before proceeding

set -e

###
### knobs
###

hostname=vulcan
poolname=zroot

# if set, the same root password will be set for the outer and inner base
# if empty, you will be prompted separately for outer and inner base
rootpw=

# a geli passphrase containing spaces can be entered in quotes: "test 123"
# if empty, you will be prompted for geli the passphrase (a total of 3 times)
gelipassphrase=

# size of encrypted swap partition for inner base
# leave empty or set to 0 to disable swap
swapsize=2G

# size of the outer base UFS partition. rule of thumb:
# 1600M - stock base system
#  800M - custom minimal base
# add space for larger custom kernels or multiple kernels as needed
outersize=1600M

# path to custom package for outer base
# leave empty to use stock base system (/usr/freebsd-dist/base.txz)
outerbasetxz=

if [ -n "$outerbasetxz" ] && [ ! -f "$outerbasetxz" ]; then
  echo "$outerbasetxz does not exist."
  exit
fi

# if set, put "PermitRootLogin yes" in /etc/sshd.conf for outer and inner base
# leave empty for default (SSH root login forbidden)
rootSSH=set

# if set, ensure that inner and outer base have distinct SSH host keys
# this is more secure, but creates somewhat of a hassle on the client side
separateSSHhostkeys=


###
### device selection
###

# called without arguments
[ -z $1 ] && \
  dialog --msgbox \
    "This script expects to be called with a device name." 0 0 && \
  dialog --no-collapse --title "FYI: gpart show -p" --ok-label Exit \
    --msgbox "$(gpart show -p)" 0 0 && \
  exit

# called with argument: use $1 as target device to partition
drive=$1
targetpart=$(gpart show -p $drive) || exit

dialog --no-collapse --yes-label "DESTROY and use this drive" --no-label Abort \
  --title "FYI: gpart show -p $drive" --yesno "$targetpart" 0 0 || exit


###
### partitioning
###

gpart destroy -F $drive
gpart create -s gpt $drive

gpart add   -a 1M -s 10M        -l efi   -t efi          $drive
gpart add   -a 1M -s $outersize -l outer -t freebsd-ufs  $drive
[ -n "$swapsize" ] && [ "$swapsize" != "0" ] && \
  gpart add -a 1M -s $swapsize  -l swap  -t freebsd-swap $drive
gpart add   -a 1M               -l inner -t freebsd-zfs  $drive


###
### encryption
###

if [ -n "$gelipassphrase" ]; then
  echo $gelipassphrase | geli init   -J - /dev/gpt/inner
  echo $gelipassphrase | geli attach -j - /dev/gpt/inner
else
  echo "Enter geli passphrase to initialize inner.eli:"
  geli init /dev/gpt/inner
  echo "Enter geli passphrase again to attach inner.eli:"
  geli attach /dev/gpt/inner
fi

# encrypted swap defined in /etc/fstab needs no initialization


###
### inner zfs
###

zpool create -o ashift=12 -m none -o altroot=/mnt $poolname /dev/gpt/inner.eli

# default layout from the 13.0-RELEASE installer, taken from:
# https://cgit.freebsd.org/
#              src/tree/usr.sbin/bsdinstall/scripts/zfsboot?h=releng/13.0#n141
zfs create -o mountpoint=none $poolname/ROOT
zfs create -o mountpoint=/    $poolname/ROOT/default
zfs create -o mountpoint=/usr -o canmount=off $poolname/usr
zfs create                                    $poolname/usr/home
zfs create -o setuid=off                      $poolname/usr/ports
zfs create                                    $poolname/usr/src
zfs create -o mountpoint=/var -o canmount=off $poolname/var
zfs create -o exec=off -o setuid=off          $poolname/var/audit
zfs create -o exec=off -o setuid=off          $poolname/var/crash
zfs create -o exec=off -o setuid=off          $poolname/var/log
zfs create -o atime=on                        $poolname/var/mail
zfs create -o setuid=off                      $poolname/var/tmp


###
### confirm disk setup
###

if ! dialog --no-collapse --yes-label Install --no-label Abort \
  --yesno "$(gpart show -pl $drive; ls -lt /dev/gpt; echo; zfs list)" 0 0; then
  echo; echo "To start over, run the following commands:"; echo
  echo " # zpool export $poolname"
  echo " # geli detach gpt/inner.eli"; echo
  exit
fi


###
### outer filesystem
###

newfs -m2 /dev/gpt/outer
mkdir /mnt/outer
mount /dev/gpt/outer /mnt/outer


###
### outer base install
###

# use custom outerbase.txz if set
if [ -n "$outerbasetxz" ]; then
  tar -xvpPf $outerbasetxz -C /mnt/outer
else
  tar -xvpPf /usr/freebsd-dist/base.txz -C /mnt/outer
fi


###
### inner base install
###

tar -xvpPf /usr/freebsd-dist/base.txz --exclude='boot/' -C /mnt
ln -s /outer/boot /mnt/boot
chflags -h sunlink /mnt/boot


###
### efi system partition
###

newfs_msdos /dev/gpt/efi
mount -t msdos /dev/gpt/efi /mnt/outer/boot/efi
mkdir -p /mnt/outer/boot/efi/EFI/BOOT
cp /boot/loader.efi /mnt/outer/boot/efi/EFI/BOOT/BOOTX64.EFI
umount /mnt/outer/boot/efi


###
### shared /boot and kernel
###

tar -xvpPf /usr/freebsd-dist/kernel.txz -C /mnt/outer

cat <<EOD >> /mnt/outer/boot/loader.conf
autoboot_delay="4"
vfs.root.mountfrom="ufs:/dev/gpt/outer"
geom_eli_load="YES"
zfs_load="YES"
EOD


###
### common config: system
###

hostname $hostname
chroot /mnt/outer sysrc hostname=$hostname
chroot /mnt sysrc hostname=$hostname

# ensure outer and inner have identical hostid to avoid zpool import confusion
chroot /mnt/outer service hostid onestart
chroot /mnt/outer service hostid_save onestart
cp /mnt/outer/etc/hostid /mnt/etc/

if [ -n "$rootpw" ]; then
  echo $rootpw | chroot /mnt/outer pw mod user root -h 0
  echo $rootpw | chroot /mnt pw mod user root -h 0
else
  echo; echo "Setting root password for outer base:"
  chroot /mnt/outer passwd
  echo; echo "Setting root password for inner base:"
  chroot /mnt passwd
fi

[ -f /mnt/outer/usr/sbin/sendmail ] && \
  chroot /mnt/outer sysrc sendmail_enable=NONE
chroot /mnt sysrc sendmail_enable=NONE


###
### common config: ssh
###

chroot /mnt/outer sysrc sshd_enable=YES
chroot /mnt sysrc sshd_enable=YES

[ -n "$rootSSH" ] && \
 sed -i '' -e 's/^#\(PermitRootLogin\).*/\1 yes/' /mnt/outer/etc/ssh/sshd_config

chroot /mnt/outer service sshd onekeygen

rm -r /mnt/etc/ssh
cp -r /mnt/outer/etc/ssh /mnt/etc/

if [ -n "$separateSSHhostkeys" ]; then
  rm /mnt/etc/ssh/ssh_host_*_key*
  chroot /mnt service sshd onekeygen
fi


###
### outer config
###

# this is to stop the outer base from auto-importing the zpool, as it's
# locked by geli anyway. It's no problem to later import the pool by unlock.sh
chroot /mnt/outer sysrc zfs_enable=NO

cat <<EOD > /mnt/outer/etc/fstab
/dev/gpt/outer /         ufs     rw,noatime 1 1
/dev/gpt/efi   /boot/efi msdosfs rw,noauto  1 1
tmpfs          /var/log  tmpfs   rw,size=100m,noexec          0 0
tmpfs          /tmp      tmpfs   rw,size=500m,mode=777,nosuid 0 0
EOD
# the outer base doesn't get swap, as there should be no need for it

cat <<EOD > /mnt/outer/root/unlock.sh
#!/bin/sh
set -e

geli attach gpt/inner

if [ "\$1" = "-n" ]; then
  zpool import -o altroot=/mnt $poolname
else
  zpool import -N $poolname
fi

BOOTZFS=\$( zpool list -H -o bootfs $poolname )
if [ "\$BOOTZFS" = "-" ]; then
  BOOTZFS="$poolname/ROOT/default"
fi
kenv vfs.root.mountfrom="zfs:\$BOOTZFS"

if [ "\$1" = "-n" ]; then
  echo; echo "$poolname is unlocked and imported with altroot=/mnt."
  echo "To reboot into inner base later, call: reboot -r"; echo
else
  echo; echo "--- reboot -r happening now ---"; echo
  reboot -r
fi
EOD
chmod +x /mnt/outer/root/unlock.sh

dialog --msgbox "Now editing _outer base_ configuration." 0 0
mount -t devfs devfs /mnt/outer/dev
chroot /mnt/outer/ bsdconfig || true


###
### inner config
###

# upon `reboot -r`, the pool is already imported. this ensures `zfs mount -a`
chroot /mnt/ sysrc zfs_enable=YES

cat <<EOD > /mnt/etc/fstab
/dev/gpt/outer    /outer    ufs     rw,noatime 1 1
/dev/gpt/efi      /boot/efi msdosfs rw,noauto  1 1
tmpfs             /tmp      tmpfs   rw,mode=777,nosuid 0 0
EOD

[ -n "$swapsize" ] && [ "$swapsize" != "0" ] && cat <<EOD >> /mnt/etc/fstab
/dev/gpt/swap.eli none      swap    sw 0 0
EOD

dialog --msgbox "Now editing _inner base_ configuration." 0 0
mount -t devfs devfs /mnt/dev
chroot /mnt/ bsdconfig || true


###
### cleanup
###

killall dhclient

if dialog --yes-label "Yes, export" --no-label "No, inspect" \
   --yesno "All done. Unmount all filesystems and export $poolname?" 0 0; then
  umount -f /mnt/outer/dev
  umount -f /mnt/dev
  umount /mnt/outer
  zpool export $poolname  
  geli detach gpt/inner.eli
  exit
fi

echo; echo
echo "--- Before rebooting, do the following: ---"
echo
echo "# umount -f /mnt/outer/dev"
echo "# umount -f /mnt/dev"
echo "# umount /mnt/outer"
echo "# zpool export $poolname"
echo
echo "Otherwise, your first unlock.sh from the outer base will fail to import"
echo "the pool. If that happens, your best option is to force import once:"
echo
echo "# zpool import -Nf $poolname"
echo
echo "... and just reboot."; echo