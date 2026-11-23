#!/usr/bin/env bash
set -Eeuo pipefail

# vivac-panel theme, without a screen: the grid lists the catalogue in
# lib/themes.sh order with the title and essence each palette writes for
# itself and five real colours, marks the worn one, applies through
# scripts/apply-theme.sh and makes a palette from a picture through
# vivac-theme from-image. Nothing is invented: a palette that is missing a
# colour falls back to the theme default.

repo_root="${REPO_ROOT:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)}"
fail() { printf '%s\n' "$1" >&2; exit 1; }
sandbox="$(mktemp -d "${TMPDIR:-/tmp}/vivac-theme.XXXXXX")"
trap 'rm -rf -- "$sandbox"' EXIT
export HOME="$sandbox/home" XDG_CONFIG_HOME="$sandbox/home/.config" XDG_DATA_HOME="$sandbox/home/.local/share" VIVAC_LANG=en
mkdir -p "$XDG_CONFIG_HOME/vivac"
printf 'theme=metropolis\n' >"$XDG_CONFIG_HOME/vivac/settings"

py() { /usr/bin/python3 -I -c "import sys; sys.path.insert(0, '$repo_root/lib'); from vivacpanel import theme; $1"; }

names="$(py 'print(",".join(t.name for t in theme.themes()))')"
expected="$(bash -c "source '$repo_root/lib/kv.sh'; source '$repo_root/lib/themes.sh'; theme_catalogue '$repo_root'" | paste -sd,)"
[[ "$names" == "$expected" ]] || fail "catalogue order: $names vs $expected"

out="$(py 't = {x.name: x for x in theme.themes()}["metropolis"]; print(t.title, t.essence, len(t.colours), t.colours[0])')"
[[ "$out" == "Metropolis Resistance 5 #AAA875" ]] || fail "metropolis card: $out"

[[ "$(py 'print(theme.current())')" == metropolis ]] || fail "current theme"
out="$(py 'print(theme.apply_command("cosmos"))')"
[[ "$out" == "['$repo_root/scripts/apply-theme.sh', '--theme', 'cosmos']" ]] || fail "apply: $out"
out="$(py 'print(theme.picture_command("/x/a.png"))')"
[[ "$out" == *"vivac-theme', 'from-image', '/x/a.png', '--apply']" ]] || fail "from-image: $out"
out="$(py 'print(theme.step(0, 4, 8), theme.step(7, 4, 8), theme.step(3, 1, 8), theme.step(3, -4, 8))')"
[[ "$out" == "4 7 4 0" ]] || fail "movement: $out"
printf 'theme panel: catalogue, card data, current theme, apply, from-image and movement\n'
