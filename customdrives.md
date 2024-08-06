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

general description, capabilities

#### boot partitions: dual ESPs

#### outer base: GEOM mirror

#### inner base: GELI-encrypted zpool mirror

#### `unlock.sh`: dual unlock

#### Soundtrack

[Blind Guardian - Mirror Mirror](https://www.youtube.com/watch?v=Z_p-FfinVTA)
