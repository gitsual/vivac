#!/usr/bin/env bash
# Print one Waybar workspace button, or the whole strip, from the workspace cache.
#
#   ws-render.sh N   button N (1..10): what custom/wsN shows; its class is
#                    active, urgent, occupied or empty so the stylesheet can
#                    tell them apart, and its tooltip lists only its windows
#   ws-render.sh     the ten buttons joined, as one strip (tests, debugging)
#
# Every one of the ten workspaces is a button carrying its number; an
# occupied one adds one glyph per window, an empty one shows the number
# alone. The active workspace is bold and underlined, an urgent one bold
# and italic, so the two never rely on colour alone. Nothing a window
# controls (class, title) reaches the markup: glyphs come from the catalogue
# and titles go to the tooltip HTML-escaped.
#
# Reads: WS_CACHE (default $XDG_RUNTIME_DIR/waybar-ws.json, written by
# ws-refresh.sh), WS_ICONS (default ~/.config/waybar/workspace-icons.json).
set -Eeuo pipefail

cache="${WS_CACHE:-${XDG_RUNTIME_DIR:-/tmp}/waybar-ws.json}"
icons="${WS_ICONS:-${XDG_CONFIG_HOME:-$HOME/.config}/waybar/workspace-icons.json}"

only="${1:-}"
if [[ -n "$only" && ! "$only" =~ ^([1-9]|10)$ ]]; then
	printf 'ws-render: workspace must be 1..10, got %s\n' "$only" >&2
	exit 2
fi

if [[ ! -r "$cache" ]]; then
	# Before the first event every button is its number, never blank.
	if [[ -n "$only" ]]; then
		printf '{"text": "%s", "tooltip": "no workspace state yet", "class": "empty"}\n' "$only"
	else
		printf '{"text": "%s", "tooltip": "no workspace state yet", "class": "ws"}\n' "$(printf '%s  ' 1 2 3 4 5 6 7 8 9 10 | sed 's/  $//')"
	fi
	exit 0
fi

jq -c --slurpfile catalogue "$icons" --arg only "$only" '
	$catalogue[0] as $cat
	| def by_prefix($table; $name):
		[ $table | to_entries[] | .key as $k | select(($name | type) == "string" and ($name | startswith($k))) ]
		| sort_by(-(.key | length)) | .[0].value;
	def lookup($name):
		if ($name | type) != "string" or $name == "" then null
		else ($cat.classes[$name] // by_prefix($cat.prefixes; $name)) end;
	def by_title($title):
		if ($title | type) != "string" then null
		else ([ $cat.titles | to_entries[] | .key as $k | select($title | contains($k)) ] | .[0].value) end;
	def icon_for($w):
		lookup($w.initialClass) // lookup($w.class) // by_title($w.title) // $cat.default;
	. as $state
	| def button($n):
		([ $state.workspaces[]? | select(.id == $n) ] | .[0]) as $w
		| ($w.windows // []) as $windows
		| (($n | tostring) + (if ($windows | length) > 0 then " " + ([ $windows[] | icon_for(.) ] | join(" ")) else "" end)) as $label
		| if $n == $state.active then { markup: ("<span weight=\"bold\" underline=\"single\">" + $label + "</span>"), class: "active" }
		  elif ($w.urgent // false) then { markup: ("<span weight=\"bold\" style=\"italic\">" + $label + "</span>"), class: "urgent" }
		  elif ($windows | length) > 0 then { markup: $label, class: "occupied" }
		  else { markup: $label, class: "empty" } end
		| . + { tooltip: ([ $windows[] | (.title // "") | @html ] | join(", ")) };
	if $only != "" then
		button($only | tonumber) | { text: .markup, tooltip: .tooltip, class: .class }
	else
	[ range(1; 11) as $n | button($n).markup ] as $buttons
	| {
		text: ($buttons | join("  ")),
		tooltip: ([ $state.workspaces[]? | select(.id >= 1 and .id <= 10) | select((.windows | length) > 0)
			| (.id | tostring) + ": " + ([ .windows[] | (.title // "") | @html ] | join(", ")) ] | join("\n")),
		class: (if ([ $state.workspaces[]? | select(.urgent // false) ] | length) > 0 then "ws urgent" else "ws" end)
	  }
	end' "$cache"
