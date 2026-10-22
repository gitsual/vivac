# From Arch to Windows: what maps to what

vivac on Arch is a Wayland desktop built from small programs. Windows 11 has a
desktop already, so this port does not replace it: it puts a tiling window
manager, a bar and a launcher on top, dresses Windows' own surfaces in the
palette, and keeps every rule of the source that still means something here.

## The pieces

| Layer | Arch (vivac) | Windows 11 (this repository) | Notes |
|---|---|---|---|
| Window manager | Hyprland | **GlazeWM** | Tiling, ten workspaces, the same bindings. Borders in the palette (Windows 11 only API). |
| Bar | Waybar | **Zebar** | Plain HTML/CSS/JS widget, no build step. Gauges rendered per machine from hardware facts. |
| Launcher | rofi · wofi · dmenu | **Flow Launcher** | Themed XAML rendered from the palette. One launcher instead of three. |
| Terminal | kitty | **Windows Terminal** | A `vivac` colour scheme merged into its settings; open terminals reload by themselves. |
| Editor | Neovim + NvChad | Neovim + NvChad | The same config and lockfile; clipboard and avante's build adapted. |
| Notifications | dunst | Windows notifications | Native toasts. They cannot be themed. |
| Lock + idle | hyprlock + hypridle | Windows lock + secure screen saver + `powercfg` | `apply-system.ps1 -Idle`: lock at 5 min, screen off at 10, sleep at 30. |
| Wallpaper | swaybg | Windows wallpaper | Rendered from the same SVG templates, rasterized by Edge. |
| Power menu | nwg-bar · rofi | WPF window (`MOD+Shift+E`) | Asks twice before ending the session. |
| Theme picker | rofi | WPF window (`MOD+Shift+T`) | Reads the catalogue from `data/themes/` each time. |
| Help panes | rofi, F1-F5 | WPF window (`MOD+F1`), F1-F5 inside | Live bindings not in the registry show as `UNREGISTERED`. |
| Clipboard history | cliphist | Windows clipboard history (Win+V) | With `mod=alt`, `MOD+V` forwards to it. |
| Taskbar | (none) | Hidden (`apply-system.ps1 -Taskbar`) | Kept hidden by the resident host; tray icons move into the bar. |
| Desktop icons | (none) | Hidden (`apply-system.ps1 -DesktopIcons`) | |
| Screenshots | grim + slurp | Snipping Tool (`MOD+Shift+S`) | Its own notification names the file. |
| Login | greetd + ReGreet | Windows sign-in | `apply-system.ps1 -LockScreen` puts the wallpaper on the lock screen. |
| Packages | pacman manifests | **winget** manifests | `packages/*.txt`; optional sets selected by hardware facts. |
| Deployment | GNU Stow symlinks | Copy + manifest + backups | Symlinks need Developer Mode or elevation on Windows. |
| Firewall | UFW | Windows Defender Firewall | Inbound denied, outbound allowed, existing rules kept. |
| Antivirus | ClamAV, weekly scan | Microsoft Defender, weekly quick scan, plus Malwarebytes (`-Security`) | One surface and one bar shield for both (`vivac security`): Defender's protection, signatures and scans, Malwarebytes' service, layers, scans, database and licence. |
| Security status | (none) | Shield on the bar, `vivac security` surface | Replaces Windows Security's tray icon and summaries (`-SecurityQuiet`); threat alerts stay native. |
| Audits | rkhunter, Lynis | `scripts/security-audit.ps1` | Antivirus, exclusions, firewall, every autostart location, tasks, services, updates, UAC. |
| Secrets | GNOME Keyring + KeePassXC | Windows Credential Manager + KeePassXC | |
| Automation | systemd user units + JSON runner | Task Scheduler + JSON runner | `scripts/task.ps1`; no shell between the task and the program. |
| First run | `vivac-welcome` | `bin/vivac-welcome.ps1` | Language, modifier, theme, and a tour that waits for each key. |
| Gates | `scripts/check.sh` | `scripts/check.ps1` | Author-run, like the source. |

## The rules that carry over

- **One palette file.** `data/theme.conf` and `data/themes/*.conf` are the
  source's own files, unchanged. Every themed file is a template under
  `templates/`; the default render is committed under `dotfiles/` and a gate
  fails on drift.
- **Every colour comes from the corpus**, and an ornament on a wallpaper is
  earned (an affinity in the root matrix, or an aesthetic that carries its
  canonical colours) or refused, never quietly dropped.
- **Hardware facts are detected, not assumed**, through an allowlist, and
  never written into the checkout.
- **One writer per setting**; values are validated before they land.
- **Nothing is deleted**; a conflicting file goes to a timestamped backup.
- **Labels come from `i18n/`, actions never do.**

## What is not reproduced, and why

- **Not every Win combination is the window manager's.** The modifier is the
  Windows key, as in the source, but Windows reserves a few for itself:
  Win+L always locks (which `MOD+L` does anyway), and Win+V, Win+D and the
  like keep their Windows meaning when vivac binds nothing there. Alt is one
  setting away (`mod=alt`, or the welcome wizard) for whoever prefers it.
- **Help panes open with `MOD+F1`, not bare F1-F5.** On Windows, F1, F2 and F5
  are used by nearly every application (help, rename, refresh); taking them
  globally would break them everywhere. Inside the pane, F1-F5 switch panes.
- **Workspaces are walked with `MOD+,` and `MOD+.`**, not brackets: on a
  Spanish keyboard the brackets need AltGr.
- **Notifications are not themed.** Windows draws them; there is no API.
- **No CPU temperature in the bar.** Windows only exposes it to elevated
  processes; the GPU temperature is shown on NVIDIA through `nvidia-smi`.
- **No disk layout.** The source's Btrfs layout has no Windows counterpart
  worth imposing on an installed system.
- **No bootable image or VM gate.** The source proves itself in a QEMU guest
  built from the tree; here the deploy regression runs against a scratch
  profile instead (`tests/cases/Deploy.Tests.ps1`), which proves less.
