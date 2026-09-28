#!/usr/bin/env bash
# The bar's wired menu: connect or drop the cable through NetworkManager, or
# open nm-connection-editor. Chosen by position, labels from i18n/.
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

# The first managed ethernet device; Docker's veth pairs report as unmanaged.
iface="$(nmcli -t -f DEVICE,TYPE,STATE device status | awk -F: '$2=="ethernet" && $3!~/unmanaged|sin gesti/ {print $1; exit}')"
[[ -n "$iface" ]] || {
	command -v notify-send >/dev/null && notify-send "$(i18n_get net.wired_title)" "$(i18n_get net.none)"
	exit 3
}

labels=(
	"󰈀  $(i18n_format net.wired_connect "$iface")"
	"󰈂  $(i18n_get net.wired_disconnect)"
	"  $(i18n_get net.edit)"
)
commands=("nmcli device connect $iface" "nmcli device disconnect $iface" nm-connection-editor)

chosen="$(printf '%s\n' "${labels[@]}" | rofi -dmenu -i -format i -p "$(i18n_get net.wired_title)")" || exit 0
[[ "$chosen" =~ ^[0-9]+$ ]] || exit 0
((chosen < ${#commands[@]})) || exit 0
exec ${commands[$chosen]}
