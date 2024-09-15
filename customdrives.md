# freebsd-outerbase: `customdrives`

The [outerbase-install.sh](outerbase-install.sh) script is only made for a very simple, one-drive installation, and it's not realistic for the script to support more advanced drive/encryption configurations. Therefore, the `customdrives=` option provides a _“bring your own zpool”_ solution, where the system is installed onto a prepared outer base block device and zpool, which can be anything you can dream up.

The main guideline is that after the installation, the system should be able to boot from the outer base block device, and unlock the inner base zpool through `unlock.sh`, which of course needs to be tweaked to fit the drive configuration. As long as that works, many different kinds of setup should be possible.

## how it works
For a `customdrives` install, you need to do several things manually that [outerbase-install.sh](outerbase-install.sh) would take care of in the case of a simple, one-drive install:

* **boot partitions:** set up boot drives and partitions (EFI or MBR).

* **outer base block device:** set up a device to hold the outer base UFS filesystem (but do not format it yet).

* **zpool:** set up a zpool with the name set in `poolname` and import it with `-o altroot=/mnt`.

* **swap space,** if you want any.

Then you should prepare a number of files for the system to be installed:

* an `fstab` for the outer base
* an `fstab` for the inner base
* a `/boot/loader.conf` for the outer base
* appropriate modifications to `unlock.sh` in order to unlock and import your zpool

Finally, set the variables in `outerbase-install.sh` to correspond to you planned setup:

* set `customdrives` to any non-empty value
* set `outerbasedevice` to the outer base block device name (example: `/dev/mirror/outer`)
* set the paths where the installer can find the following files:
  * `customfstabouter` for the outer base's `fstab`
  * `customfstabinner` for the inner base's `fstab`
  * `bootloaderconf` for the outer base's `/boot/loader.conf`

There is no path to be set for `unlock.sh`. It is generated dynamically by the install script and placed at `/mnt/outer/root/unlock.sh`. You should modify it manually after installation.

With `customdrives` set, `outerbase-install.sh` can be called without any arguments. It will perform some sanity checks and present a confirmation dialog before the installation.

## tested implementations

I doubt that anyone in the world besides myself will ever do this, but if you install an outerbase system with `customdrives`, I'd love a description of your setup to publish here. For now, the following setup is the only one I have created and tested:

### Fully Mirrored Two-Drive System

This system uses two mirrored SSDs in order to be able to survive the failure of one drive.

Obviously, there are several ways to "hardware-RAID" (or maybe "BIOS-raid") such a configuration with minimal hassle. However, in keeping with the spirit of it, this system achieves the same by nailing extra legs onto freebsd-outerbase.

This system has two identically-sized SSDs, where the outer base is mirrored by GEOM and formatted to UFS, while the inner base is a mirror of two GELI-encrypted partitions.

    .--------- SSD 1 ----------.                .--------- SSD 2 ----------.
    | .----------------------. |                | .----------------------. |
    | |       gpt/esp0       | |                | |       gpt/esp1       | |
    | |      ESP: FAT32      | |                | |      ESP: FAT32      | |
    | |      loader.efi      | |                | |      loader.efi      | |
    | ·----------------------· |                | ·----------------------· |
    | .----------------------. |                | .----------------------. |
    | |     gpt/swap0.eli    | |                | |     gpt/swap1.eli    | |
    | |         swap         | |                | |         swap         | |
    | ·----------------------· |                | ·----------------------· |
    | .----------------------. |                | .----------------------. |
    | |      gpt/outer0      | |                | |      gpt/outer1      | |
    | |         UFS         <------ gmirror ------->        UFS          | |
    | |      outer base      | |  mirror/outer  | |      outer base      | |
    | ·----------------------· |                | ·----------------------· |
    | .----------------------. |                | .----------------------. |
    | |      gpt/inner0      | |                | |      gpt/inner1      | |
    | |         GELI         | |                | |         GELI         | |
    | | .------------------. | |                | | .------------------. | |
    | | |  gpt/inner0.eli  | | |                | | |  gpt/inner1.eli  | | |
    | | |       ZFS       <------- zfs mirror ------->      ZFS        | | |
    | | |    inner base    | | |     zroot      | | |    inner base    | | |
    | | ·------------------· | |                | | ·------------------· | |
    | ·----------------------· |                | ·----------------------· |
    ·--------------------------·                ·--------------------------·

The idea is that if one drive fails, the other one will still be able to boot into the outer base residing on the degraded `/dev/mirror/outer`, which can in turn unlock and boot the inner base, residing on a degraded zfs mirror. (This has been tested by yanking one of the drives out when the system was shut down.)

A ~bug~ feature of this setup is that `unlock.sh` will fail to unlock the missing GELI partitions and abort rebooting into the inner base unless/until `set -e` is disabled. This alerts the user to the drive failure.

Otherwise, everything should work the same as in a regular freebsd-outerbase system, especially updating the outer base. The only additional maintenance task should be to update both ESPs individually in case `loader.efi` needs to be replaced.

#### installing

The following descriptions are kept brief, highlighting the differences to the simple, one-drive installation, aimed at people familiar with the freebsd-outerbase installation process (just myself, honestly).

The first step is partitioning both drives as laid out in the work of ASCII art above.

#### boot partitions: dual ESPs

The same procedure as the regular freebsd-outerbase install with UEFI boot (installing `/boot/loader.efi` as `\EFI\BOOT\BOOTX64.EFI`), but once on each drive.

It might be advisable to register both ESPs through `efibootmgr`, but in testing on VirtualBox and a physical HP Prodesk computer, it proved to be unnecessary for the automatic failover after removing one drive.

#### inner base: GELI-encrypted zpool mirror

To set up both encrypted partitions for the zfs mirror, you can either type your passphrase four times by using:

```
geli load
geli init /dev/gpt/inner0
geli init /dev/gpt/inner1
geli attach /dev/gpt/inner0
geli attach /dev/gpt/inner1
```

… or you can export your passphrase to a variable and pipe it into geli:

```
export $passphrase="this is my s3cr3t"
geli load
echo $passphrase | geli init -J - /dev/gpt/inner0
echo $passphrase | geli init -J - /dev/gpt/inner1
echo $passphrase | geli attach -j - /dev/gpt/inner0
echo $passphrase | geli attach -j - /dev/gpt/inner1
```

After verifying with `geli status` that both encrypted partitions are attached, you may create the zpool, which I found the most fun:

`zpool create -o ashift=12 -m none -o altroot=/mnt zroot mirror /dev/gpt/inner0.eli /dev/gpt/inner1.eli`

With the zpool set up, feel free to `zpool status` and `zpool list -v` and smile.

#### outer base: GEOM mirror

With the zpool created, set up the outer base mirror:

```
gmirror load
gmirror label outer /dev/gpt/outer0 /dev/gpt/outer1
```

Successful operation can be verified by `gmirror status`.

**Note:** When trying this process the other way around – first creating `mirror/outer`, then `gpt/inner{0,1}.eli`, I found that gmirror doesn't seem to like `/dev/gpt/`. It creates the mirror using `/dev/diskid/` entries, which whithers (i.e. disappears) all `/dev/gpt/` entries. In order to avoid that, I created `gpt/inner{0,1}.eli` first, and only afterwards used gmirror (which causes it to use old-school device names like `nda0p2`).

#### custom files: outer base /etc/fstab

```
/dev/mirror/outer /         ufs     rw,noatime 1 1
tmpfs             /var/log  tmpfs   rw,size=100m,noexec          0 0
tmpfs             /tmp      tmpfs   rw,size=500m,mode=777,nosuid 0 0
```

#### custom files: inner base /etc/fstab

```
/dev/mirror/outer  /outer    ufs     rw,noatime 1 1
/dev/gpt/swap0.eli none      swap    sw 0 0
/dev/gpt/swap1.eli none      swap    sw 0 0
tmpfs              /tmp      tmpfs   rw,mode=777,nosuid 0 0
```

#### custom files: /boot/loader.conf

```
autoboot_delay="4"
geom_mirror_load="YES"
vfs.root.mountfrom="ufs:/dev/mirror/outer"
geom_eli_load="YES"
zfs_load="YES"
```

#### setting up `outerbase-install.sh`

Prepare `outerbase-install.sh` with the following settings:

```
customdrives=set
outerbasedevice=/dev/mirror/outer
customfstabouter=/tmp/tmp/fstab.outer
customfstabinner=/tmp/tmp/fstab.inner
bootloaderconf=/tmp/tmp/boot.loader
outerbasetxz=/tmp/tmp/outerbase.txz
```

Furthermore, set `hostname=`, `poolname=` and `rootpw=` and other settings according to your needs. Most install-related settings like `gelipassphrase=` and `swapsize=` will be ignored.

Then you'll need to transfer the relevant files to the installer image, which I tend to do like so:

```
dhclient em0
mkdir /tmp/tmp
mount -t tmpfs tmpfs /tmp/tmp
cd /tmp/tmp
nc -l 8000 | tar xf -
```

from another machine containing the requisite files, transfer them over:

```
tar cf - outerbase-install.sh outerbase.txz fstab.outer fstab.inner loader.conf | nc -N target 8000
```

Then, cross your fingers and run `sh outerbase-install.sh`.

#### tweaking `unlock.sh`

Before (or after, if you like) rebooting into the outer base for the first time, you need to adapt `unlock.sh` in order for it to unlock the inner base correctly.

The minimal modification to `unlock.sh` would require you to enter the passphrase twice. In order to avoid this, you can type it into a shell variable, which then pipes it into `geli attach`. Edit the relevant portion of `unlock.sh` like so:

```
stty -echo
read -p "GELI password to unlock inner base: " -r gelipw
echo
stty echo

echo $gelipw | geli attach -j - gpt/inner0
echo $gelipw | geli attach -j - gpt/inner1
```

#### Ohrwurm

The official soundtrack for the Fully Mirrored Two-Drive System implementation of freebsd-outerbase is:

[**Blind Guardian - Mirror Mirror**](https://www.youtube.com/watch?v=Z_p-FfinVTA)
