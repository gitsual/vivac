# vivac for Windows

*A **vivac** is the camp you pitch from what you carry and strike at dawn.
This is the [vivac](https://github.com/gitsual/vivac) workstation, rebuilt on
Windows 11 from the same twenty-odd lines of colour.*

**os** Windows 11 · **wm** [GlazeWM](https://github.com/glzr-io/glazewm) · **bar** [Zebar](https://github.com/glzr-io/zebar) · **launcher** [Flow Launcher](https://www.flowlauncher.com)<br>
**term** Windows Terminal · **editor** Neovim / NvChad · **font** JetBrains Mono Nerd Font<br>
**colour** `data/theme.conf` → `templates/` → `dotfiles/` · **scripts** Windows PowerShell 5.1, nothing to install first

The palettes, the colour doctrine, the wallpapers and the keyboard-first
desktop are the source's. What changes is everything underneath: Hyprland
becomes GlazeWM, Waybar becomes a Zebar widget, rofi becomes Flow Launcher and
a few native WPF windows, pacman becomes winget, Stow becomes a deploy with a
manifest and backups. [docs/mapping.md](docs/mapping.md) has the whole table,
including what does **not** carry over and why.

---

## Get it

```powershell
git clone https://github.com/gitsual/vivac-windows.git C:\vivac   # any path without spaces
cd C:\vivac
powershell -ExecutionPolicy Bypass -File scripts\bootstrap.ps1 -DryRun   # what it would install and write
powershell -ExecutionPolicy Bypass -File scripts\bootstrap.ps1 -Editor   # do it
```

`bootstrap.ps1` installs the base packages with winget (and the optional
sets you ask for: `-Editor`, `-Desktop`, `-Security`; `-ListSelectors` says
which apply to this machine), detects the hardware, deploys every
configuration, starts GlazeWM and opens the first-run wizard. It needs no
elevation.

Nothing is deleted. A file that is in the way goes to
`%LOCALAPPDATA%\vivac\backups\<timestamp>\` first, and

```powershell
scripts\uninstall.ps1 -DryRun   # see what it would put back
scripts\uninstall.ps1           # put it back
```

restores what was there before, the wallpaper and accent colour included.

## What you get

- **Eight palettes, one switch.** `MOD+Shift+T`, the `◐` in the bar, or
  `scripts\apply-theme.ps1 -Theme NAME`: wallpaper, accent colour, window
  borders, bar, launcher, and every terminal already open.
- **Tiling that stays out of the way.** Ten workspaces, a new window splits
  the one it lands on, move/resize/fullscreen are one chord each.
- **A bar that only shows what the machine has.** The Wi-Fi gauge needs an
  adapter, the battery a battery, the GPU temperature an NVIDIA card; the
  gauges are rendered per machine from detected hardware facts.
- **Every key, described.** `MOD+F1` opens the help pane, built from the
  same registry as [docs/keys.md](docs/keys.md); a live binding the registry
  does not know shows up as `UNREGISTERED` instead of disappearing.
- **A first run that teaches.** Language, modifier key, theme, then a tour
  that waits for you to actually press each key.
- **A security audit.** `scripts\security-audit.ps1` checks the antivirus,
  Defender exclusions, the firewall, every place a program can start itself
  with Windows, scheduled tasks, services, updates and UAC.
- **Windows Security in the palette.** A shield on the bar, bare while all
  is well, in the accent or the urgent colour with a few words when
  something needs a look; clicking it opens a vivac surface with Defender's
  state, a quick scan, a signature update and the history. Scans report
  back with a vivac notification. `scriptspply-system.ps1 -SecurityQuiet`
  (elevated) then hides Windows Security's own tray icon and non-critical
  notifications; threat alerts stay Windows' own.

`MOD` is the **Windows key**, as `SUPER` is in the source. Windows keeps a
few Win combinations for itself (Win+L locks, which is what `MOD+L` does
anyway); `mod=alt` in `%APPDATA%\vivac\settings`, or the wizard, switches to
Alt.

`scripts\apply-system.ps1 -Taskbar -DesktopIcons` removes the Windows taskbar
(its tray icons move into the bar) and the desktop icons, so the desktop is
the wallpaper, the bar and the windows, as in the source.

## The eight

| | | | |
|---|---|---|---|
| **Bad Romance** · Nocturne | **Carmen** · Appetite | **Cosmos** · Technique | **Gatsby** · Nostalgia |
| **Metropolis** · Resistance | **Northern Lights** · Quartz | **Persephone** · Romance | **The Hermit** · Endurance |

```powershell
scripts\apply-theme.ps1 -List
scripts\apply-theme.ps1 -Theme persephone -DryRun
scripts\make-wallpaper.ps1 -All    # every wallpaper, SVG + 3840x2160 PNG, into dist\wallpapers
```

## How colour works

Exactly as in the source. `data/theme.conf` holds the palette; everything that
carries a colour is a template under `templates/` and is rendered into
`dotfiles/`; a gate fails when a committed render and its template disagree.
Every colour must exist in `data/palette-corpus.tsv`, and a wallpaper carries
an ornament only when the theme has earned one.

Templates use the source's syntax: `@COLOR_BG@`, `@COLOR_BG:lower@`,
`@COLOR_BG:rgb@` and the derived shades `:dark`, `:darker`, `:dim`. The
per-machine templates under `render/` also see the settings (`@SET_MOD@`), the
hardware facts, and guard lines such as `@?has_battery=yes@`.

## Day to day

| | |
|---|---|
| `scripts\deploy.ps1 [-DryRun] [-Package glazewm,zebar,...]` | Render and place the configuration again |
| `scripts\apply-theme.ps1 -Theme NAME` | Switch palette, live |
| `scripts\apply-system.ps1 -DryRun -Session -Idle` | Opt-in profiles: start at sign-in, idle lock/sleep, taskbar auto-hide |
| `scripts\apply-system.ps1 -DryRun -Firewall -Defender -SecurityQuiet -LockScreen` | Machine-wide profiles (run elevated without `-DryRun`) |
| `scripts\security-audit.ps1` | Read-only audit (elevated to also see Defender exclusions) |
| `scripts\task.ps1 -Name NAME -Register` | A JSON-described task in the Task Scheduler ([example](profiles/automation/example.json)) |
| `scripts\hardware-facts.ps1` | What was detected; correct it in `%APPDATA%\vivac\hardware-facts.override` |
| `bin\vivac.ps1 welcome` | The wizard again |

## Verification

```powershell
scripts\check.ps1
```

Runs every gate, each file in a fresh PowerShell: every script parses and is
ASCII (Windows PowerShell 5.1 misreads anything else), JSON and XML are
well-formed, the renderer and predicate grammar behave, the eight palettes
obey the doctrine, the help registry and the GlazeWM bindings describe the
same keys with no key bound twice, every language carries every string,
hardware detection matches golden facts for five machines this one is not,
the WPF surfaces build in every theme, the committed renders have not drifted,
nothing private is in the tree, and the deploy regression runs end to end in a
scratch profile: dry run writes nothing, the second pass changes nothing, a
file that is not vivac's is backed up first, and uninstall restores it.

> **Author-run, not CI.** Like the source, these checks are run by hand
> before publication. Nothing re-runs them on each commit.

## Repository map

```text
data/        Palettes (the source's), corpus, help registry, selectors
templates/   Themed templates -> dotfiles/ (committed render) and the deploy
render/      Per-machine templates (palette + settings + hardware facts)
static/      Files deployed as they are: the bar's code, the Neovim config
dotfiles/    The default theme's render, committed and checked for drift
lib/         Vivac (render, settings, i18n), Deploy, Desktop, Apps, Surfaces
bin/         vivac.ps1 (help, power, theme, clipboard, notify) and the wizard
scripts/     bootstrap, deploy, apply-theme, apply-system, audit, uninstall...
packages/    winget manifests: base and optional sets
i18n/        English and Spanish
tests/       The gates, fixtures and golden files
```

## License

[MIT](LICENSE), as the source.
