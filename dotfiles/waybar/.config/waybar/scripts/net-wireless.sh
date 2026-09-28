#!/usr/bin/env bash
# The bar's Wi-Fi menu: rofi over NetworkManager, in the session's language.
#
# The list is the networks the adapter can see right now, plus a radio toggle
# and a door into nm-connection-editor for anything the menu does not cover.
# The action is chosen by position, never by label: the labels are translated
# and an SSID is data the network chose, so neither is matched as text.
#
# A secured network that has no saved profile asks for its key in a second
# rofi prompt with echo off. A saved profile is brought up as it is; if that
# fails (the key changed) the stale profile is dropped and the key asked again.
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

notify() {
	command -v notify-send >/dev/null && notify-send "$(i18n_get net.wifi_title)" "$1" || true
}

# The adapter is asked for by type, not by name: names are predictable, not
# guaranteed, and the bar already binds the module with a pattern.
iface="$(nmcli -t -f DEVICE,TYPE device status | awk -F: '$2=="wifi"{print $1; exit}')"
[[ -n "$iface" ]] || {
	notify "$(i18n_get net.none)"
	exit 3
}

radio="$(nmcli radio wifi)"
nmcli device wifi rescan ifname "$iface" >/dev/null 2>&1 || true
sleep 1

# Parallel arrays: one row per menu line, the action read from kinds[].
kinds=() labels=() ssids=() secured=()
if [[ "$radio" == enabled ]]; then
	kinds+=(radio) labels+=("󰖪  $(i18n_get net.wifi_off)")
else
	kinds+=(radio) labels+=("󰖩  $(i18n_get net.wifi_on)")
fi
kinds+=(edit) labels+=("  $(i18n_get net.edit)") ssids+=('' '') secured+=('' '')

active=''
while IFS=: read -r in_use ssid security signal; do
	[[ -n "$ssid" ]] || continue
	seen=0
	for known in "${ssids[@]}"; do [[ "$known" == "$ssid" ]] && seen=1; done
	((seen)) && continue
	[[ "$in_use" == '*' ]] && active="$ssid"
	if [[ -z "$security" || "$security" == '--' ]]; then icon='󰖩' locked=0; else icon='󰤪' locked=1; fi
	mark=''
	[[ "$in_use" == '*' ]] && mark='  ✔'
	kinds+=(net) ssids+=("$ssid") secured+=("$locked")
	labels+=("$(printf '%s  %-32s %3s%%%s' "$icon" "$ssid" "$signal" "$mark")")
done < <(nmcli -t -f IN-USE,SSID,SECURITY,SIGNAL device wifi list ifname "$iface" --rescan no)

chosen="$(printf '%s\n' "${labels[@]}" | rofi -dmenu -i -format i -p "$(i18n_get net.wifi_title)")" || exit 0
[[ "$chosen" =~ ^[0-9]+$ ]] || exit 0
((chosen < ${#kinds[@]})) || exit 0

case "${kinds[$chosen]}" in
radio)
	if [[ "$radio" == enabled ]]; then nmcli radio wifi off; else nmcli radio wifi on; fi
	exit 0
	;;
edit) exec nm-connection-editor ;;
esac

ssid="${ssids[$chosen]}"
if [[ "$ssid" == "$active" ]]; then
	nmcli connection down id "$ssid" >/dev/null 2>&1 && notify "$(i18n_format net.disconnected "$ssid")"
	exit 0
fi

if nmcli -t -f NAME connection show | grep -Fxq -- "$ssid"; then
	if nmcli connection up id "$ssid" ifname "$iface" >/dev/null 2>&1; then
		notify "$(i18n_format net.connected "$ssid")"
		exit 0
	fi
	nmcli connection delete id "$ssid" >/dev/null 2>&1 || true
fi

if [[ "${secured[$chosen]}" == 1 ]]; then
	key="$(rofi -dmenu -password -p "$(i18n_format net.password_for "$ssid")")" || exit 0
	[[ -n "$key" ]] || exit 0
	ok=0
	nmcli device wifi connect "$ssid" password "$key" ifname "$iface" >/dev/null 2>&1 && ok=1
else
	ok=0
	nmcli device wifi connect "$ssid" ifname "$iface" >/dev/null 2>&1 && ok=1
fi

if ((ok)); then notify "$(i18n_format net.connected "$ssid")"; else notify "$(i18n_format net.failed "$ssid")"; fi
