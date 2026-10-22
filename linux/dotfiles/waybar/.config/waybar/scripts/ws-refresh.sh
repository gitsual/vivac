#!/usr/bin/env bash
# Keep the workspace cache current from Hyprland's event socket.
#
# Listens on socket2 with socat, keeps only the events that change what the
# strip shows, waits 50 ms for the burst that usually follows (a window
# opens, gets a title, gets focus), then takes one snapshot with hyprctl
# and signals Waybar. Waybar itself never polls: custom/ws runs
# ws-render.sh once at start and once per signal.
#
#   --once          one snapshot, no listener (also what the listener runs)
#   --replay FILE   read events from FILE instead of the socket (tests)
#
# Injectable for tests: HYPRCTL_CMD (default hyprctl), WS_CACHE, WS_NOTIFY
# (default: pkill -RTMIN+1 waybar), WS_DEBOUNCE (seconds, default 0.05).
set -Eeuo pipefail

hyprctl_cmd="${HYPRCTL_CMD:-hyprctl}"
cache="${WS_CACHE:-${XDG_RUNTIME_DIR:-/tmp}/waybar-ws.json}"
notify="${WS_NOTIFY:-pkill -RTMIN+1 waybar}"
debounce="${WS_DEBOUNCE:-0.05}"
relevant='^(workspace|focusedmon|openwindow|closewindow|movewindow|movewindowv2|windowtitle|windowtitlev2|urgent|createworkspace|destroyworkspace|activewindow|activewindowv2)>>'
declare -a urgent=()

snapshot() {
	local clients workspaces active tmp
	clients="$("$hyprctl_cmd" -j clients)"
	workspaces="$("$hyprctl_cmd" -j workspaces)"
	active="$("$hyprctl_cmd" -j activeworkspace)"
	tmp="$(mktemp -- "$cache.XXXXXX")"
	jq -n --argjson clients "$clients" --argjson workspaces "$workspaces" --argjson active "$active" \
		--argjson urgent "$(printf '%s\n' "${urgent[@]}" | jq -R . | jq -s .)" '
		($active.id) as $active_id
		| { active: $active_id,
		    workspaces: [ $workspaces[] | select(.id > 0) | .id as $id
		      | { id: $id, name: .name,
		          windows: [ $clients[] | select(.workspace.id == $id and .mapped)
		                     | { address, class, initialClass, title } ],
		          urgent: ($id != $active_id and
		                   ([ $clients[] | select(.workspace.id == $id) | .address ] | any(. as $a | $urgent | index($a) != null))) }
		      ] | sort_by(.id) }' >"$tmp"
	mv -- "$tmp" "$cache"
	# An urgent window on the workspace that is now active is no longer urgent.
	mapfile -t urgent < <(jq -r --argjson urgent "$(printf '%s\n' "${urgent[@]}" | jq -R . | jq -s .)" '
		.active as $active
		| [ .workspaces[] | select(.id != $active) | .windows[].address ] as $elsewhere
		| $urgent[] | select(. as $a | $elsewhere | index($a) != null)' "$cache")
	$notify || true
}

listen() {
	local line
	while IFS= read -r line; do
		[[ "$line" =~ $relevant ]] || continue
		[[ "$line" == urgent\>\>* ]] && urgent+=("0x${line#urgent>>}")
		# Drain the burst before one snapshot.
		while IFS= read -r -t "$debounce" line; do
			[[ "$line" == urgent\>\>* ]] && urgent+=("0x${line#urgent>>}")
		done
		snapshot
	done
}

case "${1:-}" in
--once)
	snapshot
	;;
--replay)
	[[ -r "${2:-}" ]] || {
		printf 'ws-refresh: no trace at %s\n' "${2:-}" >&2
		exit 2
	}
	listen <"$2"
	;;
'')
	socket="${XDG_RUNTIME_DIR:?}/hypr/${HYPRLAND_INSTANCE_SIGNATURE:?}/.socket2.sock"
	snapshot
	socat -u "UNIX-CONNECT:$socket" - | listen
	;;
*)
	printf 'Usage: ws-refresh.sh [--once | --replay FILE]\n' >&2
	exit 2
	;;
esac
