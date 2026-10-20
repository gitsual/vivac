#!/usr/bin/env bash
# The help registry: which keys exist, in which pane, what they do.
#
# A pane is rendered from three sources that never mix roles: the registry
# (data/help-registry.tsv) says which key does what, the i18n table says how
# to describe it, and, for the Hyprland pane, `hyprctl binds -j` says what is
# actually bound right now. A live bind with no registry row renders as
# UNREGISTERED instead of vanishing, so drift is visible in the pane itself
# and refused by scripts/check-help-registry.sh at check time. A description
# is text: it is printed, never executed, never passed to a command.
#
# Sourced, not executed. Requires lib/kv.sh and lib/i18n.sh loaded by the
# caller; the live pane requires jq.

# shellcheck disable=SC2034  # arrays are read by callers through their names
declare -ga HELP_ROWS=()
declare -gA HELP_PANE=() HELP_TYPE=() HELP_VALUE=() HELP_LABEL=()
HELP_PANES='hypr browser shell editor system'
HELP_TYPES='exec dispatch doc'

# help_load_registry FILE — rows are keyed "pane/bind_id"; order is kept.
help_load_registry() {
	local file="$1" line key
	local -a cols
	HELP_ROWS=() HELP_PANE=() HELP_TYPE=() HELP_VALUE=() HELP_LABEL=()
	[[ -r "$file" ]] || {
		printf 'help: cannot read registry %s\n' "$file" >&2
		return 1
	}
	while IFS= read -r line || [[ -n "$line" ]]; do
		[[ -z "$line" || "$line" == '#'* ]] && continue
		mapfile -t -d $'\t' cols < <(printf '%s' "$line")
		[[ ${#cols[@]} -eq 5 ]] || {
			printf 'help: registry row does not have 5 columns: %q\n' "$line" >&2
			return 1
		}
		[[ " $HELP_PANES " == *" ${cols[1]} "* ]] || {
			printf 'help: unknown pane %q\n' "${cols[1]}" >&2
			return 1
		}
		[[ " $HELP_TYPES " == *" ${cols[2]} "* ]] || {
			printf 'help: unknown action type %q\n' "${cols[2]}" >&2
			return 1
		}
		key="${cols[1]}/${cols[0]}"
		[[ -v HELP_PANE["$key"] ]] && {
			printf 'help: duplicate row for %s\n' "$key" >&2
			return 1
		}
		HELP_ROWS+=("$key")
		HELP_PANE["$key"]="${cols[1]}"
		HELP_TYPE["$key"]="${cols[2]}"
		HELP_VALUE["$key"]="${cols[3]}"
		HELP_LABEL["$key"]="${cols[4]}"
	done <"$file"
}

# help_bind_id MODS KEY — the registry id of a bind line: modifiers joined
# with +, then the key. "SUPER SHIFT" S -> SUPER+SHIFT+S; "" F1 -> F1.
help_bind_id() {
	local mods="$1" key="$2" id=''
	local -a parts
	read -ra parts <<<"$mods"
	((${#parts[@]})) && id="$(
		IFS=+
		printf '%s+' "${parts[*]}"
	)"
	printf '%s%s' "$id" "$key"
}

# help_lua_bind_id LINE — read one line of a Lua Hyprland config. The key of a
# bind must be a literal on its own line, `hl.bind("SUPER + SHIFT + S", ...)`
# starting in column 0, so it can be read without running Lua. rc 0: a literal
# bind, its registry id in HELP_LUA_ID. rc 1: not a bind (comments included).
# rc 2: a bind whose key is built, indented or nested; callers refuse it.
help_lua_bind_id() {
	local line="$1" spec
	local -a parts
	HELP_LUA_ID=''
	[[ "$line" != --* && "$line" == *'hl.bind('* ]] || return 1
	[[ "$line" =~ ^hl\.bind\(\"([A-Za-z0-9_:\ +]+)\"\, ]] || return 2
	spec="${BASH_REMATCH[1]// + / }"
	read -ra parts <<<"$spec"
	((${#parts[@]})) || return 2
	HELP_LUA_ID="$(help_bind_id "${parts[*]:0:${#parts[@]}-1}" "${parts[-1]}")"
}

# help_live_bind_ids JSON_FILE — the ids of every bind Hyprland reports,
# derived from its modmask in the same order the registry uses.
help_live_bind_ids() {
	jq -r '
		def mods: [ (if (. / 64 | floor) % 2 == 1 then "SUPER" else empty end),
		            (if (. / 4 | floor) % 2 == 1 then "CTRL" else empty end),
		            (if (. / 8 | floor) % 2 == 1 then "ALT" else empty end),
		            (if . % 2 == 1 then "SHIFT" else empty end) ];
		.[] | ((.modmask | mods) + [.key]) | join("+")' "$1"
}

# help_render PANE [LIVE_JSON] — one line per key: "id<TAB>description".
# Registry rows of the pane first, in registry order; then, when a live
# bind list is given, every live bind without a row, marked UNREGISTERED.
help_render() {
	local pane="$1" live="${2:-}" key id label
	for key in "${HELP_ROWS[@]}"; do
		[[ "${HELP_PANE["$key"]}" == "$pane" ]] || continue
		label="$(i18n_get "${HELP_LABEL["$key"]}")" || true
		printf '%s\t%s\n' "${key#*/}" "$label"
	done
	[[ -n "$live" ]] || return 0
	while IFS= read -r id; do
		[[ -v HELP_PANE["$pane/$id"] ]] || printf '%s\tUNREGISTERED\n' "$id"
	done < <(help_live_bind_ids "$live")
}
