#!/usr/bin/env bash
set -Eeuo pipefail

# apply-theme writes vivac's own renders over their Stow symlinks. A regular
# file at one of those paths is the owner's, and has to survive a theme switch:
# it gets the palette's colours through the colour overlay and nothing else,
# and choosing the default again gives back the original bytes.

repo_root="${REPO_ROOT:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)}"
apply="$repo_root/scripts/apply-theme.sh"
facts="$repo_root/tests/golden/vm-virtio/hardware-facts"
fail() {
	printf '%s\n' "$1" >&2
	exit 1
}

sandbox="$(mktemp -d "${TMPDIR:-/tmp}/vivac-owner.XXXXXX")"
trap 'rm -rf -- "$sandbox"' EXIT
mkdir -p "$sandbox/.config/waybar" "$sandbox/.config/kitty"
run() {
	HOME="$sandbox" XDG_CONFIG_HOME="$sandbox/.config" XDG_STATE_HOME="$sandbox/.state" \
		FACTS_FILE="$facts" FACTS_OVERRIDE="$sandbox/absent" \
		SETTINGS_FILE="$sandbox/.config/vivac/settings" "$apply" "$@" 2>"$sandbox/err"
}

tok() { sed -nE "s/^$2=(.*)$/\1/p" "$1"; }
bg="$(tok "$repo_root/data/theme.conf" COLOR_BG)" cbg="$(tok "$repo_root/data/themes/carmen.conf" COLOR_BG)"
tbg="$(tok "$repo_root/data/theme.conf" TERMINAL_BG)"
printf '/* owner layout */\nwindow#waybar { background: #%s; margin: 3px; }\n' "$bg" >"$sandbox/.config/waybar/style.css"
printf '# owner kitty\nbackground #%s\nfont_size 11\n' "$tbg" >"$sandbox/.config/kitty/kitty.conf"
cp -- "$sandbox/.config/waybar/style.css" "$sandbox/waybar.orig"
cp -- "$sandbox/.config/kitty/kitty.conf" "$sandbox/kitty.orig"

run --theme carmen --no-reload >/dev/null || fail 'apply-theme failed with owner files present'
for f in waybar/style.css kitty/kitty.conf; do
	[[ -f "$sandbox/.config/$f" && ! -L "$sandbox/.config/$f" ]] || fail "$f stopped being the owner's regular file"
	grep -qF -- "$(sed -n 1p "$sandbox/${f%%/*}.orig")" "$sandbox/.config/$f" || fail "$f lost the owner's own first line"
	grep -Fq -- "$sandbox/.config/$f" "$sandbox/.state/vivac/theme-overlay" && fail "$f was recorded as a vivac-owned overlay file"
done
grep -qiF "$cbg" "$sandbox/.config/waybar/style.css" || fail 'the colour overlay was not applied after the template loop'
grep -qF 'margin: 3px' "$sandbox/.config/waybar/style.css" || fail 'the owner layout was replaced'
grep -qF 'font_size 11' "$sandbox/.config/kitty/kitty.conf" || fail 'the owner kitty config was replaced by the render'
grep -qi 'waybar' "$sandbox/err" || fail 'overwriting an owner file was refused without a word'

# Other themes and the way back: the owner's bytes return untouched, and the
# files vivac does own still behave as before.
run --theme metropolis --no-reload >/dev/null || fail 'second switch failed'
run --theme bad-romance --no-reload >/dev/null || fail 'switch back to the default failed'
cmp -s "$sandbox/.config/waybar/style.css" "$sandbox/waybar.orig" || fail 'waybar is not byte-identical after returning to the default'
cmp -s "$sandbox/.config/kitty/kitty.conf" "$sandbox/kitty.orig" || fail 'kitty is not byte-identical after returning to the default'

printf 'apply-theme: owner files kept, recoloured, restored\n'
