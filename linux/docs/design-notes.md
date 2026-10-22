# Design and sanitization decisions

## From workstation to public system

The source workstation combines Arch Linux, Hyprland, three launchers, a highly customized Neovim workflow, PipeWire/WirePlumber tuning, Bluetooth reconnection, UFW, ClamAV and a tiered disk layout. The repository preserves those decisions while separating portable defaults, optional hardware profiles and local-only identifiers.

| Source characteristic | Public treatment |
|---|---|
| Absolute home paths and executable locations | `$HOME`, `localhost`, PATH lookup or script-relative discovery |
| Physical disk names, UUIDs, labels and exact mount paths | Architecture diagram and placeholder-based fstab model |
| Audio node names and device serials | Local renderer fed by `wpctl status -n` output |
| Permissive Bluetooth repair | Safer confirmation policy plus secure connections/privacy |
| NVIDIA environment | Optional hardware profile, not forced on every machine |
| Private wallpaper and desktop content | Purpose-built SVG preview and local wallpaper instructions |
| Neovim code containing an embedded credential | Secret-bearing block removed; provider auth comes from runtime environment or locally authenticated proxies |
| Shell integrations containing credentials/private endpoints | Safe portable baseline plus untracked `local.bash` extension point |
| Personal server/sync/game services | Generic JSON-driven systemd service/timer lifecycle; private commands and endpoints stay destination-local |
| Backups, histories, caches and nested Git data | Excluded before import |

## Engineering properties

1. **Allowlisted import:** components were selected by function; no recursive copy of the home directory was used.
2. **Layered deployment:** user files use Stow; privileged files require a separate reviewed command.
3. **Reversible changes:** destination conflicts and system files are backed up before replacement.
4. **Idempotence:** `stow --no-folding --restow` supports local overlays and safe repeated execution.
5. **Hardware privacy:** identifiers are rendered on the destination machine and never committed.
6. **Machine-specific renders:** files whose content depends on the machine (Waybar modules, Hyprland monitor/input/GPU fragments) are templates under `render/`, rendered from detected hardware facts into `$XDG_CONFIG_HOME` and never committed or stowed. The Waybar config left Stow for this reason: a JSON module array cannot be extended by a local overlay, only replaced. The renderer refuses any output path that resolves inside the checkout.
7. **Fail-closed publication:** suspicious names/content, binaries, syntax errors and Gitleaks findings block release.