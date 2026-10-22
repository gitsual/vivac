#!/usr/bin/env bash
set -Eeuo pipefail

# Switch the whole desktop to a palette from the catalogue, live.
#
# The palette-dependent files are committed renders: templates/ is rendered
# into dotfiles/ from data/theme.conf and Stow symlinks the result into $HOME.
# That is right for the default and useless for a choice — a stranger who picks
# another theme would change a setting and see nothing move, because the
# stylesheets on disk were rendered from a palette they did not pick.
#
# So a non-default theme is deployed the same way a machine-specific render is:
# rendered from the chosen palette and written OVER the stowed symlink, with
# the symlink recorded so choosing the default again restores it exactly.
# Nothing in the checkout is touched, which is what keeps check-theme-drift.sh
# meaningful.
#
#   --theme NAME   write the setting first (default: whatever is set)
#   --list         print the catalogue and exit
#   --no-reload    render only; do not tell anything to re-read its config
#
# What the caller sees change: the wallpaper, the bar, the window borders, the
# notifications, the launcher, and the terminal -- open windows included, since
# kitty re-reads its config on SIGUSR1 (which is how kitty's own
# reload_conf_in_all_kitties does it). The two that still wait for their next
# launch are hyprlock and nwg-bar, neither of which is on screen to reload.

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
# shellcheck source=lib/kv.sh
source "$repo_root/lib/kv.sh"
# shellcheck source=lib/render.sh
source "$repo_root/lib/render.sh"
# shellcheck source=lib/settings.sh
source "$repo_root/lib/settings.sh"
# shellcheck source=lib/themes.sh
source "$repo_root/lib/themes.sh"

settings_file="${SETTINGS_FILE:-${XDG_CONFIG_HOME:-$HOME/.config}/vivac/settings}"
state_dir="${XDG_STATE_HOME:-$HOME/.local/state}/vivac"
manifest="$state_dir/theme-overlay"
templates_dir="${TEMPLATES_DIR:-$repo_root/templates}"
default_theme="$THEMES_DEFAULT"
# The palettes made from pictures are found through the same settings file
# (the shared root is one of its keys), here and in every script run below.
export SETTINGS_FILE="$settings_file"

# The shipped palettes and the ones made from pictures (lib/themes.sh).
catalogue() {
	theme_catalogue "$repo_root"
}

chosen='' reload=true
while (($#)); do
	case "$1" in
	--theme)
		chosen="${2:-}"
		shift
		;;
	--list)
		catalogue
		exit 0
		;;
	--no-reload) reload=false ;;
	-h | --help)
		sed -n '4,25p' "${BASH_SOURCE[0]}" | sed 's/^# \?//'
		exit 0
		;;
	*)
		printf 'Unknown option: %s\n' "$1" >&2
		exit 2
		;;
	esac
	shift
done

if [[ -n "$chosen" ]]; then
	# Materialised first: under `set -o pipefail` a `grep -q` that matches the
	# first line kills `find` with SIGPIPE, and the pipeline then reports the
	# signal instead of the match.
	known="$(catalogue)"
	grep -Fxq -- "$chosen" <<<"$known" || {
		printf 'apply-theme: no theme named %s; the catalogue holds:\n' "$chosen" >&2
		printf '%s\n' "$known" >&2
		exit 1
	}
	settings_write "$settings_file" theme "$chosen"
fi
settings_load "$settings_file"
theme="${SETTINGS[theme]}"
theme_file="$(theme_file_for "$repo_root" "$theme")" || theme_file=''
[[ -f "$theme_file" ]] || {
	printf 'apply-theme: %s names no palette\n' "$theme" >&2
	exit 1
}

# ------------------------------------------------------------------- overlay

# Undo the previous overlay before laying down a new one, so switching themes
# five times leaves exactly as many files behind as switching once, and so the
# Stow symlink is put back byte-for-byte rather than approximated.
if [[ -f "$manifest" ]]; then
	while IFS=$'\t' read -r target link; do
		[[ -n "$target" ]] || continue
		if [[ -n "$link" ]]; then
			# Never leave the path empty, not even for a microsecond: a
			# reload that lands in that window makes Hyprland write its own
			# stub config over it, which costs the session 49 of its 55
			# binds and makes the ln below fail with EEXIST. Build the new
			# symlink beside the target and rename it into place.
			scratch_link="$(mktemp -u -- "$target.XXXXXX")"
			ln -s -- "$link" "$scratch_link"
			mv -T -- "$scratch_link" "$target"
		else
			rm -f -- "$target"
		fi
	done <"$manifest"
	rm -f -- "$manifest"
fi

render_load_tokens "$theme_file"

# The default palette is what the committed dotfiles already hold, so it needs
# no overlay at all: restoring the symlinks above has already applied it.
written=0
if [[ "$theme" != "$default_theme" ]]; then
	mkdir -p -- "$state_dir"
	: >"$manifest"
	while IFS= read -r template; do
		relative="${template#"$templates_dir"/}"
		# templates/<package>/<path under $HOME>.in — anything whose path does
		# not start at a dotfile belongs to the system (/etc) or to no home at
		# all (the wallpaper sources), and is not ours to write here.
		rest="${relative#*/}"
		[[ "$rest" == .* ]] || continue
		target="$HOME/${rest%.in}"
		# A regular file here is the owner's: the manifest was undone above, so
		# nothing of ours can be left at this path. Writing over it would replace
		# their layout with ours, and undoing it later would delete it. It gets
		# the palette's colours from the colour overlay instead.
		if [[ -e "$target" && ! -L "$target" ]]; then
			printf 'apply-theme: %s is not a vivac file; left to the colour overlay\n' "$target" >&2
			continue
		fi
		link=''
		[[ -L "$target" ]] && link="$(readlink -- "$target")"
		mkdir -p -- "$(dirname -- "$target")"
		# Render beside the target, never in $TMPDIR: /tmp is tmpfs and $HOME
		# is not, so a scratch file there makes the mv below a copy rather
		# than a rename(2), exposing a half-written config to any reload.
		scratch="$(mktemp -- "$target.XXXXXX")"
		render_file "$template" "$scratch" || {
			rm -f -- "$scratch"
			printf 'apply-theme: %s did not render\n' "$relative" >&2
			exit 1
		}
		mv -T -- "$scratch" "$target"
		printf '%s\t%s\n' "$target" "$link" >>"$manifest"
		written=$((written + 1))
	done < <(find "$templates_dir" -type f -name '*.in' | LC_ALL=C sort)
fi

# Owner-structured configs keep their own layout and take only the colours, the
# default palette included (it is how a switch back restores the originals).
"$repo_root/scripts/colour-overlay.sh" --apply "$theme" --config-dir "$HOME/.config" >/dev/null ||
	printf 'apply-theme: the colour overlay failed; owner configs keep their colours\n' >&2

# The machine-specific renders carry palette tokens too (the bar's colours),
# and they read the theme straight out of the settings file written above.
"$repo_root/scripts/render-config.sh" --deploy >/dev/null

# ------------------------------------------------------------------- reloads

if $reload; then
	# The wallpaper is the largest thing on screen and the slowest to draw, so
	# it starts first and catches up while the rest reloads.
	#
	# Tested with -f, not -x: both call sites run it through `bash` (here and
	# the wallpaper autostart entry of hyprland.lua), so the execute
	# bit is a permission neither one needs. Guarding on -x meant that a file
	# committed 644 -- which this one was -- silently disabled the wallpaper
	# half of every theme switch, on every machine, with nothing reported.
	#
	# Killing the old swaybg belongs to wallpaper.sh, which does it holding the
	# lock that serialises the swap; doing it out here raced that lock.
	if [[ -f "$HOME/.config/hypr/scripts/wallpaper.sh" ]]; then
		setsid bash "$HOME/.config/hypr/scripts/wallpaper.sh" >/dev/null 2>&1 &
	fi
	# Every reload below talks to another process, and a compositor whose IPC
	# has wedged never answers: an unbounded `hyprctl reload` leaves this
	# script blocked for the life of the session. vivac-welcome previews
	# synchronously, so that block reaches the keyboard loop and the desktop
	# stops answering keys -- the same symptom this script already caused once
	# by other means. Bound anything that waits on another process.
	timeout 5 hyprctl reload >/dev/null 2>&1 || true
	# SIGUSR2 makes Waybar re-read both its config and its stylesheet.
	pkill -SIGUSR2 -x waybar >/dev/null 2>&1 || true
	# ...and SIGUSR1 makes kitty re-read its own, so the terminals already open
	# take the new ground and text instead of keeping the previous theme's
	# until they are closed. This is the signal kitty sends itself.
	pkill -SIGUSR1 -x kitty >/dev/null 2>&1 || true
	timeout 5 dunstctl reload >/dev/null 2>&1 || true
	# base46 compiles its highlights once and caches the bytecode. The theme
	# file just re-rendered keeps its name, so nothing in that cache looks
	# stale to it and the next editor would start in the previous palette.
	# Dropping the cache costs one recompile at the next launch. Editors
	# already open keep their colours until they are restarted, which is the
	# one surface here that cannot be told to re-read its config: there is no
	# signal for it and no server socket to send a command to.
	#
	# Rebuilt right away rather than left to the next launch: init.lua reads the
	# cache unconditionally, so an editor started with the cache missing opens on
	# an error instead of on the file. The recompile is a headless run of the
	# call base46 makes when it is first installed.
	rm -rf -- "${XDG_DATA_HOME:-$HOME/.local/share}/nvim/base46"
	if command -v nvim >/dev/null 2>&1; then
		timeout 120 nvim --headless \
			-c 'lua require("base46").load_all_highlights()' \
			-c 'qa!' >/dev/null 2>&1 || true
	fi
fi

printf 'theme: %s applied (%d overlay files)\n' "$theme" "$written"
