#!/usr/bin/env bash
# The needles are the guest's own shell text, $HOME and $fragment included.
# shellcheck disable=SC2016
set -Eeuo pipefail

# The VM gate cannot run in check.sh, so what it asserts about the compositor
# config is pinned here: it verifies and inspects hyprland.lua and the Lua
# fragments (never the hyprlang ones), and it proves that a broken local.lua
# still verifies.

repo_root="${REPO_ROOT:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)}"
acceptance="$repo_root/tests/guest-acceptance.sh"

fail() {
	printf '%s\n' "$1" >&2
	exit 1
}
has() { grep -Fq -- "$1" "$acceptance"; }

has 'Hyprland --verify-config -c "$HOME/.config/hypr/hyprland.lua"' || fail 'the gate does not verify hyprland.lua'
grep -Eq 'hyprland\.conf|generated/[^ ]*\.conf|\$fragment\.conf' "$acceptance" && fail "the gate still reads a hyprlang compositor file: $(grep -En 'hyprland\.conf|generated/[^ ]*\.conf|\$fragment\.conf' "$acceptance")"
has 'generated/$fragment.lua' || fail 'the gate does not check the Lua fragments are real files'
has 'hl.env("QT_IM_MODULE", "fcitx")' || fail 'the input method is not checked in the Lua fragment'
has '{ id = "fcitx5", cmd = "fcitx5 -d" }' || fail 'the fcitx5 autostart entry is not checked'
has '{ id = "hypridle"' || fail 'hypridle is not checked as an autostart entry'
has 'kb_layout = "fr"' || fail 'the seeded layout is not checked in input.lua'
# A broken local.lua must not stop the config verifying, and must not stay behind.
has 'error("owner mistake")' || fail 'the gate has no broken local.lua case'
has 'rm -f "$HOME/.config/hypr/local.lua"' || fail 'the gate leaves the broken local.lua in the guest'

printf 'guest acceptance: verifies hyprland.lua, Lua fragments, autostart entries and a broken local.lua\n'
