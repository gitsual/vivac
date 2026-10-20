# Keys

The help panes (`F1` to `F5`) render `data/help-registry.tsv` in the session
language; this page is the same registry for readers without a session. The
Hyprland pane is complete and checked against the template at every
`check.sh` run. The other four are starting points: the most-used keys of
the browser, the shell, the editor and the system, kept short on purpose.

## hypr

`F1`. Every bind in `templates/hypr/.config/hypr/hyprland.lua.in`, described
by the `-- @help:` line above it. A bind Hyprland reports at runtime that the
registry does not know renders as `UNREGISTERED` rather than disappearing.

## browser

`F2`. Tabs, the address bar and find-in-page, as Firefox and Chromium ship
them.

## shell

`F3`. Readline editing keys, which bash and zsh share by default.

## editor

`F4`. The Neovim leader (`Space`) and the first keys under it as the
configuration in `dotfiles/nvim` defines them; `docs/neovim.md` has the rest.

## system

`F5`. Consoles, media keys and the screenshot key: handled by the kernel, the
audio stack and Hyprland respectively, so they work outside any window.
