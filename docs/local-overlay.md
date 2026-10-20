# Owner overlay: keep your own keys and editor settings

vivac never edits your personal files. Hyprland keys live in
`~/.config/hypr/local.lua`, Neovim additions in `~/.config/nvim/lua/local/init.lua`.
Both are loaded last, so they win, and both are guarded: a missing file is normal
and a broken one is logged while vivac's own config stays in effect.

## Quick path

1. Copy the example: `cp ~/.config/hypr/local.lua.example ~/.config/hypr/local.lua`.
2. Keep the blocks you want, delete the rest, add your own binds.
3. Reload (`SUPER+SHIFT+R`) and press `F1`: the Hyprland pane lists your keys.

## Hyprland: `local.lua`

| You want | Write in `local.lua` |
|----------|----------------------|
| Take a key vivac uses | `hl.unbind("SUPER + R")`, then `hl.bind("SUPER + A", ...)` |
| Show it in `F1` | `-- @help: hypr <label_key>` on the line right above the `hl.bind` |
| Change a started program | `vivac.autostart_set("hypridle", false)` removes it; `vivac.autostart_set(id, "cmd")` replaces it |
| Extra environment, rules, monitors | `hl.env`, `hl.window_rule`, `hl.monitor`: your call wins over vivac's |
| Terminal, scripts directory | `vivac.terminal`, `vivac.scripts` |

Rules for the `F1` line:

- The label is the one vivac uses for the default key: see `data/help-registry.tsv`.
- The bind is one line, starting in column 0, with the key as a plain string:
  `hl.bind("SUPER + A", ...)`. A key built with `..`, a loop, or an indented bind
  is not read, and `F1` keeps the default key.
- A key another vivac row already shows is ignored.

If `local.lua` does not parse, or does not exist, `F1` shows vivac's default keys.

## Import checklist (from an existing `hyprland.lua`)

- [ ] List the keys you use that vivac also binds (`SUPER+R`, `SUPER+D`, `SUPER+L`,
      `SUPER+SHIFT+Q`, `F2`, and the rest of the registry). Decide who keeps each.
- [ ] For every key you keep, write `hl.unbind(...)` then your `hl.bind(...)`.
- [ ] Add the `-- @help:` line above each bind that replaces a vivac feature.
- [ ] Move your own binds, rules and environment lines over unchanged.
- [ ] Drop what vivac already does: monitors, input, GPU environment and the usual
      session variables are generated from this machine's hardware facts.
- [ ] Replace built keys (`mainMod .. " + X"`) by literal strings in the binds you annotate.
- [ ] Run `Hyprland --verify-config -c ~/.config/hypr/hyprland.lua`.

A key or config name Hyprland itself rejects (an unknown key name, a misspelt
setting) is reported by `--verify-config` even from `local.lua`. Plain Lua mistakes
are not: they are logged and a notification says so.

## Neovim: `lua/local/init.lua`

vivac's `init.lua` ends with `pcall(require, "local")`. Put your own mappings and
options in `~/.config/nvim/lua/local/init.lua`; vivac does not ship that file.

- [ ] Deploy backs up every file of your old config that vivac replaces
      (under `~/.local/state/vivac/backups/<stamp>/`); files vivac has no
      counterpart for stay where they are.
- [ ] Move only what you use into `lua/local/`. Unused plugin setups are dead code.

## What the installer leaves alone

`scripts/deploy.sh` never creates, overwrites or deletes `local.lua`, and
`scripts/test-deploy.sh` checks that it stays byte-identical across deploys.
