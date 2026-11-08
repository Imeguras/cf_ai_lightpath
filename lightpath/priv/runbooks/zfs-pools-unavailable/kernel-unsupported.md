What fixed it on 2026-11-08 (the author): build a zfs-dkms that supports the
running kernel, then load the module and import.

  paru -S zfs-dkms --assume-installed zfs-utils=2.4.4-1
  paru -S zfs-utils
  doas modprobe zfs
  doas zpool import -a
  zpool status

The --assume-installed breaks the zfs-dkms/zfs-utils version lock for one
transaction, so both can move to the new version.

Alternative when no zfs-dkms supports the kernel yet: install linux-lts and
linux-lts-headers with pacman, and boot it until zfs-dkms catches up.

Check afterwards: `dkms status` shows zfs ... installed for the running
kernel, and the libvirt storage pools on ZFS start again.
