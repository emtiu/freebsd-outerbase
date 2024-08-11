# freebsd-outerbase: `customdrives`

The [outerbase-install.sh](outerbase-install.sh) script is only made for a very simple, one-drive installation, and it's not realistic for the script to support more advanced drive/encryption configurations. Therefore, `customdrives` provides a _“bring your own zpool”_ solution, where the system is installed onto a prepared outer base block device and zpool, which take any form you can dream of.

The main guideline is that after the installation, the system should be able to boot from the outer base block device, and unlock the inner base zpool through `unlock.sh`, which of course needs to be tweaked to fit the drive configuration. As long as that works, many different kinds of setup should be possible.

## how it works
For a `customdrives` install, you need to do several things that [outerbase-install.sh](outerbase-install.sh) would take care of in the case of a simple, one-drive install:

* **boot partitions:** set up boot partitions such that the system will be able to boot the outer base, corresponding to whichever device you are planning to use for the outer base UFS filesystem.

* **outer base block device:** set up a device to hold the outer base UFS filesystem (but do not format it yet).

* **zpool:** set up a zpool with the name set in `poolname` and import it with `-o altroot=/mnt`.

* **swap space,** if you want any.

Then you should prepare a number of files with appropriate settings for the system to be installed:

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

This system uses two mirrored SSDs in order to be able to survive the failure of one SSD, and still continue working.

Obviously, there are several ways to "hardware-RAID" (or rather, "BIOS-raid") such a configuration with minimal hassle. However, in keeping with the spirit of it, this system achieves the mirroring by nailing extra legs onto freebsd-outerbase.

This system has two identically-sized SSDs, where the outer base is mirrored by GEOM and formatted to UFS, while the inner base is a mirror of tow GELI-encrypted partitions.

    .--------- SSD 1 ----------.                .--------- SSD 2 ----------.
    | .----------------------. |                | .----------------------. |
    | |       gpt/efi0       | |                | |       gpt/efi1       | |
    | |      ESP: FAT32      | |                | |      ESP: FAT32      | |
    | |      loader.efi      | |                | |      loader.efi      | |
    | ·----------------------· |                | ·----------------------· |
    |                          |                |                          |
    | .----------------------. |                | .----------------------. |
    | |     gpt/swap0.eli    | |                | |     gpt/swap1.eli    | |
    | |         swap         | |                | |         swap         | |
    | ·----------------------· |                | ·----------------------· |
    |                          |                |                          |
    | .----------------------. |                | .----------------------. |
    | |      gpt/outer0      | |                | |      gpt/outer1      | |
    | |         UFS         <------ gmirror ------->        UFS          | |
    | |      outer base      | |  mirror/outer  | |      outer base      | |
    | ·----------------------· |                | ·----------------------· |
    |                          |                |                          |
    | .----------------------. |                | .----------------------. |
    | |      gpt/inner0      | |                | |      gpt/inner1      | |
    | |         GELI         | |                | |         GELI         | |
    | | .------------------. | |                | | .------------------. | |
    | | |  gpt/inner0.eli  | | |                | | |  gpt/inner0.eli  | | |
    | | |       ZFS       <------ zfs mirror -------->      ZFS        | | |
    | | |    inner base    | |       zroot      | | |    inner base    | | |
    | | ·------------------· | |                | | ·------------------· | |
    | ·----------------------· |                | ·----------------------· |
    ·--------------------------·                ·--------------------------·

The idea is that if one drive fails, the other one will still be able to boot into the outer base residing on the degraded `/dev/mirror/outer`, which can in turn unlock and boot the inner base, residing on a degraded zfs mirror. (This has been tested by yanking one of the driver out from under the system when shut down.)

A bu^H^Hfeature of this setup is that `unlock.sh` will fail to unlock one of the GELI partitions for the inner base unless `set -e` is disabled, alerting the user to the failure.

Otherwise, everything should work the same as in a regular freebsd-outerbase system, especially updating the outer base. The only manual maintenance would be to update both ESPs in case `loader.efi` needs to be replaced.

#### boot partitions: dual ESPs

#### outer base: GEOM mirror

```
gmirror load
gmirror label outer /dev/gpt/outer0 /dev/gpt/outer1
```

#### inner base: GELI-encrypted zpool mirror

```
geli init -J - /dev/gpt/inner0
geli init -J - /dev/gpt/inner1
geli attach -j - /dev/gpt/inner0
geli attach -j - /dev/gpt/inner1
```

`zpool create -o ashift=12 -m none -o altroot=/mnt zroot mirror /dev/gpt/inner0.eli /dev/gpt/inner1.eli`

#### fstabs

swap

#### `unlock.sh`: dual unlock

```
stty -echo
read -p "GELI password to unlock inner base: " -r gelipw
echo
stty echo

echo $gelipw | geli attach -j - gpt/inner0
echo $gelipw | geli attach -j - gpt/inner1
```

#### Soundtrack

[Blind Guardian - Mirror Mirror](https://www.youtube.com/watch?v=Z_p-FfinVTA)
