# Boot menu follows the theme (boot-sync)

GRUB's menu theme and the boot logo HackBGRT draws for Windows live on the
EFI system partition (ESP), which is root's. Windows already carries the
theme there (`windows/scripts/boot-sync.ps1`); this is the same contract for
Arch, so a theme switch on either side updates the boot.

| Half | Runs as | File |
| --- | --- | --- |
| stage | the user, on every theme switch | `scripts/boot-stage.sh` (called by `scripts/apply-theme.sh` when the stage folder exists) |
| sync | root, from a systemd service | `scripts/boot-sync.py`, installed as `/usr/local/lib/vivac/boot-sync.py` |

## Permission model (the twin of Windows')

| | Windows | Arch |
| --- | --- | --- |
| stage | `%ProgramData%\vivac\boot-stage`, users write | `/var/lib/vivac/boot-stage`, `root:wheel` mode 2770 |
| code that runs privileged | `%ProgramFiles%\vivac\boot-sync.ps1`, admins only | `/usr/local/lib/vivac/boot-sync.py`, root only |
| trigger | scheduled task the user may start, not edit | `vivac-boot-sync.path` on `palette.conf` |
| log | `%ProgramFiles%\vivac\boot-sync.log` | `/var/log/vivac/boot-sync.log` (root only) |

The sync trusts nothing in the stage: closed list of palette keys, six hex
digits each, a plausible screen size, pictures that must be PNG, are capped
at 40 MB / 64 megapixels and are decoded and encoded anew, links and special
files refused. It renders everything before writing anything and writes only
`grub/themes/vivac/` and `EFI/HackBGRT/splash.bmp` (only if `EFI/HackBGRT`
exists). The service is further confined with `ProtectSystem=strict` and
`ReadWritePaths` limited to those two folders.

## Install (needs root; nothing here is done by the checkout)

    sudo install -Dm755 -o root -g root scripts/boot-sync.py /usr/local/lib/vivac/boot-sync.py
    sudo install -Dm644 system/etc/systemd/system/vivac-boot-sync.service /etc/systemd/system/vivac-boot-sync.service
    sudo install -Dm644 system/etc/systemd/system/vivac-boot-sync.path /etc/systemd/system/vivac-boot-sync.path
    sudo install -Dm644 system/usr/lib/tmpfiles.d/vivac-boot-stage.conf /usr/lib/tmpfiles.d/vivac-boot-stage.conf
    sudo systemd-tmpfiles --create vivac-boot-stage.conf
    sudo systemctl daemon-reload
    sudo systemctl enable --now vivac-boot-sync.path
    scripts/boot-stage.sh        # as the user: stages the current theme, the path unit does the rest
    journalctl -u vivac-boot-sync.service -n 20; sudo tail /var/log/vivac/boot-sync.log

## Undo

    sudo systemctl disable --now vivac-boot-sync.path
    sudo rm /etc/systemd/system/vivac-boot-sync.{service,path} /usr/lib/tmpfiles.d/vivac-boot-stage.conf /usr/local/lib/vivac/boot-sync.py
    sudo rm -r /var/lib/vivac/boot-stage /var/log/vivac/boot-sync.log
    sudo systemctl daemon-reload

The partition keeps the last theme written; Windows' task or a removal of
`/boot/efi/grub/custom.cfg` is how the menu goes back to plain.

## Differences from boot-sync.ps1

See the docstring of `scripts/boot-sync.py`: a stricter palette (unknown keys
are refused), links refused, a pixel cap, per-file replacement instead of
emptying the folder first, header says `boot-sync` and "on either system".
The frame pieces are drawn with Pillow, so edge pixels differ slightly from
GDI+'s (same geometry, colours, alpha).
