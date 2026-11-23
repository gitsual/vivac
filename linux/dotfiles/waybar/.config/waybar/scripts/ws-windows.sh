#!/usr/bin/env bash
# The windows of one workspace, to jump to one: what a window's glyph on the
# Windows bar does with a click (windows/static/zebar/vivac/bar.js). A Waybar
# module cannot tell which of its glyphs was clicked, so a right click on a
# workspace lists its windows instead, each with its application's icon, and
# the chosen one is focused (on that workspace).
#
#   ws-windows.sh N           pick among workspace N's windows (rofi)
#   ws-windows.sh N --print   the rows the picker would show, one per line
#
# One window goes straight to it; none goes to the workspace.
set -Eeuo pipefail

self="$(readlink -f -- "${BASH_SOURCE[0]}")"
# dispatch.sh speaks to the compositor in whichever config language it runs.
dispatch="${WS_DISPATCH:-$(dirname -- "$self")/../../../../hypr/.config/hypr/scripts/dispatch.sh}"

n="${1:-}"
[[ "$n" =~ ^([1-9]|10)$ ]] || {
	printf 'ws-windows: workspace must be 1..10, got %s\n' "$n" >&2
	exit 2
}
clients="$(hyprctl clients -j 2>/dev/null || echo '[]')"
# address<TAB>class<TAB>title, in focus order (most recent first).
mapfile -t rows < <(jq -r --argjson n "$n" '
	[.[] | select(.workspace.id == $n and .mapped != false)]
	| sort_by(.focusHistoryID) | .[]
	| [.address, (.class // ""), ((.title // "") | gsub("[\t\n]"; " "))] | @tsv' <<<"$clients")

if [[ "${2:-}" == "--print" ]]; then
	for r in "${rows[@]}"; do
		IFS=$'\t' read -r _ class title <<<"$r"
		printf '%s — %s\n' "$class" "$title"
	done
	exit 0
fi

if ((${#rows[@]} == 0)); then
	exec "$dispatch" workspace "$n"
fi
pick=0
if ((${#rows[@]} > 1)); then
	pick="$(for r in "${rows[@]}"; do
		IFS=$'\t' read -r _ class title <<<"$r"
		printf '%s\0icon\x1f%s\n' "$title" "${class,,}"
	done | rofi -dmenu -i -format i -show-icons -p "$n" -no-custom)" || exit 0
fi
IFS=$'\t' read -r address _ <<<"${rows[$pick]}"
exec "$dispatch" focuswindow "address:$address"
