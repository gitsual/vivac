#!/usr/bin/env bash
# Print the palette the session is wearing, in that palette.
#
# Every colour on the card is read from the same theme file the desktop is
# rendered from, so the card cannot claim a colour the desktop is not using --
# which is the only reason it is worth putting in a screenshot at all.
set -Eeuo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
# shellcheck source=lib/kv.sh
source "$repo_root/lib/kv.sh"
# shellcheck source=lib/settings.sh
source "$repo_root/lib/settings.sh"

settings_file="${SETTINGS_FILE:-${XDG_CONFIG_HOME:-$HOME/.config}/vivac/settings}"
theme='bad-romance'
[[ -f "$settings_file" ]] && {
	settings_load "$settings_file"
	theme="${SETTINGS[theme]:-$theme}"
}
theme_file="$repo_root/data/theme.conf"
[[ "$theme" != bad-romance ]] && theme_file="$repo_root/data/themes/$theme.conf"
[[ -f "$theme_file" ]] || {
	printf 'No such theme: %s\n' "$theme" >&2
	exit 1
}

declare -A token=()
while IFS='=' read -r key value; do
	[[ "$key" == [A-Z_]* && -n "$value" ]] || continue
	token["$key"]="$value"
done <"$theme_file"

title="$(sed -nE 's/^# @title: (.*)$/\1/p' "$theme_file")"
essence="$(sed -nE 's/^# @essence: (.*)$/\1/p' "$theme_file")"
palettes=$(($(find "$repo_root/data/themes" -name '*.conf' -type f | wc -l) + 1))

# 24-bit escapes, because the palette is 24-bit: quantising it to the terminal's
# sixteen slots would print an approximation of the colour being described.
fg() { printf '\033[38;2;%d;%d;%dm' "0x${1:0:2}" "0x${1:2:2}" "0x${1:4:2}"; }
bg() { printf '\033[48;2;%d;%d;%dm' "0x${1:0:2}" "0x${1:2:2}" "0x${1:4:2}"; }
reset=$'\033[0m'

row() { printf '  %s%-8s%s %s\n' "$(fg "${token[COLOR_FG_DIM]}")" "$1" "$reset" "$2"; }

printf '\n  %s%s%s %s·%s %s%s%s %s—%s %s%s%s\n\n' \
	"$(fg "${token[COLOR_ACCENT]}")" 'vivac' "$reset" \
	"$(fg "${token[COLOR_BORDER_INACTIVE]}")" "$reset" \
	"$(fg "${token[COLOR_FG]}")" "${title:-$theme}" "$reset" \
	"$(fg "${token[COLOR_BORDER_INACTIVE]}")" "$reset" \
	"$(fg "${token[COLOR_MUTED]}")" "${essence:-$theme}" "$reset"
row 'os' "$(sed -nE 's/^PRETTY_NAME="?([^"]*)"?$/\1/p' /etc/os-release | head -1)"
row 'kernel' "$(uname -r)"
row 'wm' "hyprland   bar waybar   term kitty"
row 'themes' "$palettes palettes, one source of colour"

printf '\n  '
for key in COLOR_BG COLOR_SURFACE COLOR_SURFACE_ALT COLOR_BORDER_INACTIVE \
	COLOR_FG_DIM COLOR_FG COLOR_ACCENT COLOR_URGENT COLOR_MUTED COLOR_OK COLOR_INFO; do
	printf '%s      %s' "$(bg "${token[$key]}")" "$reset"
done
printf '\n\n'
