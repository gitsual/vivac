#!/usr/bin/env bash
set -Eeuo pipefail

# Choosing a theme is a thing the desktop does, not a command someone has to
# remember: a bind, a button on the bar, and a row in the help pane, all
# reaching the one script that applies a palette everywhere.

repo_root="${REPO_ROOT:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)}"
picker="$repo_root/dotfiles/ricer/.local/bin/vivac-theme"
template="$repo_root/templates/hypr/.config/hypr/hyprland.lua.in"
bar="$repo_root/render/waybar/config.in"

fail() {
	printf '%s\n' "$1" >&2
	exit 1
}
[[ -x "$picker" ]] || fail 'the theme picker is missing or not executable'

# shellcheck disable=SC2016  # the literal $HOME is what the template says
grep -Fq 'hl.bind("SUPER + SHIFT + T", hl.dsp.exec_cmd("$HOME/.local/bin/vivac-theme"))' "$template" ||
	fail 'the theme picker has no key'
grep -Fq 'SUPER+SHIFT+T	hypr	exec' "$repo_root/data/help-registry.tsv" ||
	fail 'the theme picker is not in the help registry, so the help pane never mentions it'
grep -Fq 'custom/theme' "$bar" || fail 'the bar has no theme button'
grep -Fq 'vivac-theme' "$bar" || fail 'the bar theme button reaches nothing'
grep -Fq '#custom-theme' "$repo_root/templates/waybar/.config/waybar/style.css.in" ||
	fail 'the bar theme button carries no palette of its own'

# The catalogue is read, never copied: the picker offers exactly what the
# wizard offers, which is exactly what ships.
# The last row makes a new palette from a picture; a scratch config home keeps
# any palette already made on this machine out of the count.
scratch="$(mktemp -d)"
trap 'rm -rf -- "$scratch"' EXIT
mapfile -t offered < <(VIVAC_REPO="$repo_root" VIVAC_LANG=en XDG_CONFIG_HOME="$scratch" SETTINGS_FILE="$scratch/settings" "$picker" --print)
count=$(($(find "$repo_root/data/themes" -name '*.conf' -type f | wc -l) + 1))
((${#offered[@]} == count + 1)) ||
	fail "the picker offers ${#offered[@]} rows and the catalogue holds $count themes, plus one to make a palette"
[[ "${offered[-1]}" == 'From a picture'* ]] || fail 'the last row does not make a palette from a picture'
for row in "${offered[@]}"; do
	[[ "$row" == *' — '* ]] || fail "a row says nothing about the theme it offers: $row"
done

# The row that comes back is a position, never a label: the titles are prose
# and one of them already contains the separator the menu prints.
grep -Fq -- '-format i' "$picker" || fail 'the picker reads a label back instead of a position'
grep -Fq 'apply-theme.sh" --theme' "$picker" ||
	fail 'the picker does not delegate to the one script that applies a palette'

printf 'theme picker: %d themes, bound, on the bar, in the help registry\n' "${#offered[@]}"
