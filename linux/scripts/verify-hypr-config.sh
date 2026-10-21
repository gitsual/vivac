#!/usr/bin/env bash
# Ask Hyprland itself whether the committed hyprland.lua loads.
#
# The config is staged the way a session sees it: a scratch config directory
# holding hyprland.lua and the generated Lua fragments rendered from fixture
# hardware facts. Hyprland --verify-config then runs the whole file, so a
# misspelt key, a bind it cannot parse or an hl.dsp function that does not
# exist fails here instead of in a user's session. Cases:
#   - every hardware archetype, with no local.lua;
#   - a local.lua that raises and one that does not parse: the vivac config must
#     still verify, because the loader contains the owner's mistakes;
#   - an owner-style local.lua that unbinds vivac keys and binds others;
#   - the shipped local.lua.example, as the owner would copy it.
# Without Hyprland the stage prints a notice and passes.
#
# HYPRLAND_BIN names the binary (tests use a stub); HYPR_LUA the file to verify.
set -Eeuo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
hyprland="${HYPRLAND_BIN:-Hyprland}"
config="${HYPR_LUA:-$repo_root/dotfiles/hypr/.config/hypr/hyprland.lua}"

if ! command -v "$hyprland" >/dev/null; then
	printf 'hyprland verify: %s not installed; skipped\n' "$hyprland"
	printf '%s\n' \
		'!!! WARNING: hyprland.lua and every generated config are NOT VERIFIED on this machine.' \
		'!!! A passing check.sh here proves nothing about whether Hyprland loads them.' \
		'!!! Run the VM gate (scripts/test-vm.sh) or install Hyprland and run this stage again.'
	exit 0
fi

sandbox="$(mktemp -d "${TMPDIR:-/tmp}/vivac-hypr-verify.XXXXXX")"
trap 'rm -rf -- "$sandbox"' EXIT
runtime="$sandbox/run"
mkdir -m 700 -- "$runtime"

status=0
count=0

# verify NAME ARCHETYPE [LOCAL_LUA_TEXT]
verify() {
	local name="$1" archetype="$2" home="$sandbox/$1" output
	mkdir -p -- "$home"
	HOME="$home" XDG_CONFIG_HOME="$home/.config" XDG_STATE_HOME="$home/.state" \
		FACTS_FILE="$repo_root/tests/golden/$archetype/hardware-facts" FACTS_OVERRIDE="$sandbox/none" \
		"$repo_root/scripts/render-config.sh" --deploy >/dev/null
	cp -- "$config" "$home/.config/hypr/hyprland.lua"
	if (($# > 2)); then
		printf '%s\n' "$3" >"$home/.config/hypr/local.lua"
	fi
	count=$((count + 1))
	if ! output="$(HOME="$home" XDG_CONFIG_HOME="$home/.config" XDG_RUNTIME_DIR="$runtime" \
		"$hyprland" --verify-config -c "$home/.config/hypr/hyprland.lua" 2>&1)"; then
		printf 'hyprland verify: %s refused:\n%s\n' "$name" "${output#*Config parsing result:}" >&2
		status=1
	fi
}

for archetype in desktop-nvidia laptop-amd-hybrid laptop-intel vm-virtio headless-unknown; do
	verify "$archetype" "$archetype"
done
verify broken-runtime desktop-nvidia 'error("owner mistake")'
verify broken-syntax desktop-nvidia 'this is = not lua ('
verify owner-override desktop-nvidia 'hl.unbind("SUPER + R")
hl.bind("SUPER + A", hl.dsp.exec_cmd("rofi -show drun"))
hl.unbind("F2")
hl.bind("SUPER + F2", hl.dsp.exec_cmd(vivac.scripts .. "/help-pane.sh --pane browser"))
vivac.autostart_set("hypridle", false)'
verify example-overlay desktop-nvidia "$(<"$repo_root/dotfiles/hypr/.config/hypr/local.lua.example")"

((status == 0)) || exit 1
printf 'hyprland verify: %d configs accepted\n' "$count"
