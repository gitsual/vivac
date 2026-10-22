# Recommended storage architecture

The live workstation uses a pattern worth reproducing without publishing its device names, UUIDs, labels, mount paths or exact capacities.

## Layout

1. **Fast system SSD**
   - GPT partition table.
   - EFI System Partition mounted at `/boot/efi`.
   - Btrfs system partition with separate `@` and `@home` subvolumes.
   - SSD-aware asynchronous discard.
2. **Native Linux data disk**
   - ext4 for large projects, media, backups and workloads that should not consume the system SSD.
   - `nofail` so boot is not blocked when the drive is absent.
   - `noatime` to reduce needless metadata writes.
3. **Interoperability disk**
   - NTFS3 only when the same data must be writable from Windows and Linux.
   - `nofail` and a bounded systemd device timeout.
4. **Encryption recommendation**
   - Use LUKS2 for Linux-only private data. Keep recovery headers and keys offline.
   - Do not copy UUIDs from another machine; generate them during installation and insert the local values.

## Sanitized `/etc/fstab` model

```fstab
UUID=<root-filesystem-id>  /          btrfs  rw,relatime,ssd,discard=async,space_cache=v2,subvol=/@      0 0
UUID=<root-filesystem-id>  /home      btrfs  rw,relatime,ssd,discard=async,space_cache=v2,subvol=/@home  0 0
UUID=<efi-filesystem-id>   /boot/efi  vfat   rw,relatime,fmask=0022,dmask=0022,utf8,errors=remount-ro    0 2
UUID=<linux-data-id>       /mnt/data  ext4   defaults,noatime,nofail,x-systemd.device-timeout=30        0 2
UUID=<shared-data-id>      /mnt/shared ntfs3 rw,relatime,dmask=0022,fmask=0022,acl,iocharset=utf8,nofail,x-systemd.device-timeout=30 0 0
```

Use `lsblk -f` and `blkid` locally to obtain identifiers. Never publish the resulting file unchanged.

## Operational safeguards

- Enable `fstrim.timer` for SSDs.
- Keep at least one backup on a different physical device.
- Test mounts with `sudo mount -a` before rebooting.
- Prefer Btrfs snapshots for system rollback, but do not treat snapshots as backups.
- Keep user data off the root filesystem when large media/VM/model workloads are expected.
