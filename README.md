# freebsd-outerbase
install script for a remote-unlockable FreeBSD system with geli-encrypted root-on-zfs

## the problem
If a server resides on encrypted media, it's difficult to unlock it remotely after a reboot. When a fully encrypted system boots, it usually sits and waits for a passphrase to be entered long before the network is ready to allow a remote connection.

Common solutions include virtualization, the serial console ([traditional](https://docs.freebsd.org/en_US.ISO8859-1/books/handbook/serialconsole-setup.html) or through a [DIY server](https://www.jpaul.me/2019/01/how-to-build-a-raspberry-pi-serial-console-server-with-ser2net/)), [IPMI](https://en.wikipedia.org/wiki/Intelligent_Platform_Management_Interface) and friends, or IP-KVM hardware (expensive [traditional](https://www.kvm-switches-online.com/vnc-kvm-switch.html) or [low-cost](https://pikvm.org/) [DIY](https://mtlynch.io/tinypilot/)).

## outer base solution
This solution builds upon two [previous](https://github.com/Sec42/freebsd-remote-crypto/) [implementations](https://phryk.net/article/howto-freebsd-remote-bootable-crypto-setup/) of the following idea: an unencrypted barebones system (the **outer base**) boots and accepts incoming SSH connections. Over SSH, the encrypted system can be unlocked. Then, FreeBSD's `reboot -r` command is used to reboot (more precisely: re-root the kernel) into the unlocked system (the **inner base**):


                                                                 .---------------------------.
                                                                 |    gpt/inner: GELI        |
                                                                 |  .----------------------. |
                               .----------------.  3) unlock     |  | gpt/inner.eli: zroot | |
                               | gpt/outer: ufs |--------------> |  |                      | |
    .--------------.  1) boot  |                |-------------------->    "inner base"     | |
    | gpt/efi: ESP |---------->|  "outer base"  |  4) reboot -r  |  ·----------------------· |
    ·--------------·           ·----------------·                ·---------------------------·
                                         Λ
                                         |
                                  2) ssh ┘

## highlights
* comfortable unlock/reboot script with basic Boot Environments support
* optional encrypted swap
* optional use of a custom-built base system for the outer base (example `src.conf` for a minimal outer base system included)
* minimal requirements:
  * an amd64 system (UEFI or BIOS boot supported)
  * a bootable stock FreeBSD installer (e.g. DVD or memstick)
  * this script
* install script provides hints and checks to help select the right target device
* tested on bare metal and in VirtualBox with FreeBSD from 13.0-RELEASE to 14.1-RELEASE
### security and privacy considerations
The outer base is a stock FreeBSD base install that holds no user data (with the likely exception of a public SSH key for login). However, the kernel must be shared between the outer and inner base. This means that the kernel resides on the unencrypted UFS partition with the outer base system.

Therefore, this solution *does not protect* against undetected hardware tampering (because the unencrypted bootloader and/or kernel could be manipulated before booting) or exploitation of the running system (because inner base and user data are unlocked when the system is running).

It *does* provide encryption at rest, so all user data and the inner base system (except `/boot`) should be locked and protected:
* when the system is powered down,
* after a reboot (before unlocking),
* on the physical drives when removed.

For the question of SSH host keys, see **variables in the install script** below.

## update history
* **2024-08**: version 0.3, now support arbitrary zpools and outerbase block devices (through `customdrives=`)
* **2024-08**: version 0.2, now supports BIOS boot, thanks @foudfou
* **2023-11**: first documented update procedure for self-compiled custom outer base
* **2021-04**: version 0.1, initial release

## quick start
1. Boot a stock FreeBSD installer image on the target machine (i.e. option `1. Boot Installer [Enter]`) and enter the shell.
2. Transfer `outerbase-installer.sh` from this repo to `/tmp/` (by removable media, http, `nc`, …).
3. Run `outerbase-installer.sh` with the target drive name (without `/dev/`) as the only argument.

       sh /tmp/outerbase-installer.sh ada0

**That drive will have its partition table erased by `gpart destroy -F` in the process.**

## a warning on deleting used drives

The metadata of old zpools, GEOM mirrors, geli-encrypted partitions etc. can remain on a drive and cause confusion even after the partition table was destroyed by `gpart destroy -F`.

In one observed case, metadata from a former zpool remained on a drive after it had received a new freebsd-outerbase installation. Both the old zombie zpool and the newly installed one had the name `zroot`, causing the automatic import to fail after unlocking the geli partition containing the new zpool. Using [`zpool-labelclear(8)`](https://man.freebsd.org/cgi/man.cgi?query=zpool-labelclear&sourceid=opensearch) to fry the _old_ zpool also destroyed the geli metadata for the container of the _current_ zpool, necessitating a reinstall. _sad_trombone.wav_

In another case, a zombie Windows Recovery EFI program booted from a drive that had just received a new freebsd-outerbase installation.

To avoid any such mishaps, it's best to zero out the drive with `dd if=/dev/zero` before installing, which you can expect to take between 5 and 15 minutes for a 256GB SSD.

## detailed description
### installing
`outerbase-installer.sh` expects to be run from the shell of a stock FreeBSD installer image such as `FreeBSD-13.2-RELEASE-amd64-memstick.img`. When run without arguments, it just shows the output of `gpart show` to help in selecting the right drive and exits.

To run the installation, execute `outerbase-installer.sh` with the name of the target drive (without "`/dev/`") as the only argument. For example, to use /dev/ada0 for the installation—**which will be erased by `gpart destroy -F` in the process!**—run:

    sh outerbase-installer.sh ada0

**In setting up the system for booting, the script expects:**
* an amd64 machine with UEFI or BIOS boot
* no other operating systems
* to create the machine's only bootable partition on the target drive

The script then proceeds to:
1. create partitions, set up encryption, create the zpool,
2. create file systems and zfs datsets,
2. install the outer base, inner base and boot partition,
3. configure the outer and inner base (see below),
4. open a `chroot`'ed `bsdconfig` for both outer and inner base.

When all is done without errors, the system can be rebooted (with the installer medium removed) and should boot into the outer base.

#### install script variables: install options
At the top of the install script, you'll find options for different ways of installation:

**`gptboot`** can be empty or contain a string:

* If empty, the system will be set up for UEFI boot, with FreeBSD's default `loader.efi` installed as `BOOTX64.EFI`.
* If set to a string, the system will be set up for BIOS/MBR boot, with a Master Boot Record and a `freebsd-boot` partition written to the target drive.

**`customdrives`** and its associated options are an advanced option to support more customized installations. The idea is to install an outer and inner base, but in a **_“bring your own zpool”_** kind of way: The install script skips all partitioning and encryption setup, and just installs into an existing outer base device and zpool.

* [This feature is documented in detail in customdrives.md.](customdrives.md)

#### install script variables: system properties

Below the install options, you can customize the system to be installed.

**`hostname`** and **`poolname`** are self-explanatory.

**`rootpw`** can be empty or contain a string:

* If empty, `passwd` will prompt for the root password for outer and inner base separately (twice for confirmation each time).
* If set to a string, it will be used as the root password for both outer and inner base identically.

**`gelipassphrase`** can be empty or contain a string:

* If empty, `geli` will ask for the passphrase a total of three times (twice for `geli init` and once for `geli attach`).
* If set to a string, it will be used as the passphrase for the encryption of the inner base partition. For a passphrase that contains spaces, the argument should be enclosed in quotes: `gelipassphrase="test 123"`

**`swapsize`** sets the size of the swap partition. Its value is passed to `gpart create -s`. If empty or set to `0`, no swap partition is created, and no swap entry is placed in the inner base's `/etc/fstab`.

**`outersize`** sets the size of the outer base UFS partition. Its value is passed to `gpart create -s`. The default is `1600M`. See **custom minimal outer base** below for details.

**`outerbasetxz`** is the path to the custom base.txz package to use for the outer base. It's empty by default, which means a stock base system is installed as the outer base. The script exits immediately if this path does not exist. See **custom minimal outer base** below for details.

**`rootSSH`** can be empty or set to any value:

* If empty, the default `/etc/ssh/sshd_config` is not changed. `PermitRootLogin` remains set to `no`, which is the default.
* If set to any value, `PermitRootLogin` is set to `yes` in `/etc/ssh/sshd_config` for both the outer and inner base.

**`separateSSHhostkeys`** can be empty or set to any value:

* If empty, *outer base and inner base share identical SSH host keys*. This could be a security concern, because the private SSH host keys are stored unencrypted on the outer base UFS partition. However, it prevents connecting clients from complaining about changed host keys after rebooting into the inner base.
* If set to any value, *the inner base uses its own separate set of SSH host keys*. This is somewhat more secure, but clients will need some serious convincing to connect to both outer and inner base, as changing host keys on the same host are a red flag.
### booting and unlocking
The installer places `/root/unlock.sh` in the outer base to assist in unlocking and rebooting into the inner base.

It uses `reboot -r`, which does a "soft reboot" or "re-root", as explained in the `reboot(8)` manpage of FreeBSD 13.2:


     -r   The system kills all processes, unmounts all filesystems, mounts
          the new root filesystem, and begins the usual startup sequence.
          After changing vfs.root.mountfrom with kenv(1), reboot -r can be
          used to change the root filesystem while preserving kernel state.
          […]

When called without arguments, `/root/unlock.sh`:

* prompts for the geli passphrase to unlock `gpt/inner.eli`,
* imports the zpool without mounting any datsets (by using `zpool import -N`),
* sets the `vfs.root.mountfrom` kernel variable (see **basic Boot Environments support** below),
* calls `reboot -r` to reboot the system into the unlocked inner base.

When called with `/root/unlock.sh -n` (where `-n` means "no reboot"):

* the zpool is imported with `-o altroot=/mnt`,
* the final `reboot -r` is skipped.

The inner base can then be inspected or manipulated at `/mnt`. At any later time, a manually issued `reboot -r` should still reboot into the inner base.

#### basic Boot Environments support
There is some support for Boot Environments (BE) in the inner base system. They can be created and managed normally with `bectl(8)` or `beadm(1)`.

When a BE is activated, the name of the corresponding zfs datset is set in the zpool's `bootfs` property. When a regular bootloader boots from the pool, it it looks for the system in that dataset and mounts it at `/`.

When `/root/unlock.sh` has imported the zpool that contains the inner base, it also reads the zpool's `bootfs` property and sets `vfs.root.mountfrom` accordingly. When `reboot -r` is issued, the system reboots with that dataset as the new `/`, much the same as a normal boot.

The main difference with this setup is that `/boot` is not part of the inner base system, since it must reside on the outer base UFS partition. Therefore, `/boot` is not covered by BE protection when doing upgrades for example.

Otherwise, BEs should work as expected, but haven't been exhaustively tested.

### characteristics of the installed systems
These are the unique/surprising/nonstandard properties of the systems installed by this install script. For tunable options, see **variables in the install script** above. For a description of the booting process, see **installing** and **booting and unlocking** above.

The **target drive** it set up as follows (using a 75GB disk at `/dev/ada0` as example):

         ada0     (75G) type: GPT

         ada0p1   (10M) type: efi           label: efi
         ada0p2    (2G) type: freebsd-ufs   label: outer
         ada0p3    (4G) type: freebsd-swap  label: swap
         ada0p4   (69G) type: freebsd-zfs   label: inner

The `inner` partition takes up all available space after the others are set up. The install script aligns partitions on 1MB boundaries.

If swap is configured, it is used by the inner base only, and encrypted.

The zpool containing the inner base consists of a single vdev without redundancy, created atop the `gpt/inner.eli` geom with `-o ashift=12`. The layout of the datasets is an exact replication of the default in FreeBSD 13.2-RELEASE.

The **boot loader** gets the following settings in `/boot/loader.conf`:

    autoboot_delay="4"
    vfs.root.mountfrom="ufs:/dev/gpt/outer"
    geom_eli_load="YES"
    zfs_load="YES"

The **outer base** is a stock FreeBSD base system (except when using a **custom minimal outer base** as described below) on a single UFS root partition. For this partition, the free-space reserve as determined by `newfs -m` is set to just 2% (down from the default of 8%).

The script to unlock the inner base and reboot into it is placed at `/root/unlock.sh` (see **booting and unlocking** above).

This is `/etc/fstab` for the outer base in a UEFI install:

    /dev/gpt/outer /         ufs     rw,noatime 1 1
    /dev/gpt/efi   /boot/efi msdosfs rw,noauto  1 1

In addition to these fstab entries, the system uses the `tmpmfs` and `varmfs` options in `/etc/rc.conf` to set up non-persistent memory-filesystems (of 500m each) for `/tmp` and `/var` for the outer base, with the rationale that the outer base won't really ever need any files placed there.

The install script sets `zfs_enable=NO` for the outer base. This way, no auto-import of the zpool is attempted at boot, which would fail anyway because `gpt/inner.eli` is locked.

Both **outer base and inner base** share the same host id. This avoids complaints when importing the zpool. The install script also sets `sendmail_enable=NONE` for both outer and inner outer base.

The install script also creates SSH host keys (either identical or separate for inner and outer base, see **variables in the install script** above) and sets `sshd_enable=YES` for both outer and inner base. Optionally, `PermitRootLogin` is set to `yes` in `/etc/ssh/sshd_config`.

The **inner base** has `zfs_enable=YES` set to ensure `zfs mount -a` is run on boot. This is `/etc/fstab` for the inner base in a UEFI install:

    /dev/gpt/outer    /outer    ufs     rw,noatime 1 1
    /dev/gpt/efi      /boot/efi msdosfs rw,noauto  1 1
    tmpfs             /tmp      tmpfs   rw,mode=777,nosuid 0 0
    /dev/gpt/swap.eli none      swap    sw 0 0

Crucially, the outer base UFS partition is mounted at `/outer`. In the inner base, `/boot` is a protected symlink to `/outer/boot`, because that is what the system actually uses to boot the outer base.

Note that the mountpoint for the ESP is `/boot/efi`, even though `/boot` itself is a symlink. This is preferred over `/outer/boot/efi`, because `/boot/efi` is the more canonical mountpoint, and it is the same for both the outer and inner base, hopefully avoiding confusion and mistakes.

### custom minimal outer base
Compiling your own FreeBSD base system for the outer base allows you to make it smaller and simpler, in accordance with its role as a 'login-and-unlock-only system'. A `src.conf` for such a minimal outer system is part of this repository. The resulting sizes are as follows:

&nbsp;| base.txz | installed | with kernel | partition
:---:|---:|---:|---:|---:
`src.conf` 14.1|63M|322M|516M|1000M
stock 14.1|199M|973M|1166M|1600M

The recommended partition size takes into account that upgrades require some free space, including for two kernels to coexist.

#### compiling the custom minimal outer base
With the FreeBSD source tree in place at `/usr/src`, and with the `src.conf` from this repository in a place like `/tmp/outerbase-src.conf`, run the following commands:

    make -C /usr/src/ SRCCONF=/tmp/outerbase-src.conf -j7 buildworld
    make -C /usr/src/release SRCCONF=/tmp/outerbase-src.conf base.txz

As the configuration is very minimal (mainly by avoiding the building of llvm, excluding any debug information and not building a custom kernel), the system builds rather quickly. During testing, it completed in around 10 minutes on an i7 with 4x&nbsp;3.6GHz and 16G of RAM.

The resulting `base.txz` is created (in the case of the amd64 arch) at `/usr/obj/usr/src/amd64.amd64/release/base.txz`. To avoid confusion, it's best to rename it to `outerbase.txz` for use with `outerbase-installer.sh`.

#### installing with custom minimal outer base
In `outerbase-installer.sh`, set the `outerbasetxz` variable to the location of your `outerbase.txz`. It will then be used for installing the outer base. (The inner base will always use the stock `/usr/freebsd-dist/base.txz` instead.) The install script exits if `outerbasetxz` is set to a path that does not exist.

Your `outerbase.txz` can be in any type of readable location:

##### 1. mounted
The location of `outerbase.txz` can be a (read-only) mount, such as an NFS share or some removable media.

##### 2. network file transfer
`outerbase.txz` can also be transferred to the installer's file system over the network, for example by downloading it over http, or by using `nc`.

However, the writable `/tmp` partition of the `memstick.img` installer is limited to 20MB in size, which is probably too small for `outerbase.txz`. As a workaround, another tmpfs with unrestricted size can be mounted under it:

    mkdir /tmp/large
    mount -t tmpfs tmpfs /tmp/large

##### 3. on the installer image
It's particularly convenient to put `outerbase.txz` on the bootable installer medium itself. For use with `FreeBSD-13.2-RELEASE-amd64-memstick.img`, a USB stick or SD card of 2GB or more is appropriate. After writing the image to a 2GB medium at `/dev/da0`, its partition layout as shown by `gpart show da0` should look like this:

    =>      1  3842047  da0  MBR  (1.8G)
            1    66584    1  efi  (33M)
        66585  2064080    2  freebsd  [active]  (1.0G)
      2130665  1711383       - free -  (836M)

In order to fit `outerbase.txz`, the main partition needs to be grown. Because the installer image is MBR-partitioned, an extra step is needed to grow the partition inside its BSD slice before growing the file system. By not specifying a size, first the slice, then the partition and finally the file system is grown to use all available space:

    gpart resize -i2 da0
    gpart resize -i1 da0s2
    growfs /dev/da0s2a

Then, the file system can be mounted for writing and copying `outerbase.txz` onto it:

    mount /dev/da0s2a /mnt/
    cp outerbase.txz /mnt/usr/freebsd-dist/

While you're at it, you can also copy along `outerbase-installer.sh`. Make sure to set

    outerbasetxz=/usr/freebsd-dist/outerbase.txz

in `outerbase-installer.sh` so it will find your `outerbase.txz`.

Note that the installer mounts its main partition read-only. If you copy `outerbase-installer.sh` to the installer image, but then you need to edit it before running: copy it to `/tmp`, edit and run the copy.

### Update procedure
#### stock outer base
When using a stock system as the outer base, the update procedure is as easy as calling `freebsd-update` for the outer base and inner base resepctively. While booted into the inner base, run:

    # freebsd-update -b /outer fetch
    # freebsd-update -b /outer install

#### custom minimal outer base: building on the target machine
A custom minimal outer base needs to be re-built with every update (e.g. from `13.2-RELEASE-p4` to `-p5`). The following steps describe the procedure for building and installing on the same machine. Further down, there's also a description on how to update a non-build machine.

##### step 1: sources

First your should have the sources on hand. Download them like so:

`git clone --branch releng/13.2 https://git.FreeBSD.org/src.git /usr/src`

... or simply `git pull` in `/usr/src`, if it is already populated. You can check for the correct version you're trying to update to by running:

`grep -e ^REVISION -e ^BRANCH /usr/src/sys/conf/newvers.sh`

##### step 2: building

Then, build the system. You need to provide `make` with the `src.conf` that corresponds to your custom minimal outer base. You can specify its location like this:

`make SRCCONF=/root/outerbase-src.conf buildworld`

... or simply run `make buildworld` if you have the correct file in place at `/etc/src.conf` (which is assumed for the follwing commands).

##### step 3: updating `/etc`

Normally, `etcupdate` maintains a persistent database in `/var/db/etcupdate` to save execution time on subsequent runs. Here, this database is only stored temporarily in the non-persisent `/tmp/` of the inner base, in order to minimize clutter on the outer base partition and avoid any confusion between the inner and outer base's etcupdate database.

From `/usr/src`, run:

    # etcupdate extract -d /tmp/etcupdate -D /outer/
    # etcupdate -p -d /tmp/etcupdate -D /outer

##### step 4: installing

From `/usr/src`, run:

`# make DESTDIR=/outer installworld`

Then complete the `etcupdate` operation:

`# etcupdate -d /tmp/etcupdate -D /outer`

You may now want to clean the installation of unneeded files and directories. Specifically, installing an update for the custom minimal outer base may leave behind a number of empty directories associated with unused system components. To find out which those are, run from `/usr/src`:

`# make DESTDIR=/outer check-old`

If the deletion list presented by the previous command makes sense, you may run the cleanup:

`# make DESTDIR=/outer BATCH_DELETE_OLD_FILES=yes delete-old delete-old-libs`

#### custom minimal outer base: building on a remote machine

If you want to update a custom minimal outer base on a machine that cannot (or should not) build the system itself, you may use another FreeBSD machine for building, mount the source and build directories, and install it as normal. It's pretty neat, and it's been tested to work with the build machine offering its `/usr/src` and `/usr/obj` for NFSv4 mounts.

For this procedure, you're going to need the correct `src.conf` in place on **both the build machine and the target machine**. You may either supply its location as in `make SRCCONF=/root/outerbase-src.conf`, or just place it at `/etc/src.conf` **on both machines** (which is assumed for the follwing commands).

First, follow the above **steps 1 and 2 on the build machine**. Then, on the target machine, mount the necessary directories (read-only works fine):

    # mount_nfs -o nfsv4,ro buildbox:/usr/src /usr/src
    # mount_nfs -o nfsv4,ro buildbox:/usr/obj /usr/obj

Then, follow the above **steps 3 and 4 on the target machine**. Don't forget to have the correct `src.conf` in place.

If you see warnings like: `make[2] warning: /usr/src/: Read-only file system.`, these have been seen in testing and appeared to be harmless.

After installing, just unmount the directories and you're done:

    # umount /usr/obj
    # umount /usr/src

#### inner base

The inner base can be updated as normal when booted:

    # freebsd-update fetch
    # freebsd-update install

Note that `/outer/boot` and `/boot` are the same directory, so its contents will correspond to whatever update process you ran last.

## Ohrwurm
If the name of this project didn't make you think of [this song](https://www.youtube.com/watch?v=rsYPeP1XJuM) before, it will now!
