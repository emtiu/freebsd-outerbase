#!/bin/sh

### version 0.3

### usage
#
# sh outerbase-install.sh
#   warns about expecting a drive name, shows output of `gpart show`
#
# sh outerbase-install.sh <drive>
#   shows output of `gpart show <drive>`, awaits confirmation before proceeding

set -e

###
### install options
###

# if set, configure boot to BIOS+GPT, otherwise assumes UEFI+GPT. This is for
# older systems which do not support UEFI. From gptboot(8): "gptboot is used on
# BIOS-based computers to boot from a UFS partition on a GPT-partitioned disk".
gptboot=

# if set, skip partitioning entirely and rely on drives already configured
# to install the inner and outer base into. This allows for custom encryption,
# more complex zpool geometries, and even a GEOM-mirrored (gmirror) outer base.
customdrives=
# for this to work, several conditions must be met before running this script:
#   1) bootcode already installed
#   2) a zpool named as in $poolname already imported with -o altroot=/mnt
#   3) a device name for the outer base to be mounted at /mnt/outer
outerbasedevice=
#   4) fstabs for outer and inner base at the locations specified here:
customfstabouter=
customfstabinner=
#   5) boot/loader.conf at the locations specified here:
bootloaderconf=


###
### system properties
###

hostname=vulcan
poolname=zroot

# root password for the outer base. If empty, you will be prompted for the password
outerrootpw=
# root password for the inner base. If empty, you will be prompted for the password
innerrootpw=

# a geli passphrase containing spaces can be entered in quotes: "test 123"
# if empty, you will be prompted for geli the passphrase (a total of 3 times)
gelipassphrase=

# size of encrypted swap partition for inner base
# leave empty or set to 0 to disable swap
swapsize=2G

# size of the outer base UFS partition. recommendation:
# 1600M - stock base system
# 1000M - custom minimal base
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

# use a tmpfs for /var in outer base (destroyed at reboot) to save space and
# minimize user data. NOTE: if set, pkg cannot be used in the outer base.
# leave empty for default (permanent /var file system)
varmfs=

###
### device selection
###

if [ -z "$customdrives" ]; then

  # called without argument: present drive info and exit
  if [ -z $1 ]; then
    dialog --msgbox \
      "This script expects to be called with a device name." 0 0

    dialog --no-collapse --title "FYI: \`geom disk list\`" \
      --yes-label "Show \`gpart show -p\`" --no-label Exit \
      --yesno "$(geom disk list)" 0 0 && \
    dialog --no-collapse --title "FYI: \`gpart show -p $drive\`" \
      --ok-label Exit --msgbox "$(gpart show -p)" 0 0

    exit
  fi

  # called with argument: ask to confirm, then partition drive $1
  drive=$1
  targetpart=$(geom disk list $drive; gpart show -p $drive 2>&1 || true )

  dialog --title "FYI: \`geom disk list $drive; gpart show -p $drive\`" \
    --no-collapse --yes-label "DESTROY and use $drive" --no-label Abort \
    --yesno "$targetpart" 0 0 || exit

else

  # customdrives: verify conditions as explained above
  echo "Verifying devices and paths. If the script fails here, check them."
  zpool list -H $poolname        # fails if pool is not imported
  [ -e "$outerbasedevice" ]      # fails if outer base device does not exist
  [ -f "$customfstabouter" ]     # fails if no prepared fstab found
  [ -f "$customfstabinner" ]     # fails if no prepared fstab found
  [ -f "$bootloaderconf" ]       # fails if no prepared loader.conf found

  # if tests passed: verify to continue
  dialog --title "FYI: zpool list -v $poolname" \
    --no-collapse --yes-label "Proceed with install" --no-label Abort \
    --yesno "$(zpool list -v $poolname)" 0 0 || exit

fi


###
### partitioning
###

if [ -z "$customdrives" ]; then

  gpart create -s gpt $drive || \
    { gpart destroy -F $drive && gpart create -s gpt $drive; }

  if [ -n "$gptboot" ]; then
    gpart add -a 1M -s 512k     -l gptboot -t freebsd-boot $drive
  else
    gpart add -a 1M -s 10M        -l efi   -t efi          $drive
  fi
  gpart add   -a 1M -s $outersize -l outer -t freebsd-ufs  $drive
  [ -n "$swapsize" ] && [ "$swapsize" != "0" ] && \
    gpart add -a 1M -s $swapsize  -l swap  -t freebsd-swap $drive
  gpart add   -a 1M               -l inner -t freebsd-zfs  $drive

fi


###
### boot code
###

if [ -z "$customdrives" ]; then

  if [ -n "$gptboot" ]; then
    gpart bootcode -b /boot/pmbr -p /boot/gptboot -i 1 $drive
    gpart set -a bootme -i 2 $drive
  else
    newfs_msdos /dev/gpt/efi
    mount -t msdos /dev/gpt/efi /mnt/
    mkdir -p /mnt/EFI/BOOT
    cp /boot/loader.efi /mnt/EFI/BOOT/BOOTX64.EFI
    efibootmgr -a -c -l /mnt/EFI/BOOT/BOOTX64.EFI -L FreeBSD
    umount /mnt/
  fi

fi


###
### encryption
###

if [ -z "$customdrives" ]; then

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

fi


###
### inner zfs
###

if [ -z "$customdrives" ]; then
  zpool create -o ashift=12 -m none -o altroot=/mnt $poolname /dev/gpt/inner.eli
fi

# default layout from the 14.1-RELEASE installer, taken from:
# https://cgit.freebsd.org/
#              src/tree/usr.sbin/bsdinstall/scripts/zfsboot?h=releng/14.1#n145
zfs create -o mountpoint=none $poolname/ROOT
zfs create -o mountpoint=/    $poolname/ROOT/default
zfs create -o mountpoint=/home                $poolname/home
zfs create -o mountpoint=/usr -o canmount=off $poolname/usr
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

if [ -z "$customdrives" ]; then

  if ! dialog --no-collapse --yes-label Install --no-label Abort \
    --yesno "$(gpart show -pl $drive; ls -lt /dev/gpt; echo; zfs list)" 0 0; then
    echo; echo "To start over, run the following commands:"; echo
    echo " # zpool export $poolname"
    echo " # geli detach gpt/inner.eli"; echo
    exit
  fi

fi


###
### outer filesystem
###

mkdir /mnt/outer

if [ -z "$customdrives" ]; then
  outerbasedevice=/dev/gpt/outer
fi

newfs -m2 $outerbasedevice
mount $outerbasedevice /mnt/outer


###
### outer base install
###

# use custom outerbase.txz if set
if [ -z "$outerbasetxz" ]; then
  outerbasetxz=/usr/freebsd-dist/base.txz
fi

# extract /var but leave it empty for varmfs
if [ -n "$varmfs" ]; then
  tarexcl="--exclude './var/?*'"
fi
tar -xvpPf $outerbasetxz $tarexcl -C /mnt/outer


###
### inner base install
###

tar -xvpPf /usr/freebsd-dist/base.txz --exclude='boot/' -C /mnt
ln -s /outer/boot /mnt/boot
chflags -h sunlink /mnt/boot


###
### shared /boot and kernel
###

tar -xvpPf /usr/freebsd-dist/kernel.txz -C /mnt/outer

if [ -z "$customdrives" ]; then

  cat <<EOD >> /mnt/outer/boot/loader.conf
autoboot_delay="4"
vfs.root.mountfrom="ufs:/dev/gpt/outer"
geom_eli_load="YES"
zfs_load="YES"
EOD

else

  cat $bootloaderconf >> /mnt/outer/boot/loader.conf

fi


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

if [ -n "$outerrootpw" ]; then
  echo "$outerrootpw" | chroot /mnt/outer pw mod user root -h 0
else
  echo
  echo "Setting root password for outer base:"
  chroot /mnt/outer passwd
fi

if [ -n "$innerrootpw" ]; then
  echo "$innerrootpw" | chroot /mnt pw mod user root -h 0
else
  echo
  echo "Setting root password for inner base:"
  chroot /mnt passwd
fi


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

chroot /mnt/outer sysrc tmpmfs=YES
chroot /mnt/outer sysrc tmpsize=500m
if [ -n "$varmfs" ]; then
  chroot /mnt/outer sysrc varmfs=YES
  chroot /mnt/outer sysrc varsize=500m
fi

if [ -z "$customdrives" ]; then

  if [ -z "$gptboot" ]; then
    cat <<EOD >> /mnt/outer/etc/fstab
/dev/gpt/efi   /boot/efi msdosfs rw,noauto  1 1
EOD
  fi
  cat <<EOD >> /mnt/outer/etc/fstab
/dev/gpt/outer /         ufs     rw,noatime 1 1
EOD
# the outer base doesn't get swap, as there should be no need for it

else

  cat $customfstabouter >> /mnt/outer/etc/fstab

fi

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
  echo "To use the inner base, reboot and unlock again."; echo
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

if [ -z "$customdrives" ]; then

  if [ -z "$gptboot" ]; then
    cat <<EOD >> /mnt/etc/fstab
/dev/gpt/efi      /boot/efi msdosfs rw,noauto  1 1
EOD
  fi
  cat <<EOD >> /mnt/etc/fstab
/dev/gpt/outer    /outer    ufs     rw,noatime 1 1
tmpfs             /tmp      tmpfs   rw,mode=777,nosuid 0 0
EOD

  [ -n "$swapsize" ] && [ "$swapsize" != "0" ] && cat <<EOD >> /mnt/etc/fstab
/dev/gpt/swap.eli none      swap    sw 0 0
EOD
else

  cat $customfstabinner >> /mnt/etc/fstab

fi

dialog --msgbox "Now editing _inner base_ configuration." 0 0
mount -t devfs devfs /mnt/dev
chroot /mnt/ bsdconfig || true


###
### cleanup
###

killall dhclient || true

if dialog --yes-label "Yes, export" --no-label "No, inspect" \
   --yesno "All done. Unmount all filesystems and export $poolname?" 0 0; then
  umount -f /mnt/outer/dev
  umount -f /mnt/dev
  umount /mnt/outer
  zpool export $poolname
  if [ -z "$customdrives" ]; then
    geli detach gpt/inner.eli
  else
    echo; echo "!!! Don't forget to tweak /mnt/outer/root/unlock.sh !!!"; echo
  fi
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

if [ -n "$customdrives" ]; then
  echo; echo "!!! Don't forget to tweak /mnt/outer/root/unlock.sh !!!"; echo
fi
