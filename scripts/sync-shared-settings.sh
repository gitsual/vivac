#!/usr/bin/env bash
set -Eeuo pipefail

# Session start: bring the other OS's choices in.
#
#   scripts/sync-shared-settings.sh --pull
#
# Reads the optional shared KV file (the `shared_settings` key of the local
# settings names it) and applies the theme, weather location and UI language
# found there. It only ever reads that file: the change path in
# lib/settings.sh is its one writer. Foreign keys (the other OS has its own),
# CR, a BOM and malformed lines are ignored; a value that fails validation is
# reported and skipped without stopping the rest. No sharing configured, or no
# file there, is silence and status 0. Equal values change and reload nothing.

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
# shellcheck source=lib/kv.sh
source "$repo_root/lib/kv.sh"
# shellcheck source=lib/settings.sh
source "$repo_root/lib/settings.sh"

[[ "${1:-}" == --pull && $# -eq 1 ]] || {
	printf 'Usage: scripts/sync-shared-settings.sh --pull\n' >&2
	exit 2
}

settings_file="${SETTINGS_FILE:-${XDG_CONFIG_HOME:-$HOME/.config}/vivac/settings}"
state_dir="${XDG_STATE_HOME:-$HOME/.local/state}/vivac"

shared="$(settings_shared_path "$settings_file")" || exit 0
[[ -f "$shared" && -r "$shared" ]] || exit 0

# One pull at a time: a second session start must not interleave its writes.
mkdir -p -- "$state_dir"
exec 9>"$state_dir/shared-sync.lock"
flock -w 60 9 || exit 0

settings_load "$settings_file" || exit 0

# acceptable KEY VALUE — the shape, plus what only this checkout can know.
acceptable() {
	settings_valid "$1" "$2" || return 1
	case "$1" in
	theme) [[ "$2" == bad-romance || -f "$repo_root/data/themes/$2.conf" ]] ;;
	language) [[ "$2" == auto || -f "$repo_root/i18n/$2.conf" ]] ;;
	esac
}

declare -A incoming=()
first=1
while IFS= read -r line; do
	((first)) && line="${line#$'\xef\xbb\xbf'}"
	first=0
	for key in "${SETTINGS_SHARED_KEYS[@]}"; do
		[[ "$line" == "$key="* ]] && incoming["$key"]="${line#*=}"
	done
done < <(LC_ALL=C tr -d '\r\000' <"$shared")

changed=()
for key in "${!incoming[@]}"; do
	value="${incoming["$key"]}"
	acceptable "$key" "$value" || {
		printf 'sync-shared-settings: ignoring %s in %s: %q is not valid\n' "$key" "$shared" "$value" >&2
		continue
	}
	[[ "$value" == "${SETTINGS["$key"]}" ]] && continue
	settings_write_local "$settings_file" "$key" "$value"
	changed+=("$key")
done

has_changed() { [[ " ${changed[*]} " == *" $1 "* ]]; }
if has_changed theme; then
	"${APPLY_THEME:-$repo_root/scripts/apply-theme.sh}" || printf 'sync-shared-settings: apply-theme failed\n' >&2
elif has_changed weather_location; then
	"${RENDER_CONFIG:-$repo_root/scripts/render-config.sh}" --deploy >/dev/null || printf 'sync-shared-settings: render failed\n' >&2
	pkill -SIGUSR2 -x waybar >/dev/null 2>&1 || true
fi
exit 0
