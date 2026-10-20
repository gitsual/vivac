#!/usr/bin/env bash
set -Eeuo pipefail

# The Hyprland fragments carry only what the machine has: NVIDIA environment
# on a sole-NVIDIA desktop and nowhere else, a touchpad block on laptops, a
# software cursor on VMs and NVIDIA, the monitor scale from the facts.

repo_root="${REPO_ROOT:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)}"
renderer="$repo_root/scripts/render-config.sh"

sandbox="$(mktemp -d "${TMPDIR:-/tmp}/vivac-hypr.XXXXXX")"
trap 'rm -rf -- "$sandbox"' EXIT

fail() {
	printf '%s\n' "$1" >&2
	exit 1
}

render() {
	local archetype="$1" home="$sandbox/$1"
	mkdir -p -- "$home"
	HOME="$home" XDG_CONFIG_HOME="$home/.config" XDG_STATE_HOME="$home/.state" \
		FACTS_FILE="$repo_root/tests/golden/$archetype/hardware-facts" FACTS_OVERRIDE="$sandbox/none" \
		bash "$renderer" --deploy >/dev/null || fail "render failed for $archetype"
	printf '%s' "$home/.config/hypr/generated"
}

# lua_run DIR LABEL — run the three Lua fragments, leave the recording in $lua.
lua_run() {
	local dir="$1" label="$2" fragment
	for fragment in hardware input monitors; do
		[[ -f "$dir/$fragment.lua" ]] || fail "$label: $fragment.lua was not rendered"
		# Lua modules, not hyprlang: no `key = value` or `env =` at line start.
		grep -Eq '^[[:space:]]*[A-Za-z_][A-Za-z0-9_.-]*[[:space:]]*=' "$dir/$fragment.lua" && fail "$label: $fragment.lua carries hyprlang syntax"
	done
	lua="$(nvim -l "$repo_root/tests/lua/run_fragments.lua" "$dir/hardware.lua" "$dir/monitors.lua" "$dir/input.lua")" || fail "$label: the lua fragments do not run"
}
count_lua() { grep -Eic -- "$1" <<<"$lua" || true; }

count() { grep -c -- "$2" "$1" || true; }

for archetype in desktop-nvidia laptop-amd-hybrid laptop-intel vm-virtio headless-unknown; do
	out="$(render "$archetype")"
	hardware="$out/hardware.conf"
	input="$out/input.conf"
	monitors="$out/monitors.conf"

	nvidia="$(grep -ci '^env = .*nvidia' "$hardware" || true)"
	cursor="$(count "$hardware" 'no_hardware_cursors')"
	touchpad="$(count "$input" 'touchpad {')"
	case "$archetype" in
	desktop-nvidia) want_nvidia=4 want_cursor=1 want_touchpad=0 ;;
	laptop-amd-hybrid) want_nvidia=0 want_cursor=0 want_touchpad=1 ;;
	laptop-intel) want_nvidia=0 want_cursor=0 want_touchpad=1 ;;
	vm-virtio) want_nvidia=0 want_cursor=1 want_touchpad=0 ;;
	headless-unknown) want_nvidia=0 want_cursor=0 want_touchpad=0 ;;
	esac
	[[ "$nvidia" -eq "$want_nvidia" ]] || fail "$archetype: $nvidia nvidia lines, expected $want_nvidia"
	[[ "$cursor" -eq "$want_cursor" ]] || fail "$archetype: $cursor cursor lines, expected $want_cursor"
	[[ "$touchpad" -eq "$want_touchpad" ]] || fail "$archetype: $touchpad touchpad blocks, expected $want_touchpad"

	# No other vendor's configuration exists to leak; assert it stays that way.
	grep -Eiq 'amd|radeon|intel|i915' "$hardware" && fail "$archetype: another vendor's lines in hardware.conf"

	scale="$(grep -Eo 'auto, [0-9.]+$' "$monitors" | cut -d' ' -f2)"
	[[ "$scale" == "$(grep '^max_scale=' "$repo_root/tests/golden/$archetype/hardware-facts" | cut -d= -f2)" ]] || fail "$archetype: monitor scale $scale does not match the facts"

	# Guards are consumed, never rendered.
	grep -q '@?' "$hardware" "$input" "$monitors" && fail "$archetype: a guard survived rendering"

	# The Lua fragments sit beside them and say the same thing. They are run
	# against a recording `hl`, so a fragment that parses but asks for the
	# wrong thing fails here too.
	lua_run "$out" "$archetype"
	[[ "$(count_lua '^env .*nvidia')" -eq "$want_nvidia" ]] || fail "$archetype: lua fragments set $(count_lua '^env .*nvidia') nvidia variables, expected $want_nvidia"
	[[ "$(count_lua 'no_hardware_cursors = true')" -eq "$want_cursor" ]] || fail "$archetype: lua software-cursor lines differ from $want_cursor"
	[[ "$(count_lua 'touchpad = ')" -eq "$want_touchpad" ]] || fail "$archetype: lua touchpad blocks differ from $want_touchpad"
	grep -Fq "scale = \"$(grep '^max_scale=' "$repo_root/tests/golden/$archetype/hardware-facts" | cut -d= -f2)\"" <<<"$lua" || fail "$archetype: lua monitor scale does not match the facts"
	grep -Fq 'kb_layout = "es"' <<<"$lua" || fail "$archetype: lua input does not carry the layout"
	[[ "$(count_lua '^autostart')" -eq 0 ]] || fail "$archetype: a daemon starts without the ime setting"
	grep -Eiq 'amd|radeon|intel|i915' "$out/hardware.lua" && fail "$archetype: another vendor's lines in hardware.lua"
done

# A non-default layout and ime=fcitx5: the layout is the setting's, and fcitx5 adds three variables and one autostart entry, and nothing else.
mkdir -p -- "$sandbox/ime"
printf 'ime=fcitx5\nxkb_layout=us,es\n' >"$sandbox/ime.settings"
HOME="$sandbox/ime" XDG_CONFIG_HOME="$sandbox/ime/.config" XDG_STATE_HOME="$sandbox/ime/.state" SETTINGS_FILE="$sandbox/ime.settings" \
	FACTS_FILE="$repo_root/tests/golden/laptop-intel/hardware-facts" FACTS_OVERRIDE="$sandbox/none" \
	bash "$renderer" --deploy >/dev/null || fail 'render with ime=fcitx5 failed'
lua_run "$sandbox/ime/.config/hypr/generated" ime
[[ "$(count_lua '^env (QT_IM_MODULE|XMODIFIERS|SDL_IM_MODULE)=')" -eq 3 ]] || fail 'ime=fcitx5: expected three input-method variables'
grep -Fq 'kb_layout = "us,es"' <<<"$lua" || fail "layout: the setting did not reach input.lua: $lua"
grep -Fxq 'autostart fcitx5=fcitx5 -d' <<<"$lua" || fail "ime=fcitx5: no autostart entry: $lua"

# The committed hyprland.conf sources exactly the three generated fragments
# and defines nothing they own.
committed="$repo_root/dotfiles/hypr/.config/hypr/hyprland.conf"
for fragment in hardware monitors input; do
	grep -Fxq "source = ~/.config/hypr/generated/$fragment.conf" "$committed" || fail "hyprland.conf does not source $fragment.conf"
done
grep -Eq '^(monitor|input|env = (LIBVA|GBM|__GLX|NVIDIA))' "$committed" && fail 'hyprland.conf still carries machine-specific configuration'

# --- the Lua template and its committed render --------------------------------------------------------------
template="$repo_root/templates/hypr/.config/hypr/hyprland.lua.in"
lua_committed="$repo_root/dotfiles/hypr/.config/hypr/hyprland.lua"
[[ -f "$template" && -f "$lua_committed" ]] || fail 'hyprland.lua.in or its committed render is missing'
printf 'local chunk, err = loadfile(_G.arg[1])\nif not chunk then io.stderr:write(err, "\\n") os.exit(1) end\n' >"$sandbox/parse.lua"
nvim -l "$sandbox/parse.lua" "$lua_committed" || fail 'the committed hyprland.lua does not parse'
grep -Eq '@[A-Z][A-Z0-9_]*(:[a-z]+)?@' "$lua_committed" && fail 'the committed hyprland.lua still has a placeholder'
grep -Fq "rgb($(grep '^COLOR_ACCENT=' "$repo_root/data/theme.conf" | cut -d= -f2))" "$lua_committed" || fail 'the border does not wear the theme accent'

# The five keys the base keeps (the owner relocates them in local.lua, not here).
for default in 'SUPER + R:rofi -show drun' 'SUPER + D:dmenu_run' 'SUPER + L:hyprlock' 'SUPER + SHIFT + Q:vivac-power' 'F2:--pane browser'; do
	grep -F -- "hl.bind(\"${default%%:*}\"," "$lua_committed" | grep -Fq -- "${default#*:}" || fail "default key ${default%%:*} is not bound to ${default#*:}"
done

# No key twice: the second bind would shadow or double the first.
twice="$(sed -n 's/^hl\.bind("\([^"]*\)",.*/\1/p' "$lua_committed" | LC_ALL=C sort | uniq -d)"
[[ -z "$twice" ]] || fail "keys bound more than once: $twice"

# Drift: the committed render is the template rendered with the theme.
scratch="$sandbox/drift"
mkdir -p -- "$scratch"
(cd "$repo_root" && RENDER_ROOT="$scratch" bash scripts/check-theme-drift.sh --render >/dev/null)
cmp -s "$scratch/dotfiles/hypr/.config/hypr/hyprland.lua" "$lua_committed" || fail 'hyprland.lua drifted from its template'

printf 'hypr: generated fragments verified on 5 archetypes, hyprland.lua keeps the five default keys\n'
