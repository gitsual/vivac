#!/usr/bin/env bash
set -Eeuo pipefail

# Render a theme's wallpaper from templates/wallpaper/, in the theme's own
# colours, with its ornament on top when the theme has earned one.
#
# Ornament is not decoration on demand. The corpus mediates tension, it does
# not decorate it: only a pairing the matrix calls affinity (distance <= 2),
# or a theme that actually carries one of the named aesthetics, may add a
# layer. A theme that declares an ornament without qualifying is an error, not
# a silent downgrade — the claim is wrong and saying so is the point.

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
# shellcheck source=lib/kv.sh
source "$repo_root/lib/kv.sh"
# shellcheck source=lib/render.sh
source "$repo_root/lib/render.sh"

out_dir="$repo_root/dist/wallpapers"
themes=()
all=false
raster=true

usage() {
	cat <<'USAGE'
Usage: scripts/make-wallpaper.sh [--theme NAME]... [--all] [--out DIR] [--no-raster]

Render one wallpaper per theme (SVG always, PNG when a rasterizer exists).
  --theme NAME  a name from data/themes/, or 'bad-romance' for the default
  --theme FILE  a path ending in .conf, for a theme outside the catalogue
  --all         every theme in the catalogue, default included
  --out DIR     where to write (default: dist/wallpapers)
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
		themes+=("$2")
		shift
		;;
	--all) all=true ;;
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

theme_path() {
	case "$1" in
	*.conf) printf '%s' "$1" ;;
	bad-romance) printf '%s' "$repo_root/data/theme.conf" ;;
	*) printf '%s' "$repo_root/data/themes/$1.conf" ;;
	esac
}

# ornament_for THEME_FILE — print the ornament name the theme may use, or
# nothing. Fails when the theme claims one it has not earned.
ornament_for() {
	local file="$1" name declared distance aesthetic row allowed required hex
	name="$(basename -- "$file" .conf)"
	declared="$(sed -nE 's/^# @ornament: (.*)$/\1/p' "$file")"
	[[ -n "$declared" ]] || return 0
	distance="$(sed -nE 's/^# @distance: (.*)$/\1/p' "$file")"
	aesthetic="$(sed -nE 's/^# @aesthetic: (.*)$/\1/p' "$file")"

	if [[ "$distance" =~ ^[0-9]$ ]] && ((distance <= 2)); then
		printf '%s' "$declared"
		return 0
	fi
	[[ -n "$aesthetic" ]] || {
		printf '%s claims the ornament %s at distance %s, which is tension, and names no aesthetic to carry it\n' \
			"$name" "$declared" "$distance" >&2
		return 1
	}
	row="$(awk -F'\t' -v a="$aesthetic" '!/^#/ && NF && $1 == a' "$repo_root/data/aesthetics.tsv")"
	[[ -n "$row" ]] || {
		printf '%s claims the aesthetic %s, which the corpus does not list\n' "$name" "$aesthetic" >&2
		return 1
	}
	allowed="$(cut -f4 <<<"$row")"
	[[ "$allowed" == yes ]] || {
		printf '%s claims %s, an aesthetic the corpus marks anti-ornamento\n' "$name" "$aesthetic" >&2
		return 1
	}
	required="$(cut -f3 <<<"$row")"
	while IFS= read -r hex; do
		grep -qE "^[A-Z_]+=$hex$" "$file" || {
			printf '%s claims %s but does not carry its canonical %s\n' "$name" "$aesthetic" "$hex" >&2
			return 1
		}
	done < <(tr ',' '\n' <<<"$required")
	printf '%s' "$declared"
}

if $all; then
	themes=(bad-romance)
	while IFS= read -r file; do
		themes+=("$(basename -- "$file" .conf)")
	done < <(find "$repo_root/data/themes" -name '*.conf' -type f | LC_ALL=C sort)
fi
((${#themes[@]})) || themes=(bad-romance)

mkdir -p -- "$out_dir"
rasterizer=''
if $raster; then
	for candidate in rsvg-convert magick convert inkscape; do
		command -v "$candidate" >/dev/null && {
			rasterizer="$candidate"
			break
		}
	done
	[[ -n "$rasterizer" ]] || printf 'No rasterizer found; SVGs written, PNGs skipped\n' >&2
fi

for theme in "${themes[@]}"; do
	file="$(theme_path "$theme")"
	# A theme given as a path is named by its file; a theme given by name keeps
	# the name, so the default stays 'bad-romance' and not 'theme'.
	if [[ "$theme" == *.conf ]]; then theme="$(basename -- "$file" .conf)"; fi
	[[ -f "$file" ]] || {
		printf 'no theme named %s\n' "$theme" >&2
		exit 1
	}
	ornament="$(ornament_for "$file")"
	render_load_tokens "$file"
	# The wordmark is text, not a colour, so it is added after the loader has
	# finished checking that every token it read is bare hex.
	title="$(sed -nE 's/^# @title: (.*)$/\1/p' "$file")"
	essence="$(sed -nE 's/^# @essence: (.*)$/\1/p' "$file")"
	[[ -n "$title" && -n "$essence" ]] || {
		printf '%s declares no title and essence for its wordmark\n' "$theme" >&2
		exit 1
	}
	RENDER_TOKENS[THEME_TITLE]="$title"
	RENDER_TOKENS[THEME_ESSENCE]="$essence"

	svg="$out_dir/$theme.svg"
	rm -f -- "$svg"
	render_file "$repo_root/templates/wallpaper/base.svg.in" "$svg"
	if [[ -n "$ornament" ]]; then
		fragment="$repo_root/templates/wallpaper/ornament-$ornament.svg.in"
		[[ -f "$fragment" ]] || {
			printf '%s declares the ornament %s, which has no template\n' "$theme" "$ornament" >&2
			exit 1
		}
		render_file "$fragment" "$svg.ornament"
		cat -- "$svg.ornament" >>"$svg"
		rm -f -- "$svg.ornament"
	fi
	printf '</svg>\n' >>"$svg"

	# Unlinked first, never written through. The default theme's PNG is
	# committed and Stow puts a SYMLINK INTO THE CHECKOUT at exactly this
	# path, so opening it for writing would edit the repository from a script
	# whose whole job is to write into a home directory.
	rm -f -- "$out_dir/$theme.png"
	case "$rasterizer" in
	rsvg-convert) rsvg-convert -w 3840 -h 2160 -o "$out_dir/$theme.png" "$svg" ;;
	magick) magick -background none "$svg" -resize 3840x2160 "$out_dir/$theme.png" ;;
	convert) convert -background none "$svg" -resize 3840x2160 "$out_dir/$theme.png" ;;
	inkscape) inkscape "$svg" --export-type=png --export-filename="$out_dir/$theme.png" -w 3840 -h 2160 >/dev/null 2>&1 ;;
	esac
	printf '%-22s %s%s\n' "$theme" "$(basename -- "$svg")" "${ornament:+ + $ornament}"
done
