#!/usr/bin/env bash
# The commands keep a literal $HOME: the surface script expands it in the guest.
# shellcheck disable=SC2016
set -Eeuo pipefail

# capture-desktop.sh and record-demo.sh open each surface with the command its
# key binding runs, read out of the deployed compositor config at run time.
# That config is hyprland.lua now: both scripts read it, never the old hyprlang config,
# and their bind_command reads the same answer out of it for every key the
# captures and the film press.

repo_root="${REPO_ROOT:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)}"
sandbox="$(mktemp -d "${TMPDIR:-/tmp}/vivac-bindcmd.XXXXXX")"
trap 'rm -rf -- "$sandbox"' EXIT

fail() {
	printf '%s\n' "$1" >&2
	exit 1
}

mkdir -p -- "$sandbox/user/.config/hypr"
cp -- "$repo_root/dotfiles/hypr/.config/hypr/hyprland.lua" "$sandbox/user/.config/hypr/hyprland.lua"

expected=(
	'SUPER,Return|kitty'
	'SUPER,R|rofi -show drun'
	"SUPER,D|dmenu_run -fn 'JetBrains Mono Nerd Font-12' -nb '#$(grep '^COLOR_BG=' "$repo_root/data/theme.conf" | cut -d= -f2)' -nf '#$(grep '^COLOR_FG=' "$repo_root/data/theme.conf" | cut -d= -f2)' -sb '#$(grep '^COLOR_ACCENT=' "$repo_root/data/theme.conf" | cut -d= -f2)' -sf '#$(grep '^COLOR_BG=' "$repo_root/data/theme.conf" | cut -d= -f2)'"
	'SUPER ALT,R|wofi --show drun'
	'SUPER,E|kitty -e nvim'
	'SUPER,L|hyprlock'
	'SUPER SHIFT,S|$HOME/.config/hypr/scripts/screenshot.sh'
	',F1|$HOME/.config/hypr/scripts/help-pane.sh --pane hypr'
	',F2|$HOME/.config/hypr/scripts/help-pane.sh --pane browser'
	',F3|$HOME/.config/hypr/scripts/help-pane.sh --pane shell'
	',F4|$HOME/.config/hypr/scripts/help-pane.sh --pane editor'
	',F5|$HOME/.config/hypr/scripts/help-pane.sh --pane system'
	'SUPER SHIFT,E|$HOME/.config/rofi/power/powermenu.sh'
	'SUPER SHIFT,Q|$HOME/.local/bin/vivac-power'
	'SUPER SHIFT,T|$HOME/.local/bin/vivac-theme'
	'SUPER,V|cliphist list | rofi -dmenu -i -p Clipboard | cliphist decode | wl-copy'
	'SUPER SHIFT,R|hyprctl reload'
)

for script in capture-desktop record-demo; do
	file="$repo_root/scripts/$script.sh"
	grep -n 'hyprland\.conf' "$file" && fail "$script.sh still names the hyprlang config"
	grep -q 'hyprland\.lua' "$file" || fail "$script.sh does not read hyprland.lua"
	# The reader is the Python in the BINDPY heredoc; run exactly that text.
	sed -n "/<<'BINDPY'/,/^BINDPY\$/p" "$file" | sed '1d;$d' >"$sandbox/$script.py"
	[[ -s "$sandbox/$script.py" ]] || fail "$script.sh has no bind reader"
	for pair in "${expected[@]}"; do
		combo="${pair%%|*}"
		want="${pair#*|}"
		got="$(HOME="$sandbox/user" python -I "$sandbox/$script.py" "$combo")" || fail "$script.sh: no answer for $combo"
		[[ "$got" == "$want" ]] || fail "$script.sh: $combo gives [$got], expected [$want]"
	done
	if HOME="$sandbox/user" python -I "$sandbox/$script.py" 'SUPER,Z' >/dev/null 2>&1; then
		fail "$script.sh answered for a key nothing binds"
	fi
	# A dispatcher bind is not a command: SUPER+Q closes a window.
	if HOME="$sandbox/user" python -I "$sandbox/$script.py" 'SUPER,Q' >/dev/null 2>&1; then
		fail "$script.sh took a dispatcher bind for a command"
	fi
done

printf 'bind readers: %d keys answered from hyprland.lua by capture-desktop.sh and record-demo.sh\n' "${#expected[@]}"
