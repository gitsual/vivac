#!/usr/bin/env bash
set -Eeuo pipefail

# Stage the theme for the boot menu. Runs as the user, on every theme switch
# (scripts/apply-theme.sh calls it when the stage folder exists).
#
# The EFI system partition is root's, so this is half of a pair, the Linux
# twin of windows/lib/Boot.psm1 and windows/scripts/boot-sync.ps1:
#
#   - this script renders the two pictures (the boot logo and the menu's
#     background) and writes the palette into the stage folder, the
#     palette last: that file is what vivac-boot-sync.path watches
#   - vivac-boot-sync.service runs scripts/boot-sync.py as root. It takes
#     nothing from the stage as it is: colours are checked against
#     ^[0-9A-F]{6}$, pictures are decoded and encoded anew, and the GRUB
#     theme is written by the service itself. A user-level program can
#     choose the colours of the boot menu; it cannot hand GRUB a file of its
#     own.
#
#   --stage DIR   where to stage (default: $VIVAC_BOOT_STAGE or /var/lib/vivac/boot-stage)
#   --theme NAME  the theme to stage (default: the one the settings name)
#   --size WxH    the screen's size (default: the first monitor Hyprland reports,
#                 else the size of the last stage, else 1920x1080)

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
# shellcheck source=lib/kv.sh
source "$repo_root/lib/kv.sh"
# shellcheck source=lib/render.sh
source "$repo_root/lib/render.sh"
# shellcheck source=lib/settings.sh
source "$repo_root/lib/settings.sh"
# shellcheck source=lib/themes.sh
source "$repo_root/lib/themes.sh"

stage="${VIVAC_BOOT_STAGE:-/var/lib/vivac/boot-stage}"
theme='' size=''
while (($#)); do
	case "$1" in
	--stage) stage="${2:?--stage needs a folder}" && shift ;;
	--theme) theme="${2:?--theme needs a name}" && shift ;;
	--size) size="${2:?--size needs WxH}" && shift ;;
	-h | --help)
		sed -n '4,22p' "${BASH_SOURCE[0]}" | sed 's/^# \?//'
		exit 0
		;;
	*)
		printf 'boot-stage: unknown option %s\n' "$1" >&2
		exit 2
		;;
	esac
	shift
done

fail() {
	printf 'boot-stage: %s\n' "$1" >&2
	exit 1
}
[[ -d "$stage" && -w "$stage" ]] || fail "the stage folder $stage is not there or not writable by $USER (see docs/boot-sync.md)"

settings_file="$(themes_settings_file)"
export SETTINGS_FILE="$settings_file"
if [[ -z "$theme" ]]; then
	settings_load "$settings_file"
	theme="${SETTINGS[theme]}"
fi
theme_file="$(theme_file_for "$repo_root" "$theme")" || fail "no palette named $theme"

# ---------------------------------------------------------------- the size

if [[ -z "$size" ]] && command -v hyprctl >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then
	size="$(timeout 5 hyprctl monitors -j 2>/dev/null | jq -r '.[0] | "\(.width)x\(.height)"' 2>/dev/null)" || size=''
fi
if [[ ! "$size" =~ ^[0-9]{3,4}x[0-9]{3,4}$ && -f "$stage/palette.conf" ]]; then
	w="$(sed -nE 's/^WIDTH=([0-9]{3,4})$/\1/p' "$stage/palette.conf" | tail -1)"
	h="$(sed -nE 's/^HEIGHT=([0-9]{3,4})$/\1/p' "$stage/palette.conf" | tail -1)"
	[[ -n "$w" && -n "$h" ]] && size="${w}x${h}"
fi
[[ "$size" =~ ^[0-9]{3,4}x[0-9]{3,4}$ ]] || size=1920x1080
width="${size%x*}" height="${size#*x}"

# ------------------------------------------------------------ the pictures

work="$(mktemp -d "${TMPDIR:-/tmp}/vivac-boot-stage.XXXXXX")"
trap 'rm -rf -- "$work"' EXIT
render_load_tokens "$theme_file"

# The boot logo: the whole screen in the base colour, the coin of the brand
# mark a little above the centre and the wordmark under it (the same drawing
# windows/lib/Boot.psm1 makes).
mark="$work/mark.svg"
render_file "$repo_root/templates/brand/logo-mark.svg.in" "$mark"
mark_body="$(sed -E ':a;N;$!ba;s/<\?xml[^?]*\?>//;s/<!--([^-]|-[^-])*-->//g' "$mark")"
coin=$((height * 24 / 100))
coin_x=$(((width - coin) / 2))
coin_y=$((height * 382 / 1000 - coin / 2))
font=$((height * 45 / 1000))
text_y=$((coin_y + coin + font * 3 / 2))
mark_body="${mark_body//width=\"256\" height=\"256\"/x=\"$coin_x\" y=\"$coin_y\" width=\"$coin\" height=\"$coin\"}"
cat >"$work/splash.svg" <<SVG
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 $width $height" width="$width" height="$height">
<rect width="$width" height="$height" fill="#${RENDER_TOKENS[COLOR_BG]}"/>
$mark_body
<text x="$((width / 2))" y="$text_y" text-anchor="middle" font-family="JetBrains Mono, JetBrainsMono Nerd Font, monospace" font-size="$font" font-weight="700" letter-spacing="-1" fill="#${RENDER_TOKENS[COLOR_ACCENT]}">vivac</text>
</svg>
SVG
rsvg-convert -w "$width" -h "$height" -o "$work/splash.png" "$work/splash.svg"

# The menu's background is the theme's own wallpaper, covering the screen.
picture="$(theme_wallpaper_for "$theme_file")" || picture=''
if [[ -z "$picture" ]]; then
	"$repo_root/scripts/make-wallpaper.sh" --theme "$theme_file" --out "$work/wall" --no-raster >/dev/null
	picture="$work/wall.png"
	rsvg-convert -w 3840 -h 2160 -o "$picture" "$work/wall/$(basename -- "$theme_file" .conf).svg"
fi
magick "$picture" -resize "${width}x${height}^" -gravity center -extent "${width}x${height}" -alpha off "PNG24:$work/background.png"

# ------------------------------------------------------------------- stage

put() { # put SOURCE NAME — beside, then renamed over, so a reader never sees half a file
	local scratch
	scratch="$(mktemp -- "$stage/.$2.XXXXXX")"
	cat -- "$1" >"$scratch"
	chmod 0644 -- "$scratch"
	mv -T -- "$scratch" "$stage/$2"
}
{
	printf 'THEME=%s\nWIDTH=%s\nHEIGHT=%s\n' "$theme" "$width" "$height"
	for key in COLOR_BG COLOR_FG COLOR_FG_DIM COLOR_SURFACE COLOR_SURFACE_ALT COLOR_ACCENT COLOR_MUTED COLOR_BORDER_INACTIVE; do
		printf '%s=%s\n' "$key" "${RENDER_TOKENS[$key]}"
	done
} >"$work/palette.conf"
put "$work/splash.png" splash.png
put "$work/background.png" background.png
put "$work/palette.conf" palette.conf
printf 'boot-stage: %s at %s staged in %s\n' "$theme" "$size" "$stage"
