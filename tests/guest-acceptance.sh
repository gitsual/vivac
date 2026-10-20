#!/usr/bin/env bash
# The acceptance a provisioned guest must pass. Fed to the guest over SSH
# (bash -s) by scripts/test-vm.sh and scripts/build-vm-image.sh, so the
# gate and the published image assert the same thing and cannot drift.
# CONSOLE_KEYMAP is exported by the caller.
set -Eeuo pipefail
sudo pacman -Syu --noconfirm
sudo mkdir -p /mnt/vivac
sudo mount -L VIVAC -o ro /mnt/vivac
mkdir -p "$HOME/vivac"
tar -xzf /mnt/vivac/repository.tar.gz -C "$HOME/vivac"
cd "$HOME/vivac"
# Three language axes with three distinguishable values, so each assertion
# below can only be satisfied by its own writer.
mkdir -p "$HOME/.config/vivac"
printf 'locale=es_ES.UTF-8\nkeymap=%s\nxkb_layout=fr\nime=fcitx5\n' "$CONSOLE_KEYMAP" >"$HOME/.config/vivac/settings"
./scripts/bootstrap.sh --noconfirm --desktop-login --vm --desktop --ime --ricer --gui-greeter --apps
./scripts/apply-system.sh --locale --keymap
grep -Fxq 'LANG=es_ES.UTF-8' /etc/locale.conf
LC_ALL=C locale -a | grep -Fxq 'es_ES.utf8'
grep -Fxq "KEYMAP=$CONSOLE_KEYMAP" /etc/vconsole.conf
grep -Fxq 'hl.config({ input = { kb_layout = "fr", follow_mouse = 1 } })' "$HOME/.config/hypr/generated/input.lua"
./scripts/test-neovim.sh
./scripts/apply-system.sh --dry-run --desktop-login --vm
# The graphical greeter is rendered, not installed (the guest keeps its
# autologin): its two axes carry the seeded locale and layout, distinct from
# each other and from the console keymap.
greeter_plan="$(./scripts/apply-system.sh --dry-run --greeter)"
grep -q 'LANG=es_ES.UTF-8 XKB_DEFAULT_LAYOUT=fr cage -s -- regreet' <<<"$greeter_plan"
pacman -Qq greetd-regreet cage >/dev/null
mkdir -p /tmp/vivac-runtime
chmod 700 /tmp/vivac-runtime
XDG_RUNTIME_DIR=/tmp/vivac-runtime Hyprland --verify-config -c "$HOME/.config/hypr/hyprland.lua"
for fragment in hardware monitors input; do
  test -f "$HOME/.config/hypr/generated/$fragment.lua"
  test ! -L "$HOME/.config/hypr/generated/$fragment.lua"
done
# The owner's local.lua is contained: one that raises and one that does not
# parse both still verify, and neither is left behind in the guest.
for broken in 'error("owner mistake")' 'this is = not lua ('; do
  printf '%s\n' "$broken" >"$HOME/.config/hypr/local.lua"
  verified=0
  XDG_RUNTIME_DIR=/tmp/vivac-runtime Hyprland --verify-config -c "$HOME/.config/hypr/hyprland.lua" || verified=$?
  rm -f "$HOME/.config/hypr/local.lua"
  test "$verified" -eq 0
done
python -m json.tool "$HOME/.config/waybar/config" >/dev/null
./scripts/render-config.sh --check-drift
# Captured, then grepped: under pipefail a grep -q that closes the pipe early
# turns the producer's SIGPIPE into a failure.
gpu_plan="$(./scripts/gpu-setup.sh --dry-run)"
grep -q '^GPU families: virtio$' <<<"$gpu_plan"
gpu_list="$(./scripts/gpu-setup.sh --list)"
grep -q '^virtio .*VM gate' <<<"$gpu_list"
./scripts/gpu-setup.sh --apply
# A re-render over a changed fragment leaves a backup; the restore finds it.
printf -- '-- local edit\n' >>"$HOME/.config/hypr/generated/hardware.lua"
./scripts/render-config.sh --deploy >/dev/null
gpu_restore="$(./scripts/gpu-setup.sh --restore-config --dry-run)"
grep -q '^would restore' <<<"$gpu_restore"
# The input method reaches the compositor through the input fragment only,
# and CJK and emoji resolve by code point to installed fonts.
# The renderer keeps one leading space on template-guarded lines (so a privacy
# scan does not mistake a guard marker for an email): match with or without it.
fragment_has() { grep -Fxq -e "$2" -e " $2" "$1"; }
fragment_has "$HOME/.config/hypr/generated/input.lua" 'hl.env("QT_IM_MODULE", "fcitx")'
grep -Fq '{ id = "fcitx5", cmd = "fcitx5 -d" }' "$HOME/.config/hypr/generated/input.lua"
# A bare "! grep" is exempt from errexit, so these negative assertions state
# the failure explicitly: finding the needle is the failure.
grep -rq fcitx "$HOME/.config/hypr/generated/hardware.lua" "$HOME/.config/hypr/generated/monitors.lua" "$HOME/.config/waybar/config" && exit 1
command -v fcitx5 >/dev/null
fc-match -f '%{family}\n' ':charset=4e2d' | grep -q CJK
fc-match -f '%{family}\n' ':charset=3042' | grep -q CJK
fc-match -f '%{family}\n' ':charset=1f600' | grep -qi emoji
# Ricing tools: installed, configured through Stow, and hypridle wired into
# the session (whether it is running after a login is a destination test).
for executable in hypridle nwg-bar cliphist swappy wf-recorder nwg-look qt6ct; do
  command -v "$executable" >/dev/null
done
test -L "$HOME/.config/hypr/hypridle.conf"
# The power menu's own definition is not a stowed file: the labels follow the
# session language, which changes without a redeploy, so the JSON is generated
# into the runtime directory at each launch. What is stowed is the stylesheet
# and the icons the buttons draw.
test -L "$HOME/.config/nwg-bar/style.css"
test -L "$HOME/.config/nwg-bar/icons/power-off.svg"
"$HOME/.local/bin/vivac-power" --print | python -c 'import json,sys; assert len(json.load(sys.stdin)) == 5'
grep -Fq '{ id = "hypridle"' "$HOME/.config/hypr/hyprland.lua"
# The workspace strip and the help panes work through the stowed scripts
# with no session behind them: ten numbers, and every registered key.
strip="$(WS_CACHE=/nonexistent "$HOME/.config/waybar/scripts/ws-render.sh" | python -c 'import json,sys; print(json.load(sys.stdin)["text"])')"
[[ "$strip" == '1  2  3  4  5  6  7  8  9  10' ]]
pane="$(HYPRLAND_INSTANCE_SIGNATURE='' "$HOME/.config/hypr/scripts/help-pane.sh" --pane hypr --plain --lang es)"
[[ "$(wc -l <<<"$pane")" -eq "$(grep -c $'\thypr\t' data/help-registry.tsv)" ]]
grep -q UNREGISTERED <<<"$pane" && exit 1
grep -q $'^SUPER+Return\tAbrir una terminal$' <<<"$pane"
# Every package the desktop selector promises is installed.
# The manifest is one package per line and is meant to split into arguments.
# shellcheck disable=SC2046
pacman -Qq $(grep -Ev '^[[:space:]]*(#|$)' packages/desktop.txt) >/dev/null
for executable in Hyprland waybar kitty dunst rofi dmenu_run wofi nvim clamscan ufw greetd tuigreet firefox thunar mpv; do
  command -v "$executable" >/dev/null
 done
printf '%s\n' 'VM_ACCEPTANCE: PASS'
