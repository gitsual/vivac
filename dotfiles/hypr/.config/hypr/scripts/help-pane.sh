#!/usr/bin/env bash
# Show one help pane: the keys of Hyprland, the browser, the shell, the
# editor or the system, described in the session language.
#
#   --pane hypr|browser|shell|editor|system   which pane (required)
#   --lang LANG                               table to use (default: $LANG)
#   --plain                                   print to stdout instead of rofi
#
# Runs from the stowed symlink: the registry, the tables and the libraries
# are read from the checkout the symlink points into. Selecting a row acts
# on the registry's action_value, never on the description: exec through
# Hyprland's own exec dispatcher, dispatch through lib/hypr-ipc.sh (so it
# works under hyprlang and Lua), doc opens the
# file. A live bind Hyprland has that the registry lacks shows UNREGISTERED.
set -Eeuo pipefail

self="$(readlink -f -- "${BASH_SOURCE[0]}")"
repo_root="${HELP_REPO_ROOT:-$(cd -- "$(dirname -- "$self")/../../../../.." && pwd -P)}"
# shellcheck source=lib/kv.sh
source "$repo_root/lib/kv.sh"
# shellcheck source=lib/i18n.sh
source "$repo_root/lib/i18n.sh"
# shellcheck source=lib/hypr-ipc.sh
source "$repo_root/lib/hypr-ipc.sh"
# shellcheck source=lib/help.sh
source "$repo_root/lib/help.sh"

pane='' plain=false
language="${VIVAC_LANG:-${LANG:-en}}"
while (($#)); do
	case "$1" in
	--pane)
		pane="${2:-}"
		shift
		;;
	--lang)
		language="${2:-}"
		shift
		;;
	--plain) plain=true ;;
	-h | --help)
		sed -n '2,15p' "$self"
		exit 0
		;;
	*)
		printf 'Unknown option: %s\n' "$1" >&2
		exit 2
		;;
	esac
	shift
done
[[ " $HELP_PANES " == *" $pane "* ]] || {
	printf 'help-pane: --pane must be one of: %s\n' "$HELP_PANES" >&2
	exit 2
}
language="${language%%[._@]*}"
i18n_load "$language" "${I18N_DIR:-$repo_root/i18n}" 2>/dev/null || i18n_load en "${I18N_DIR:-$repo_root/i18n}"
help_load_registry "${HELP_REGISTRY:-$repo_root/data/help-registry.tsv}"

live=''
if [[ "$pane" == hypr ]]; then
	if [[ -n "${HELP_BINDS_JSON:-}" ]]; then
		live="$HELP_BINDS_JSON"
	elif [[ -n "${HYPRLAND_INSTANCE_SIGNATURE:-}" ]] && command -v hyprctl >/dev/null; then
		live="$(mktemp)"
		trap 'rm -f -- "$live"' EXIT
		hyprctl binds -j >"$live" || live=''
	fi
fi

rendered="$(help_render "$pane" "$live")"
if $plain; then
	printf '%s\n' "$rendered"
	exit 0
fi

# Interactive: rofi shows "id  description"; the id alone selects the row.
choice="$(printf '%s\n' "$rendered" | awk -F'\t' '{ printf "%-24s %s\n", $1, $2 }' | rofi -dmenu -i -p "$pane keys")" || exit 0
id="${choice%% *}"
key="$pane/$id"
[[ -v HELP_TYPE["$key"] ]] || exit 0
case "${HELP_TYPE["$key"]}" in
exec) hypr_dispatch exec -- "${HELP_VALUE["$key"]}" >/dev/null ;;
dispatch)
	# shellcheck disable=SC2086  # the value is "dispatcher args" from the registry
	hypr_dispatch ${HELP_VALUE["$key"]} >/dev/null
	;;
doc) xdg-open "$repo_root/${HELP_VALUE["$key"]%%#*}" ;;
esac
