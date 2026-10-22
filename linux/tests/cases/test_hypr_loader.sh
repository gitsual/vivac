#!/usr/bin/env bash
set -Eeuo pipefail

# The committed hyprland.lua, run against a recording `hl` (tests/lua/hl_stub.lua):
# it binds exactly what the help registry describes, loads the generated
# fragments as modules, and loads the owner's local.lua as the very last thing,
# guarded, so an absent, broken or overriding local.lua can never take the
# compositor down.

repo_root="${REPO_ROOT:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)}"
config="$repo_root/dotfiles/hypr/.config/hypr/hyprland.lua"
stub="$repo_root/tests/lua/hl_stub.lua"
sandbox="$(mktemp -d "${TMPDIR:-/tmp}/vivac-loader.XXXXXX")"
trap 'rm -rf -- "$sandbox"' EXIT

fail() {
	printf '%s\n' "$1" >&2
	exit 1
}

# A session's config directory: the committed file plus the rendered fragments.
home="$sandbox/home"
mkdir -p -- "$home"
HOME="$home" XDG_CONFIG_HOME="$home/.config" XDG_STATE_HOME="$sandbox/state" \
	FACTS_FILE="$repo_root/tests/golden/desktop-nvidia/hardware-facts" FACTS_OVERRIDE="$sandbox/none" \
	bash "$repo_root/scripts/render-config.sh" --deploy >/dev/null || fail 'could not render the fragments'
hypr="$home/.config/hypr"
cp -- "$config" "$hypr/hyprland.lua"

# load [ENV=VALUE...] — run the config in the session directory, leave the facts in $out.
load() {
	out="$(env HOME="$home" XDG_CONFIG_HOME="$home/.config" "$@" nvim -l "$stub" "$hypr/hyprland.lua" 2>"$sandbox/err")" ||
		fail "the config did not load: $(<"$sandbox/err")"
}
has() { grep -Fxq -- "$1" <<<"$out"; }
lines() { grep -c -- "$1" <<<"$out" || true; }

registry_rows="$(grep -c $'\thypr\t' "$repo_root/data/help-registry.tsv")"

# --- no local.lua: every registered key is bound, nothing is logged -------------------------------------------
load
has "final $registry_rows" || fail "expected $registry_rows binds: $(grep '^final' <<<"$out")"
[[ "$(lines '^bind ')" -eq "$registry_rows" ]] || fail "expected $registry_rows bind calls, saw $(lines '^bind ')"
has 'bind SUPER + Return => exec_cmd(kitty)' || fail 'SUPER+Return does not open the terminal'
has 'bind SUPER + Q => window.close()' || fail 'SUPER+Q does not close the window'
[[ "$(lines '^log ')" -eq 0 && "$(lines '^notify ')" -eq 0 ]] || fail "a missing local.lua was reported: $(grep -E '^(log|notify) ' <<<"$out")"
# The generated fragments ran: the NVIDIA environment of the desktop-nvidia facts.
has 'env GBM_BACKEND=nvidia-drm' || fail 'the hardware fragment was not loaded'
grep -q '^monitor .*scale = "' <<<"$out" || fail 'the monitors fragment was not loaded'
grep -q '^config .*kb_layout = "es"' <<<"$out" || fail 'the input fragment was not loaded'
has 'on hyprland.start' || fail 'no start handler registered'
has 'start exec waybar' || fail 'waybar is not started with the session'
# The shared-settings pull is the first autostart entry, but hl.exec_cmd starts
# every entry at once: nothing may claim, or depend on, the pull having finished
# before the bar starts (a changed theme reloads the bar itself, through apply-theme).
template="$repo_root/templates/hypr/.config/hypr/hyprland.lua.in"
grep -qiE 'comes first|is in place before' "$template" && fail 'the template still claims the pull finishes before the bar starts'
grep -q 'reloads' <(grep -B4 'id = "sync-shared"' "$template") || fail 'the template does not say why the start order does not matter'
# shellcheck disable=SC2016  # the ${...} is literal text the shell is meant to expand later
[[ "$(grep -m1 '^start exec' <<<"$out")" == 'start exec ${VIVAC_REPO:-$HOME/vivac}/scripts/sync-shared-settings.sh --pull' ]] ||
	fail "the first autostart entry is not the shared-settings pull: $(grep -m1 '^start exec' <<<"$out")"

# --- the checkout location reaches the programs the session starts -------------------------------------------
# The autostart pull expands ${VIVAC_REPO:-$HOME/vivac}. A checkout elsewhere is
# named in $XDG_CONFIG_HOME/vivac/repo (the host deploy writes it); without the
# file the environment is left alone.
[[ "$(lines '^env VIVAC_REPO=')" -eq 0 ]] || fail 'VIVAC_REPO was set without a repo file'
mkdir -p -- "$home/.config/vivac"
printf '/somewhere/else/vivac\n' >"$home/.config/vivac/repo"
load
has 'env VIVAC_REPO=/somewhere/else/vivac' || fail "the repo file did not reach the environment: $(grep '^env VIVAC' <<<"$out")"
: >"$home/.config/vivac/repo"
load
[[ "$(lines '^env VIVAC_REPO=')" -eq 0 ]] || fail 'an empty repo file set VIVAC_REPO'
rm -- "$home/.config/vivac/repo"
load

# --- the fragments run again on every load: the Lua state may persist across a reload -------------------------
load HL_STUB_RELOADS=2
[[ "$(lines '^env GBM_BACKEND=')" -eq 2 ]] || fail "a reload did not re-run the hardware fragment: $(lines '^env GBM_BACKEND=') runs"

# --- a broken local.lua is caught, reported, and the vivac config is intact -----------------------------------
printf 'error("owner mistake")\n' >"$hypr/local.lua"
load
grep -q '^log vivac: local.lua failed.*owner mistake' <<<"$out" || fail "a runtime error in local.lua was not logged: $out"
grep -q '^notify .*local.lua' <<<"$out" || fail 'a runtime error in local.lua raised no notification'
has "final $registry_rows" || fail 'a broken local.lua cost vivac binds'
has 'start exec waybar' || fail 'a broken local.lua stopped the autostart'
printf 'this is = not lua (\n' >"$hypr/local.lua"
load
grep -q '^log vivac: local.lua failed' <<<"$out" || fail "a syntax error in local.lua was not logged: $out"
has "final $registry_rows" || fail 'an unparsable local.lua cost vivac binds'
printf 'require("not_a_module")\n' >"$hypr/local.lua"
load
grep -q '^log vivac: local.lua failed.*not_a_module' <<<"$out" || fail 'a missing module inside local.lua was taken for a missing local.lua'

# Hyprland ships debug.disable_logs, so the print above reaches no log: the failure
# is also appended, with a timestamp, to $XDG_STATE_HOME/vivac/local-lua.log.
state="$sandbox/persist-state"
local_log="$state/vivac/local-lua.log"
printf 'error("owner mistake")\n' >"$hypr/local.lua"
load XDG_STATE_HOME="$state"
[[ -f "$local_log" ]] || fail 'a broken local.lua left no local-lua.log'
grep -Eq '^[0-9]{4}-[0-9]{2}-[0-9]{2}[T ][0-9:]{8}.* vivac: local.lua failed.*owner mistake' "$local_log" || fail "the log line has no timestamp or message: $(<"$local_log")"
has "final $registry_rows" || fail 'logging the failure cost vivac binds'
load XDG_STATE_HOME="$state"
[[ "$(wc -l <"$local_log")" -eq 2 ]] || fail 'the log is not appended to'
# A state directory that cannot be written never fails the config.
printf 'not a directory' >"$sandbox/blocked"
load XDG_STATE_HOME="$sandbox/blocked"
has "final $registry_rows" || fail 'an unwritable state directory cost vivac binds'
grep -q '^notify .*local.lua' <<<"$out" || fail 'the notification was lost when the log could not be written'
# No state variable: the default is under HOME/.local/state.
load XDG_STATE_HOME=
[[ -f "$home/.local/state/vivac/local-lua.log" ]] || fail 'the default state directory is not HOME/.local/state'
rm -rf -- "$home/.local/state"

# --- owner wins: hl.unbind, then rebind; the last chunk is local.lua --------------------------------------------
cat >"$hypr/local.lua" <<'LOCAL'
hl.unbind("SUPER + R")
hl.bind("SUPER + A", hl.dsp.exec_cmd("rofi -show drun"))
hl.config({ owner_marker = true })
LOCAL
load
has 'unbind SUPER + R' || fail 'local.lua could not unbind a vivac key'
has 'bind SUPER + A => exec_cmd(rofi -show drun)' || fail 'local.lua could not bind its own key'
has "final $registry_rows" || fail "relocating one key changed the bind count: $(grep '^final' <<<"$out")"
! grep -Fq 'bind SUPER + R =>' <<<"$(sed -n '/^unbind SUPER + R$/,$p' <<<"$out")" || fail 'SUPER+R was rebound by vivac after the owner unbound it'
unbind_line="$(grep -n '^unbind SUPER + R$' <<<"$out" | cut -d: -f1)"
final_line="$(grep -n '^final ' <<<"$out" | cut -d: -f1)"
# Everything from the owner's first statement to the end of the load is the owner's own.
owned="$(sed -n "$((unbind_line + 1)),$((final_line - 1))p" <<<"$out")"
[[ "$owned" == $'bind SUPER + A => exec_cmd(rofi -show drun)\nconfig { owner_marker = true }' ]] || fail "vivac configured something after local.lua started, or local.lua did not run: $owned"

# --- autostart: local.lua edits the list before the start event runs it ----------------------------------------
cat >"$hypr/local.lua" <<'LOCAL'
vivac.autostart_set("hypridle", false)
vivac.autostart_set("waybar", "waybar --config /owner/config")
vivac.autostart_set("owner-tool", "owner-tool --daemon")
LOCAL
load
has 'start exec hypridle' && fail 'autostart_set(id, false) did not remove the entry'
has 'start exec waybar --config /owner/config' || fail 'autostart_set(id, cmd) did not replace the entry'
has 'start exec waybar' && fail 'the replaced waybar entry still ran'
has 'start exec owner-tool --daemon' || fail 'autostart_set did not append a new entry'
order="$(grep '^start exec' <<<"$out")"
[[ "$(grep -n 'waybar --config' <<<"$order" | cut -d: -f1)" -lt "$(grep -n 'owner-tool' <<<"$order" | cut -d: -f1)" ]] || fail 'a new autostart entry did not go last'
[[ "$(grep -n 'waybar --config' <<<"$order" | cut -d: -f1)" -lt "$(grep -n 'wallpaper.sh' <<<"$order" | cut -d: -f1)" ]] || fail 'a replaced entry lost its place'

# --- the config directory follows XDG_CONFIG_HOME, and falls back to HOME/.config -----------------------------
rm -f -- "$hypr/local.lua"
out="$(env -u XDG_CONFIG_HOME HOME="$home" nvim -l "$stub" "$hypr/hyprland.lua" 2>"$sandbox/err")" || fail "no XDG_CONFIG_HOME: $(<"$sandbox/err")"
has 'env GBM_BACKEND=nvidia-drm' || fail 'without XDG_CONFIG_HOME the fragments were not found under HOME/.config'

printf 'hypr loader: %s binds, fragments re-run per load, broken local.lua contained, hl.unbind override, autostart edits\n' "$registry_rows"
