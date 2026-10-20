# Host deploy: adopt vivac on a machine that already has a setup

`scripts/deploy-host.sh` puts the Lua desktop on a machine whose owner already
has Hyprland, Waybar, kitty and a shell configured. It checks the new config
with Hyprland before anything changes, backs up every file it replaces, and
one command undoes all of it.

## Quick path

1. Write your `~/.config/hypr/local.lua` first ([import checklist](local-overlay.md)).
   The deploy refuses to replace a `hyprland.lua` of your own while there is no
   `local.lua` to carry its keys.
2. Make sure the hardware facts exist: `scripts/hardware-facts.sh --emit`.
3. Look: `scripts/deploy-host.sh --dry-run` verifies the staged config and
   lists what would happen. It changes nothing.
4. Deploy: `scripts/deploy-host.sh`. It prints the backup directory and the
   rollback command; keep both.
5. Log out and back in, press `F1`, and check your keys.

## What it does, in order

| Step | Effect on the host |
|------|--------------------|
| Preflight | Refuses without Stow, without Hyprland, without facts, without `local.lua` (see above). Nothing is written. |
| Stage | Renders the fragments and copies `hyprland.lua` into a scratch directory, with your `local.lua`. |
| Verify | `Hyprland --verify-config` on the staged config. Failure aborts; the host is untouched. |
| Back up | The backup directory must be writable, or it stops here. Every replaced file is copied or moved there first. |
| Deploy | `deploy.sh --protect ...` for the `hypr`, `nvim`, `ricer` and `welcome` packages (`--all` adds the system-level ones). |
| Recolour | Your Waybar, kitty, dunst, rofi and wofi files get the palette's colours and nothing else (they are never packages, not even with `--all`). |

The checkout location goes to `~/.config/vivac/repo`; the session reads it, so
the shared-settings pull at login finds this checkout even when it is not at `~/vivac`.

`--without PKG` (repeatable; `nvim`, `ricer` or `welcome`) leaves a package out:
it is not stowed and not backed up, and the output says `skipped: nvim (--without)`.
`hypr` is refused, it is the point of the deploy; any other name exits 2. Use
`--without nvim` today: the `avante.nvim` pin in `dotfiles/nvim` (lazy-lock, `94afb84`)
fails to source in the VM, while the owner's working pin is
`5e4eb8652b4776f139282a343f04a3a8c7f23cb0`. Known issue, to fix in a follow-up change.

## What it never touches

| Left alone | Why |
|------------|-----|
| `~/.bashrc` | Yours. |
| `~/.config/waybar/**` (scripts, config, `ws-refresh.sh`) | Yours; only colours in `style.css` change. |
| `~/.config/hypr/scripts/screenshot.sh`, `~/.config/hypr/hyprpaper.conf` | Yours; they collide with the hypr package, so they are protected. |
| `~/.config/hypr/local.lua` | Yours, never written, never backed up. |

Replaced with a backup: `~/.config/hypr/hyprland.lua` (your old content stays in
the backup for the `local.lua` import), `~/.config/nvim/init.lua` and the other
nvim files vivac ships, and the generated fragments. The old Hyprlang fragments
`~/.config/hypr/generated/{hardware,input,monitors}.conf` are backed up and removed.

## When verification fails

Only Lua-level breakage in `local.lua` is contained: a runtime error, a syntax
error or a missing module verify fine, and at login vivac logs it and shows a
notification. Errors Hyprland records itself, such as a bind with an unknown
key name or a misspelt config key in `local.lua`, make `--verify-config` fail,
and the deploy stops with Hyprland's own message. Fix the line and run again.

## Conflicts, failures and symlinked directories

Before the first file moves, `deploy-host.sh` runs `stow --simulate` for every
selected package; a conflict that a backup cannot clear (a file where a package
needs a directory) aborts with the list and the host untouched. If anything fails
after the first change, the run rolls itself back from its own `MANIFEST` and says
so (`rolled back automatically`); the backup is kept, marked as rolled back. A
top-level directory of your home that is a symlink to a directory elsewhere
(`~/.local` on another disk, say) stays as it is: the links land in the directory
it points at, and the rollback removes exactly those.

## Rollback

One command, from any TTY, restores the exact pre-deploy state: the old
`hyprland.lua`, the Hyprlang fragments, the original colours of your files, and
removes what the deploy created.

```bash
scripts/deploy-host.sh --rollback          # the newest backup that has something to undo
scripts/deploy-host.sh --rollback ~/.local/state/vivac/backups/<stamp>
```

The backups live in `~/.local/state/vivac/backups/<stamp>/`, with the same
layout as your home directory, plus a `MANIFEST` of what the deploy created.
Nothing in them is ever deleted by vivac. A deploy that finds the host already
matching keeps no backup, so running it twice never hides the first backup behind
an empty one; the bare `--rollback` prints which backup it used and skips one
that was already rolled back. The `MANIFEST` is checked before anything is
removed: a line that points outside your home, or a backup outside the backups
directory, is refused (`--force` accepts a backup kept elsewhere).

If the session does not start at all and you cannot run the script, from a TTY:

1. `mv ~/.config/hypr/hyprland.lua{,.vivac}` takes vivac's config out of the way
   (it is a link into the checkout). Use this name, not `.bak`: an older
   `hyprland.lua.bak` of yours would be overwritten.
2. `cp -a ~/.local/state/vivac/backups/<stamp>/.config/hypr/hyprland.lua ~/.config/hypr/`
   puts your old file back.
3. Restore anything else you need from the same directory with `cp -a`, then log in again.

## Checklist

- [ ] `local.lua` exists and carries your keys.
- [ ] `--dry-run` ended with "the staged config verified".
- [ ] You noted the backup directory and the rollback line.
- [ ] After login, `F1` shows your relocated keys.
