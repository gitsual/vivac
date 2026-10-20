#!/usr/bin/env bash
set -Eeuo pipefail

# The owner overlay. local.lua.example shows the relocation pattern: evaluated
# after the base it unbinds each displaced default key and binds the relocated
# one. The F1 pane reads "-- @help:" lines from the owner's local.lua and
# shows the relocated keys; an absent or unreadable local.lua means the
# registry defaults. The repo gate parses the example with the same parser.

repo_root="${REPO_ROOT:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)}"
example="$repo_root/dotfiles/hypr/.config/hypr/local.lua.example"
pane="$repo_root/dotfiles/hypr/.config/hypr/scripts/help-pane.sh"
stub="$repo_root/tests/lua/hl_stub.lua"
sandbox="$(mktemp -d "${TMPDIR:-/tmp}/vivac-overlay.XXXXXX")"
trap 'rm -rf -- "$sandbox"' EXIT

fail() {
	printf '%s\n' "$1" >&2
	exit 1
}

[[ -f "$example" ]] || fail "${example#"$repo_root"/} does not exist"
nvim -l /dev/stdin "$example" <<'LUA' || fail 'local.lua.example does not parse'
assert(loadfile(_G.arg[1]))
LUA

# default key -> relocated key, as the example documents them
declare -A moved=(
	['SUPER + R']='SUPER + A' ['SUPER + D']='SUPER + SHIFT + D' ['SUPER + L']='SUPER + SHIFT + L'
	['SUPER + SHIFT + Q']='SUPER + SHIFT + P' ['F2']='SUPER + F2'
)

# --- evaluated after the base: unbind, then bind the relocated key ---------------------------------------------
home="$sandbox/home"
mkdir -p -- "$home"
HOME="$home" XDG_CONFIG_HOME="$home/.config" XDG_STATE_HOME="$sandbox/state" \
	FACTS_FILE="$repo_root/tests/golden/desktop-nvidia/hardware-facts" FACTS_OVERRIDE="$sandbox/none" \
	bash "$repo_root/scripts/render-config.sh" --deploy >/dev/null || fail 'could not render the fragments'
hypr="$home/.config/hypr"
cp -- "$repo_root/dotfiles/hypr/.config/hypr/hyprland.lua" "$hypr/hyprland.lua"
cp -- "$example" "$hypr/local.lua"
out="$(env HOME="$home" XDG_CONFIG_HOME="$home/.config" nvim -l "$stub" "$hypr/hyprland.lua" 2>"$sandbox/err")" || fail "the config did not load: $(<"$sandbox/err")"
registry_rows="$(grep -c $'\thypr\t' "$repo_root/data/help-registry.tsv")"
grep -Fxq "final $registry_rows" <<<"$out" || fail "relocating must keep the bind count at $registry_rows: $(grep '^final' <<<"$out")"
! grep -Eq '^(log|notify) ' <<<"$out" || fail "the example overlay was reported as failing: $(grep -E '^(log|notify) ' <<<"$out")"
for from in "${!moved[@]}"; do
	to="${moved[$from]}"
	grep -Fxq "unbind $from" <<<"$out" || fail "the example does not unbind $from"
	base_line="$(grep -Fn "bind $from => " <<<"$out" | head -n 1)" || fail "the base does not bind $from"
	action="${base_line#*=> }"
	# the same program: the example keeps the command word, not the base's colour flags
	program="${action%% *}"
	grep -Fq "bind $to => $program" <<<"$out" || fail "the example does not rebind $program on $to"
	((${base_line%%:*} < $(grep -Fxn "unbind $from" <<<"$out" | head -n 1 | cut -d: -f1))) || fail "$from is unbound before the base binds it"
done
[[ "$(grep -c '^unbind ' <<<"$out")" -eq 5 ]] || fail 'the example must unbind exactly the five displaced keys'

# --- F1 shows the relocated keys ---------------------------------------------------------------------------------
# No session leaks in; the owner's file is the only extra input.
render() { env HYPRLAND_INSTANCE_SIGNATURE='' HELP_REPO_ROOT="$repo_root" "$@" bash "$pane" --pane hypr --lang en --plain; }
defaults="$(render HELP_LOCAL_LUA="$sandbox/absent.lua")"
shown="$(render HELP_LOCAL_LUA="$hypr/local.lua")"
for from in "${!moved[@]}"; do
	old="${from// /}"
	new="${moved[$from]// /}"
	grep -q "^$old"$'\t' <<<"$defaults" || fail "without local.lua the pane lost its default $old"
	grep -q "^$new"$'\t' <<<"$shown" || fail "the pane does not show the relocated key $new"
	! grep -q "^$old"$'\t' <<<"$shown" || fail "the pane still shows $old although local.lua moved it"
	# the description travels with the key
	[[ "$(grep "^$old"$'\t' <<<"$defaults" | cut -f2)" == "$(grep "^$new"$'\t' <<<"$shown" | cut -f2)" ]] || fail "the description of $old did not follow it to $new"
done
[[ "$(wc -l <<<"$shown")" -eq "$(wc -l <<<"$defaults")" ]] || fail 'relocating changed the number of rows'
# The same file found through XDG_CONFIG_HOME, with no override variable.
[[ "$(render XDG_CONFIG_HOME="$home/.config")" == "$shown" ]] || fail 'the pane did not find local.lua in the config directory'

# --- absent, unparsable, or not annotated the readable way: registry defaults -----------------------------------
check_defaults() {
	printf '%s' "$2" >"$sandbox/odd.lua"
	[[ "$(render HELP_LOCAL_LUA="$sandbox/odd.lua")" == "$defaults" ]] || fail "$1 changed the pane"
}
check_defaults 'an unparsable local.lua' $'this is = not lua (\n-- @help: hypr help.hypr.launcher\nhl.bind("SUPER + A", x'
check_defaults 'an annotation with a blank line before the bind' $'-- @help: hypr help.hypr.launcher\n\nhl.bind("SUPER + A", hl.dsp.exec_cmd("rofi"))\n'
check_defaults 'a built key' $'-- @help: hypr help.hypr.launcher\nhl.bind("SUPER + " .. "A", hl.dsp.exec_cmd("rofi"))\n'
check_defaults 'an indented bind' $'-- @help: hypr help.hypr.launcher\n  hl.bind("SUPER + A", hl.dsp.exec_cmd("rofi"))\n'
check_defaults 'a commented-out bind' $'-- @help: hypr help.hypr.launcher\n-- hl.bind("SUPER + A", hl.dsp.exec_cmd("rofi"))\n'
check_defaults 'a label the registry does not have' $'-- @help: hypr help.hypr.no_such_label\nhl.bind("SUPER + A", hl.dsp.exec_cmd("rofi"))\n'
check_defaults 'a key a vivac row already owns' $'-- @help: hypr help.hypr.launcher\nhl.bind("SUPER + D", hl.dsp.exec_cmd("rofi"))\n'
# ...while the same bind, annotated the readable way, does apply.
printf -- '-- @help: hypr help.hypr.launcher\nhl.bind("SUPER + CTRL + A", hl.dsp.exec_cmd("rofi"))\n' >"$sandbox/one.lua"
out="$(render HELP_LOCAL_LUA="$sandbox/one.lua")"
grep -q $'^SUPER+CTRL+A\tApplication launcher' <<<"$out" || fail "a single annotated bind was not applied: $out"
# A relocated row still acts on its registry action when picked (key rows follow the new id).
! grep -q $'^SUPER+R\t' <<<"$out" || fail 'the old key is still listed after the move'

# --- the repo gate reads the example with the same parser ----------------------------------------------------------
bash "$repo_root/scripts/check-help-registry.sh" >/dev/null 2>"$sandbox/err" || fail "the gate refused the shipped example: $(<"$sandbox/err")"
printf -- '-- @help: hypr help.hypr.no_such_label\nhl.bind("SUPER + A", hl.dsp.exec_cmd("rofi"))\n' >"$sandbox/bad-example.lua"
if HELP_LOCAL_EXAMPLE="$sandbox/bad-example.lua" bash "$repo_root/scripts/check-help-registry.sh" >/dev/null 2>"$sandbox/err"; then
	fail 'the gate accepted an example that annotates a label the registry lacks'
fi
grep -q 'help.hypr.no_such_label' "$sandbox/err" || fail "the gate did not name the label: $(<"$sandbox/err")"

printf 'local overlay: example parses, 5 keys relocated after the base, F1 follows them, odd local.lua keeps the defaults\n'
