#!/usr/bin/env bash
set -Eeuo pipefail

# The ricing tools are one selector with one manifest, all from the official
# repositories: packages/aur.txt stays empty, wlogout is never installed or
# referenced, nwg-bar sits beside the rofi power menu rather than replacing
# it, its stylesheet is rendered from the palette, and hypridle's config
# carries the three stages.

repo_root="${REPO_ROOT:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)}"
template="$repo_root/templates/hypr/.config/hypr/hyprland.conf.in"

fail() {
	printf '%s\n' "$1" >&2
	exit 1
}
grep -Eq '^[^#[:space:]]' "$repo_root/packages/aur.txt" && fail 'packages/aur.txt is not empty'
grep -rIl --exclude-dir=.git --exclude-dir=.vm-test --exclude-dir=tests --exclude=README.md 'wlogout' "$repo_root" && fail 'wlogout is referenced'
LC_ALL=C sort -cu "$repo_root/packages/ricer.txt" || fail 'packages/ricer.txt is not sorted unique'
for package in cliphist nwg-bar nwg-look qt6ct kvantum swappy wf-recorder; do
	grep -Fxq -- "$package" "$repo_root/packages/ricer.txt" || fail "$package missing from the ricer manifest"
done
grep -Fxq hypridle "$repo_root/packages/pacman.txt" || fail 'hypridle is not in the base manifest'

# --- beside, not instead: both power menus are bound, the rofi one to its own script -------------------
# shellcheck disable=SC2016  # the literal $HOME is what the template says
grep -Fxq 'bind = SUPER SHIFT, E, exec, $HOME/.config/rofi/power/powermenu.sh' "$template" || fail 'the rofi power menu bind changed'
# shellcheck disable=SC2016  # the literal $HOME is what the template says
grep -Fxq 'bind = SUPER SHIFT, Q, exec, $HOME/.local/bin/vivac-power' "$template" || fail 'the graphical power menu is not bound'

# Both menus are generated from the same table, in the session's language, and
# neither decides what to run by reading a label back. The old rofi script
# matched the selection against the English string it had printed, so it could
# not be translated without silently doing nothing.
rofi_menu="$repo_root/dotfiles/rofi/.config/rofi/power/powermenu.sh"
generator="$repo_root/dotfiles/ricer/.local/bin/vivac-power"
[[ -x "$generator" ]] || fail 'the graphical power menu has no generator'
for script in "$rofi_menu" "$generator"; do
	grep -Fq 'i18n_load' "$script" || fail "$(basename -- "$script") does not read the translation tables"
	grep -Fq 'power.poweroff' "$script" || fail "$(basename -- "$script") lost an entry"
done
# shellcheck disable=SC2016  # the pattern is literal shell source to search for
grep -Eq 'case "\$chosen"|\$chosen\)' "$rofi_menu" &&
	fail 'the rofi power menu still branches on the label it printed'

# Every entry names an icon the repository renders itself. The shipped icon
# themes carry these names only at 16-24px with Type=Fixed and inherit from
# themes that are not installed, so two of the five came out as a smudge and
# the other three were borrowed from a different theme.
for icon in lock suspend log-out reboot power-off; do
	[[ -f "$repo_root/templates/ricer/.config/nwg-bar/icons/$icon.svg.in" ]] ||
		fail "the power menu icon $icon is not a palette template"
	grep -Fq "#@COLOR_FG@" "$repo_root/templates/ricer/.config/nwg-bar/icons/$icon.svg.in" ||
		fail "the power menu icon $icon does not follow the palette"
	grep -Fq "$icon" "$generator" || fail "the generated menu never shows the $icon icon"
done

# ...and the menu hands GTK a raster, not the SVG. librsvg stopped shipping a
# gdk-pixbuf loader, so a GTK program given an .svg path reports that it cannot
# recognise the image format, which is what nwg-bar did for all five.
grep -Fq 'rsvg-convert' "$generator" || fail 'the power menu never rasterizes its icons'
grep -Fq '.svg"}' "$generator" && fail 'the power menu hands GTK an SVG path, which gdk-pixbuf cannot open'
grep -Fq 'vivac-power" --icons' "$rofi_menu" ||
	fail 'the keyboard menu rasterizes its own icons instead of sharing one rasterizer'

sandbox="$(mktemp -d "${TMPDIR:-/tmp}/vivac-power.XXXXXX")"
trap 'rm -rf -- "$sandbox"' EXIT
VIVAC_REPO="$repo_root" HOME="$repo_root/dotfiles/ricer" XDG_RUNTIME_DIR="$sandbox" \
	"$generator" --icons >/dev/null || fail 'the power menu cannot rasterize its icons'
for icon in lock suspend log-out reboot power-off; do
	[[ -s "$sandbox/vivac/icons/$icon.png" ]] || fail "rasterizing produced no $icon.png"
done

labels="$(VIVAC_REPO="$repo_root" HOME="$repo_root" "$generator" --lang es --print)"
python3 -c '
import json, sys
bar = json.loads(sys.stdin.read())
assert len(bar) == 5, bar
assert all(b["exec"] for b in bar), bar
assert all(b["icon"].endswith(".png") for b in bar), bar
assert not any(b["label"].startswith("[") for b in bar), bar
' <<<"$labels" || fail 'the generated power menu is not five working entries in Spanish'

[[ -f "$repo_root/templates/ricer/.config/nwg-bar/style.css.in" ]] || fail 'the nwg-bar stylesheet is not a palette template'
grep -Eq '#[0-9A-F]{6}' "$repo_root/dotfiles/ricer/.config/nwg-bar/style.css" || fail 'the rendered nwg-bar stylesheet carries no colour'

# --- hypridle: started with the session, three stages in order ----------------------------------------------
grep -Fxq 'exec-once = hypridle' "$template" || fail 'hypridle is not started with the session'
mapfile -t timeouts < <(awk '/^[[:space:]]*timeout =/ { print $3 }' "$repo_root/dotfiles/hypr/.config/hypr/hypridle.conf")
[[ "${timeouts[*]}" == '300 600 1800' ]] || fail "hypridle stages are not lock, screen off, suspend in order: ${timeouts[*]}"
grep -q 'lock_cmd' "$repo_root/dotfiles/hypr/.config/hypr/hypridle.conf" || fail 'hypridle has no lock command'

# --- the selector adds exactly its manifest ---------------------------------------------------------------------
listing() {
	SYSROOT="$repo_root/tests/fixtures/laptop-intel/sysroot" LSPCI_CMD=false PACMAN_CMD=false \
		bash "$repo_root/scripts/bootstrap.sh" --dry-run "$@" 2>/dev/null | grep '^would install official packages' || true
}
base="$(listing)"
with="$(listing --ricer)"
extra="$(LC_ALL=C comm -13 <(tr ' ' '\n' <<<"${base#*: }" | LC_ALL=C sort) <(tr ' ' '\n' <<<"${with#*: }" | LC_ALL=C sort))"
[[ "$extra" == "$(<"$repo_root/packages/ricer.txt")" ]] || fail "--ricer added something outside its manifest: $extra"
grep -Eq 'nwg-bar|cliphist' <<<"$base" && fail 'the default bootstrap installs ricing tools'

printf 'ricer: official repos only, no wlogout, nwg-bar beside rofi, hypridle staged, selector adds its manifest\n'
