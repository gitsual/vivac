#!/usr/bin/env bash
set -Eeuo pipefail

# Render the project's banner and mark from templates/brand/, in a theme's own
# colours.
#
# The README claims the colour scheme is a build artifact and not a mood. A
# logo hand-painted in a graphics editor would be the one place that claim
# stopped being true, so the logo is rendered from the same palette files as
# the bar, the terminal and the wallpaper, by the same token substitution.
# Changing a hex in data/themes/ and re-running this is the whole procedure.

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
# shellcheck source=lib/kv.sh
source "$repo_root/lib/kv.sh"
# shellcheck source=lib/render.sh
source "$repo_root/lib/render.sh"

theme='bad-romance'
out_dir="$repo_root/assets"
raster=true

usage() {
	cat <<'USAGE'
Usage: scripts/make-logo.sh [--theme NAME] [--out DIR] [--no-raster]

Render assets/logo.svg and assets/logo-mark.svg, plus their PNGs.
  --theme NAME  a name from data/themes/, or 'bad-romance' for the default
  --out DIR     where to write (default: assets)
  --no-raster   write the SVGs only, skip the PNG pass
USAGE
}

while (($#)); do
	case "$1" in
	--theme)
		[[ $# -ge 2 ]] || {
			printf '%s\n' '--theme needs a name' >&2
			exit 2
		}
		theme="$2"
		shift
		;;
	--no-raster) raster=false ;;
	--out)
		[[ $# -ge 2 ]] || {
			printf '%s\n' '--out needs a directory' >&2
			exit 2
		}
		out_dir="$2"
		shift
		;;
	-h | --help)
		usage
		exit 0
		;;
	*)
		printf 'Unknown option: %s\n' "$1" >&2
		exit 2
		;;
	esac
	shift
done

case "$theme" in
bad-romance) file="$repo_root/data/theme.conf" ;;
*) file="$repo_root/data/themes/$theme.conf" ;;
esac
[[ -f "$file" ]] || {
	printf 'no theme named %s\n' "$theme" >&2
	exit 1
}

render_load_tokens "$file"
# Title and essence are words, not colours, so they are added after the loader
# has finished asserting that every token it read is bare hex.
title="$(sed -nE 's/^# @title: (.*)$/\1/p' "$file")"
essence="$(sed -nE 's/^# @essence: (.*)$/\1/p' "$file")"
[[ -n "$title" && -n "$essence" ]] || {
	printf '%s declares no title and essence for the banner\n' "$theme" >&2
	exit 1
}
RENDER_TOKENS[THEME_TITLE]="$title"
RENDER_TOKENS[THEME_ESSENCE]="$essence"

mkdir -p -- "$out_dir"

rasterizer=''
if $raster; then
	for candidate in rsvg-convert magick convert inkscape; do
		if command -v "$candidate" >/dev/null 2>&1; then
			rasterizer="$candidate"
			break
		fi
	done
	[[ -n "$rasterizer" ]] || printf 'No rasterizer found; SVGs written, PNGs skipped\n' >&2
fi

# name:width:height — the banner is rendered at twice its viewBox so it stays
# sharp on a HiDPI reader, and the mark at the size a favicon is scaled from.
for spec in 'logo:1300:560' 'logo-mark:512:512'; do
	name="${spec%%:*}"
	rest="${spec#*:}"
	width="${rest%%:*}"
	height="${rest##*:}"
	svg="$out_dir/$name.svg"
	rm -f -- "$svg"
	render_file "$repo_root/templates/brand/$name.svg.in" "$svg"
	# render_file writes through mktemp, which is 600 by default; these two
	# are committed and read by anyone who clones.
	chmod 644 -- "$svg"
	if [[ -n "$rasterizer" ]]; then
		rm -f -- "$out_dir/$name.png"
		case "$rasterizer" in
		rsvg-convert) rsvg-convert -w "$width" -h "$height" -o "$out_dir/$name.png" "$svg" ;;
		magick) magick -background none "$svg" -resize "${width}x${height}" "$out_dir/$name.png" ;;
		convert) convert -background none "$svg" -resize "${width}x${height}" "$out_dir/$name.png" ;;
		inkscape) inkscape "$svg" --export-type=png --export-filename="$out_dir/$name.png" -w "$width" -h "$height" >/dev/null 2>&1 ;;
		esac
	fi
	printf '%-12s %s\n' "$name" "$theme"
done
