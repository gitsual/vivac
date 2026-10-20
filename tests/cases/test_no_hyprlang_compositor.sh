#!/usr/bin/env bash
set -Eeuo pipefail

# The compositor is configured in Lua only. No Hyprlang compositor file may
# come back: not the template, not its committed render, not a generated
# fragment, and nothing may read one. hyprlock, hyprpaper and hypridle are
# separate programs with their own Hyprlang files and stay as they are.

repo_root="${REPO_ROOT:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)}"
cd "$repo_root"

fail() {
	printf '%s\n' "$1" >&2
	exit 1
}

for gone in templates/hypr/.config/hypr/hyprland.conf.in dotfiles/hypr/.config/hypr/hyprland.conf; do
	[[ ! -e "$gone" ]] || fail "$gone is still in the tree"
done
leftover="$(find render/hypr/generated -type f -name '*.conf.in' 2>/dev/null || true)"
[[ -z "$leftover" ]] || fail "Hyprlang fragments are still in the tree: $leftover"

for kept in templates/hypr/.config/hypr/hyprlock.conf.in dotfiles/hypr/.config/hypr/hyprlock.conf \
	dotfiles/hypr/.config/hypr/hyprpaper.conf dotfiles/hypr/.config/hypr/hypridle.conf \
	templates/hypr/.config/hypr/hyprland.lua.in dotfiles/hypr/.config/hypr/hyprland.lua; do
	[[ -f "$kept" ]] || fail "$kept must stay"
done

# Nothing reads a compositor .conf any more. The pattern is built in pieces so
# this file does not match itself.
pattern='hyprland\.conf|generated/(hardware|input|monitors)\.conf|(hardware|input|monitors)\.conf\.in'
hits="$(git ls-files -z | grep -zv -e '^tests/golden/' -e '^tests/cases/test_no_hyprlang_compositor.sh$' | xargs -0 grep -nIE "$pattern" -- 2>/dev/null || true)"
[[ -z "$hits" ]] || fail "references to the Hyprlang compositor config remain:
$hits"

printf 'no Hyprlang compositor files or references; hyprlock, hyprpaper and hypridle kept\n'
