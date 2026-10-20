#!/usr/bin/env bash
# The keyboard power menu: rofi, in the session's language, with the same
# icons and the same commands as the graphical one.
#
# The action is chosen by position, never by the label. The previous version
# matched the selection against the English string it had printed, so the menu
# could not be translated without silently doing nothing: every branch would
# have missed and the script would have exited 0.
set -Eeuo pipefail

self="$(readlink -f -- "${BASH_SOURCE[0]}")"
repo_root="${VIVAC_REPO:-$(cd -- "$(dirname -- "$self")/../../../../.." && pwd -P)}"
# shellcheck source=lib/kv.sh
source "$repo_root/lib/kv.sh"
# shellcheck source=lib/i18n.sh
source "$repo_root/lib/i18n.sh"

language="${VIVAC_LANG:-${LANG:-en}}"
language="${language%%[._@]*}"
i18n_load "$language" "${I18N_DIR:-$repo_root/i18n}" 2>/dev/null ||
	i18n_load en "${I18N_DIR:-$repo_root/i18n}"

# The drawings, and the rasterizing, come from the graphical menu: librsvg no
# longer ships a gdk-pixbuf loader, so rofi cannot open an .svg either, and one
# rasterizer is better than two.
icons="$("$HOME/.local/bin/vivac-power" --icons)"
keys=(power.lock power.suspend power.logout power.reboot power.poweroff)
files=(lock suspend log-out reboot power-off)
commands=(hyprlock 'systemctl suspend' "$HOME/.config/hypr/scripts/dispatch.sh exit" 'systemctl reboot' 'systemctl poweroff')

# rofi's dmenu mode takes a per-row icon after a US separator, which is how the
# two menus end up showing the same drawing.
menu() {
	local index
	for index in "${!keys[@]}"; do
		printf '%s\0icon\x1f%s/%s.png\n' "$(i18n_get "${keys[$index]}")" "$icons" "${files[$index]}"
	done
}

chosen="$(menu | rofi -dmenu -i -show-icons -format i -p "$(i18n_get power.title)")" || exit 0
[[ "$chosen" =~ ^[0-9]+$ ]] || exit 0
((chosen < ${#commands[@]})) || exit 0
exec ${commands[$chosen]}
