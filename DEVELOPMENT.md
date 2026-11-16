# Development

See [bsdinstall](https://cgit.freebsd.org/src/tree/usr.sbin/bsdinstall?h=releng/15.0)
reference implementation for inspiration.

## Test VM

Assuming a vm-bhyve installation:

```
vm create -t freebsd-zvol outerbase-test
vim /vm/outerbase-test/outerbase-test.conf
# rename disk0 to disk1 then add:
disk0_type="ahci-hd"
disk0_name="../.iso/FreeBSD-14.2-RELEASE-amd64-memstick.img"
# pkg+geli will require more mem
memory=1G
# EOF
vm start -f outerbase-test

dhclient vtnet0
cd /tmp
# python -m http.server 8000 # on host
fetch http://192.168.1.232:8000/outerbase-install.sh
sh outerbase-install.sh vtbd0
```

## Notes

- List included package *sets* (dependencies):

        pkg query '%dn' FreeBSD-set-base
