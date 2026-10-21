#!/usr/bin/env bash
set -Eeuo pipefail

# Lay the palette's colours over configs the owner structured themselves
# (waybar, kitty, dunst, rofi, wofi), changing colour values and nothing else.
#
#   --apply THEME     palette to apply (a name from the catalogue)
#   --rebase          take the files as they are now as the new starting point
#   --config-dir DIR  where the owner configs live (default: XDG config home)
#
# Which files are touched is data/colour-overlay.tsv. Missing files are
# skipped, never created; symlinks (Stow's) are skipped, never written through.

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
data="${COLOUR_OVERLAY_DATA:-$repo_root/data}"
theme='' config_dir="${XDG_CONFIG_HOME:-$HOME/.config}" extra=()
while (($#)); do
	case "$1" in
	--apply)
		theme="${2:-}"
		shift
		;;
	--config-dir)
		config_dir="${2:-}"
		shift
		;;
	--rebase) extra+=(--rebase) ;;
	-h | --help)
		sed -n '4,13p' "${BASH_SOURCE[0]}" | sed 's/^# \?//'
		exit 0
		;;
	*)
		printf 'Unknown option: %s\n' "$1" >&2
		exit 2
		;;
	esac
	shift
done
[[ -n "$theme" ]] || {
	printf 'colour-overlay: --apply THEME is required\n' >&2
	exit 2
}

if [[ "$theme" == bad-romance ]]; then
	theme_file="$data/theme.conf"
elif [[ -f "$data/themes/$theme.conf" ]]; then
	theme_file="$data/themes/$theme.conf"
else
	# A palette made from a picture lives outside the checkout (lib/themes.sh).
	# shellcheck source=lib/kv.sh
	source "$repo_root/lib/kv.sh"
	# shellcheck source=lib/settings.sh
	source "$repo_root/lib/settings.sh"
	# shellcheck source=lib/themes.sh
	source "$repo_root/lib/themes.sh"
	theme_file="$(theme_file_for "$repo_root" "$theme")" || theme_file=''
fi
[[ -f "$theme_file" ]] || {
	printf 'colour-overlay: %s names no palette\n' "$theme" >&2
	exit 1
}

exec python3 -I "$repo_root/scripts/colour-overlay.py" \
	--data "$data" --map "$repo_root/data/colour-overlay.tsv" --theme-file "$theme_file" \
	--config-dir "$config_dir" --state "${XDG_STATE_HOME:-$HOME/.local/state}/vivac/colour-overlay" "${extra[@]}"
