# Services and maintenance

## User services included

- PipeWire, PipeWire-Pulse and WirePlumber are enabled by their packages/socket activation.
- `clamav-home-scan.timer` schedules a low-priority weekly malware scan.
- Desktop daemons (Waybar, Dunst, Hyprpaper, keyring and portal) start from Hyprland.

## System services

`apply-system.sh` enables:

- `bluetooth.service`;
- `clamav-freshclam.service`;
- `ufw.service`;
- `fstrim.timer`.

## Generic graphical session

The optional `desktop-login` profile installs greetd/tuigreet and a generic Hyprland session. It is opt-in so vivac does not replace an existing display manager unexpectedly. The VM profile adds QEMU/SPICE guest integration without forcing it onto physical hardware.

## Portable private-function layer

Application servers, synchronization jobs, gaming watchdogs and machine-bound services are not copied with their private parameters. Their behavior can instead be represented by `workstation-task@.service`, `workstation-task@.timer` and destination-local JSON task descriptions. See [Portable automations](automations.md).

## Update cycle

```bash
sudo pacman -Syu
./scripts/update-manifests.sh
./scripts/check.sh
```

Use `./scripts/update-manifests.sh --full-local` for ignored private snapshots of all explicitly installed packages before deciding what belongs in the public curated manifest.
