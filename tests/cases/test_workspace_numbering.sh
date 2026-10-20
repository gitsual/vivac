#!/usr/bin/env bash
set -Eeuo pipefail

# Workspaces are numbered 1 to 10, bound to the digit keys with 0 as 10, in
# numeric order, with a wraparound pair and no special workspace in the
# sequence. Waybar shows all ten through custom/ws (signal-driven, never
# polled) on one or two monitors alike, and the strip is never blank.

repo_root="${REPO_ROOT:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)}"
template="$repo_root/templates/hypr/.config/hypr/hyprland.lua.in"
sandbox="$(mktemp -d "${TMPDIR:-/tmp}/vivac-ws.XXXXXX")"
trap 'rm -rf -- "$sandbox"' EXIT

fail() {
	printf '%s\n' "$1" >&2
	exit 1
}

# --- binds: 1..9 then 0 -> 10, in that order, for both switch and move ------------------------
for dispatcher in workspace movetoworkspace; do
	dsp=hl\\.dsp\\.focus; [[ "$dispatcher" == workspace ]] || dsp=hl\\.dsp\\.window\\.move
	mapfile -t targets < <(sed -nE "s/^hl\.bind\(\"SUPER( \+ SHIFT)? \+ [0-9]\", $dsp\(\{ workspace = ([0-9]+) \}\)\)\$/\2/p" "$template")
	[[ "${targets[*]}" == '1 2 3 4 5 6 7 8 9 10' ]] || fail "$dispatcher binds are not 1..10 in order: ${targets[*]}"
	[[ "$(sed -nE "s/^hl\.bind\(\"SUPER( \+ SHIFT)? \+ 0\", $dsp\(\{ workspace = ([0-9]+) \}\)\)\$/\2/p" "$template" | LC_ALL=C sort -u | tr '\n' ' ')" == '10 ' ]] || fail "$dispatcher: 0 does not map to 10"
done
grep -Fq 'hl.bind("SUPER + bracketright", hl.dsp.focus({ workspace = "e+1" }))' "$template" || fail 'no wraparound forward bind'
grep -Fq 'hl.bind("SUPER + bracketleft", hl.dsp.focus({ workspace = "e-1" }))' "$template" || fail 'no wraparound backward bind'
grep -E 'hl\.bind\("SUPER( \+ SHIFT)? \+ [0-9]".*workspace = "special' "$template" && fail 'a digit key targets a special workspace'
# shellcheck disable=SC2016  # the literal $HOME is what the template says
grep -Fq '{ id = "ws-refresh", cmd = "$HOME/.config/waybar/scripts/ws-refresh.sh" }' "$template" || fail 'the workspace listener is not started with the session'

# --- Waybar: custom/ws replaces the built-in module, on 1 and 2 monitors alike --------------------
for archetype in vm-virtio laptop-amd-hybrid; do
	home="$sandbox/$archetype"
	mkdir -p -- "$home"
	HOME="$home" XDG_CONFIG_HOME="$home/.config" XDG_STATE_HOME="$sandbox/state-$archetype" \
		FACTS_FILE="$repo_root/tests/golden/$archetype/hardware-facts" FACTS_OVERRIDE="$sandbox/none" \
		bash "$repo_root/scripts/render-config.sh" --deploy >/dev/null || fail "$archetype: render failed"
	python3 - "$home/.config/waybar/config" "$archetype" <<'PY' || exit 1
import json, sys
config = json.load(open(sys.argv[1]))
problems = []
if "hyprland/workspaces" in config or "hyprland/workspaces" in config["modules-left"]: problems.append("the built-in workspaces module is still there")
ws = config.get("custom/ws")
if ws is None or "custom/ws" not in config["modules-left"]: problems.append("custom/ws is not on the bar")
elif ws.get("return-type") != "json" or "signal" not in ws or "interval" in ws: problems.append("custom/ws would poll or ignore the signal")
if problems:
    print(sys.argv[2] + ": " + "; ".join(problems), file=sys.stderr); sys.exit(1)
PY
done

# --- the strip is never blank: ten numbers with no cache, ten with an empty one ---------------------------
render="$repo_root/dotfiles/waybar/.config/waybar/scripts/ws-render.sh"
icons="$repo_root/dotfiles/waybar/.config/waybar/workspace-icons.json"
text="$(WS_CACHE="$sandbox/no-cache" WS_ICONS="$icons" bash "$render" | jq -r .text)"
[[ "$text" == '1  2  3  4  5  6  7  8  9  10' ]] || fail "empty strip is not ten numbers: $text"
printf '{"active": 7, "workspaces": []}\n' >"$sandbox/cache"
# shellcheck disable=SC2001
text="$(WS_CACHE="$sandbox/cache" WS_ICONS="$icons" bash "$render" | jq -r .text | sed 's/<[^>]*>//g')"
[[ "$text" == '1  2  3  4  5  6  7  8  9  10' ]] || fail "strip with a cache is not ten numbers: $text"

# --- active and urgent are told apart without relying on colour --------------------------------------
css="$repo_root/dotfiles/waybar/.config/waybar/style.css"
grep -q '^#custom-ws\.urgent ' "$css" || fail 'no style for an urgent strip'
grep -q 'underline=' "$render" || fail 'the active workspace is not marked independently of colour'
grep -q 'italic' "$render" || fail 'an urgent workspace is not marked independently of colour'

printf 'workspace numbering: 1..10 with 0 as 10, wraparound, custom/ws on 1 and 2 monitors, never blank\n'
