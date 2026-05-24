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
# 1600M - stock base system (pkgbase minimal)
# 1000M - custom minimal base
# add space for larger custom kernels or multiple kernels as needed
outersize=1600M

# pkgbase package sets to install for outer base
# minimal: always installed (required)
# Leave empty for minimal-only installation
# Add: "base" for full base, "lib32" for 32-bit compat, etc.
outerpkgsets=""

# pkgbase package sets to install for inner base
# minimal: always installed (required)
# Common options: "base", "lib32", "src", "tests"
innerpkgsets="base"

# if set, install debug symbols for selected packages
# This will install -dbg variants of installed package sets
install_debug=""

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
    bsddialog --msgbox \
      "This script expects to be called with a device name." 0 0

    bsddialog --title "FYI: \`geom disk list\`" \
      --yes-label "Show \`gpart show -p\`" --no-label Exit \
      --yesno "$(geom disk list)" 0 0 && \
    bsddialog --title "FYI: \`gpart show -p $drive\`" \
      --ok-label Exit --msgbox "$(gpart show -p)" 0 0

    exit
  fi

  # called with argument: ask to confirm, then partition drive $1
  drive=$1
  targetpart=$(geom disk list $drive; gpart show -p $drive 2>&1 || true )

  bsddialog --title "FYI: \`geom disk list $drive; gpart show -p $drive\`" \
    --yes-label "DESTROY and use $drive" --no-label Abort \
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
  bsddialog --title "FYI: zpool list -v $poolname" \
    --yes-label "Proceed with install" --no-label Abort \
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

INNER_CHROOT=/mnt

if [ -z "$customdrives" ]; then
  zpool create -o ashift=12 -m none -o altroot=$INNER_CHROOT $poolname /dev/gpt/inner.eli
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

  if ! bsddialog --yes-label Install --no-label Abort \
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

OUTER_CHROOT=$INNER_CHROOT/outer
mkdir $OUTER_CHROOT

if [ -z "$customdrives" ]; then
  outerbasedevice=/dev/gpt/outer
fi

newfs -m2 $outerbasedevice
mount $outerbasedevice $OUTER_CHROOT


###
### bootstrap pkg
###

# Bootstrap pkg if not already available
if ! pkg -N > /dev/null 2>&1; then
  echo "Bootstrapping pkg on the host system"
  pkg bootstrap -y
fi


###
### pkgbase installation function
###

# Install FreeBSD base system via pkgbase packages
# Args: $1 = chroot path, $2 = description (e.g., "outer"), $3 = space-separated package sets
install_pkgbase() {
  local chroot_path="$1"
  local desc="$2"; shift 2
  local user_pkgsets="$*"

  echo "Installing $desc base system via pkgbase..."

  local repos_dir=/usr/share/bsdinstall
  local pkg_cmd="pkg --rootdir $chroot_path --repo-conf-dir $repos_dir -o IGNORE_OSVERSION=yes"

  # Copy pkg keys to chroot
  mkdir -p "$chroot_path/usr/share/keys"
  cp -R /usr/share/keys/* "$chroot_path/usr/share/keys/"

  # Update pkg repositories
  $pkg_cmd update

  # Build package list - always install minimal, kernel, and pkg (if available)
  local packages="FreeBSD-set-minimal FreeBSD-kernel-generic"

  # Check if pkg package is available
  if $pkg_cmd rquery -U -r FreeBSD-base %n | grep -q "^pkg$"; then
    packages="$packages pkg"
  fi

  # Add user-specified package sets
  for pkgset in $user_pkgsets; do
    packages="$packages FreeBSD-set-$pkgset"

    # Add debug packages if requested
    if [ -n "$install_debug" ]; then
      if $pkg_cmd rquery -U -r FreeBSD-base %n | grep -q "^FreeBSD-set-$pkgset-dbg$"; then
        packages="$packages FreeBSD-set-$pkgset-dbg"
      fi
    fi
  done

  # Add kernel debug symbols if requested
  if [ -n "$install_debug" ]; then
    packages="$packages FreeBSD-kernel-generic-dbg"
  fi

  # Not part of FreeBSD-set-minimal, but FreeBSD-set-optional
  packages="$packages FreeBSD-ssh FreeBSD-bsdconfig"

  # Fetch packages (with retry logic)
  while ! $pkg_cmd install -U -F -y -r FreeBSD-base $packages; do
    echo "Fetching packages failed. Retry? (y/n)"
    read answer
    if [ "$answer" != "y" ]; then
      exit 1
    fi
  done

  # Install packages
  if ! $pkg_cmd install -U -y -r FreeBSD-base $packages; then
    echo "Package installation failed!"
    exit 1
  fi

  # Enable FreeBSD-base repository for this system
  mkdir -p "$chroot_path/usr/local/etc/pkg/repos"
  echo 'FreeBSD-base: { enabled: yes }' > "$chroot_path/usr/local/etc/pkg/repos/FreeBSD.conf"

  echo "$desc base system installation complete."
}


###
### outer base install
###

install_pkgbase "$OUTER_CHROOT" "outer" $outerpkgsets

# Extract /var but leave it empty for varmfs if requested
if [ -n "$varmfs" ]; then
  # /var should already exist from package installation
  # Just ensure it's empty
  rm -rf $OUTER_CHROOT/var/*
fi


###
### inner base install
###

install_pkgbase "$INNER_CHROOT" "inner" $innerpkgsets


###
### shared /boot and kernel
###

# Create symlink from inner to outer for shared /boot, which contains the kernel
rm -fr $INNER_CHROOT/boot
ln -s /outer/boot $INNER_CHROOT/boot
chflags -h sunlink $INNER_CHROOT/boot

if [ -z "$customdrives" ]; then

  cat <<EOD >> $OUTER_CHROOT/boot/loader.conf
autoboot_delay="4"
vfs.root.mountfrom="ufs:/dev/gpt/outer"
geom_eli_load="YES"
zfs_load="YES"
EOD

else

  cat $bootloaderconf >> $OUTER_CHROOT/boot/loader.conf

fi


###
### common config: system
###

sysrc -f $OUTER_CHROOT/etc/rc.conf hostname=$hostname
sysrc -f $INNER_CHROOT/etc/rc.conf hostname=$hostname

# ensure outer and inner have identical hostid to avoid zpool import confusion
chroot $OUTER_CHROOT service hostid onestart
chroot $OUTER_CHROOT service hostid_save onestart
cp $OUTER_CHROOT/etc/hostid $INNER_CHROOT/etc/

if [ -n "$outerrootpw" ]; then
  echo "$outerrootpw" | chroot $OUTER_CHROOT pw mod user root -h 0
else
  echo
  echo "Setting root password for outer base:"
  chroot $OUTER_CHROOT passwd
fi

if [ -n "$innerrootpw" ]; then
  echo "$innerrootpw" | chroot $INNER_CHROOT pw mod user root -h 0
else
  echo
  echo "Setting root password for inner base:"
  chroot $INNER_CHROOT passwd
fi


###
### common config: ssh
###

sysrc -f $OUTER_CHROOT/etc/rc.conf sshd_enable=YES
sysrc -f $INNER_CHROOT/etc/rc.conf sshd_enable=YES

[ -n "$rootSSH" ] && \
 sed -i '' -e 's/^#\(PermitRootLogin\).*/\1 yes/' $OUTER_CHROOT/etc/ssh/sshd_config

chroot $OUTER_CHROOT service sshd onekeygen

rm -r $INNER_CHROOT/etc/ssh
cp -r $OUTER_CHROOT/etc/ssh $INNER_CHROOT/etc/

if [ -n "$separateSSHhostkeys" ]; then
  rm $INNER_CHROOT/etc/ssh/ssh_host_*_key*
  chroot $INNER_CHROOT service sshd onekeygen
fi


###
### outer config
###

# this is to stop the outer base from auto-importing the zpool, as it's
# locked by geli anyway. It's no problem to later import the pool by unlock.sh
sysrc -f $OUTER_CHROOT/etc/rc.conf zfs_enable=NO

sysrc -f $OUTER_CHROOT/etc/rc.conf tmpmfs=YES
sysrc -f $OUTER_CHROOT/etc/rc.conf tmpsize=500m
if [ -n "$varmfs" ]; then
  sysrc -f $OUTER_CHROOT/etc/rc.conf varmfs=YES
  sysrc -f $OUTER_CHROOT/etc/rc.conf varsize=500m
fi

if [ -z "$customdrives" ]; then

  if [ -z "$gptboot" ]; then
    cat <<EOD >> $OUTER_CHROOT/etc/fstab
/dev/gpt/efi   /boot/efi msdosfs rw,noauto  1 1
EOD
  fi
  cat <<EOD >> $OUTER_CHROOT/etc/fstab
/dev/gpt/outer /         ufs     rw,noatime 1 1
EOD
# the outer base doesn't get swap, as there should be no need for it

else

  cat $customfstabouter >> $OUTER_CHROOT/etc/fstab

fi

cat <<EOD > $OUTER_CHROOT/root/unlock.sh
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
chmod +x $OUTER_CHROOT/root/unlock.sh

bsddialog --msgbox "Now editing _outer base_ configuration." 0 0
mount -t devfs devfs $OUTER_CHROOT/dev
chroot $OUTER_CHROOT/ bsdconfig || true


###
### inner config
###

# upon `reboot -r`, the pool is already imported. this ensures `zfs mount -a`
chroot $INNER_CHROOT/ sysrc zfs_enable=YES

if [ -z "$customdrives" ]; then

  if [ -z "$gptboot" ]; then
    cat <<EOD >> $INNER_CHROOT/etc/fstab
/dev/gpt/efi      /boot/efi msdosfs rw,noauto  1 1
EOD
  fi
  cat <<EOD >> $INNER_CHROOT/etc/fstab
/dev/gpt/outer    /outer    ufs     rw,noatime 1 1
tmpfs             /tmp      tmpfs   rw,mode=777,nosuid 0 0
EOD

  [ -n "$swapsize" ] && [ "$swapsize" != "0" ] && cat <<EOD >> $INNER_CHROOT/etc/fstab
/dev/gpt/swap.eli none      swap    sw 0 0
EOD
else

  cat $customfstabinner >> $INNER_CHROOT/etc/fstab

fi

bsddialog --msgbox "Now editing _inner base_ configuration." 0 0
mount -t devfs devfs $INNER_CHROOT/dev
chroot $INNER_CHROOT/ bsdconfig || true


###
### cleanup
###

killall dhclient || true

if bsddialog --yes-label "Yes, export" --no-label "No, inspect" \
   --yesno "All done. Unmount all filesystems and export $poolname?" 0 0; then
  umount -f $OUTER_CHROOT/dev
  umount -f $INNER_CHROOT/dev
  umount $OUTER_CHROOT
  zpool export $poolname
  if [ -z "$customdrives" ]; then
    geli detach gpt/inner.eli
  else
    echo; echo "!!! Don't forget to tweak $OUTER_CHROOT/root/unlock.sh !!!"; echo
  fi
  exit
fi

echo; echo
echo "--- Before rebooting, do the following: ---"
echo
echo "# umount -f $OUTER_CHROOT/dev"
echo "# umount -f $INNER_CHROOT/dev"
echo "# umount $OUTER_CHROOT"
echo "# zpool export $poolname"
echo
echo "Otherwise, your first unlock.sh from the outer base will fail to import"
echo "the pool. If that happens, your best option is to force import once:"
echo
echo "# zpool import -Nf $poolname"
echo
echo "... and just reboot."; echo

if [ -n "$customdrives" ]; then
  echo; echo "!!! Don't forget to tweak $OUTER_CHROOT/root/unlock.sh !!!"; echo
fi
