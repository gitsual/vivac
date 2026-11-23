#!/usr/bin/env bash
# Keep the bar up: start Waybar again when it dies, as windows/bin/vivac-bar-watch.ps1
# does for Zebar. Hyprland starts this instead of waybar itself.
#
# Every KEEP_INTERVAL seconds (3) it looks for a waybar of this user and starts
# one when there is none; a bar started by hand or reloaded with SIGUSR2 is left
# alone. A bar that dies KEEP_MAX_RESTARTS times (5) in a row without ever being
# seen running is given up on for KEEP_BACKOFF rounds (100, about five minutes),
# with one notice, so a broken config does not flash the bar forever. One keeper
# per session: a second one steps aside (flock on KEEP_LOCK).
#
# For tests: WAYBAR_BIN, KEEP_ROUNDS (stop after that many checks), KEEP_LOCK.
set -Eeuo pipefail

bin="${WAYBAR_BIN:-waybar}"
interval="${KEEP_INTERVAL:-3}"
max="${KEEP_MAX_RESTARTS:-5}"
backoff="${KEEP_BACKOFF:-100}"
rounds="${KEEP_ROUNDS:-0}"
lock="${KEEP_LOCK:-${XDG_RUNTIME_DIR:-/tmp}/waybar-keep.lock}"

self="$(readlink -f -- "${BASH_SOURCE[0]}")"
repo="${VIVAC_REPO:-$(cd -- "$(dirname -- "$self")/../../../../.." && pwd -P)}"
# shellcheck source=lib/i18n.sh
source "$repo/lib/i18n.sh"
language="${VIVAC_LANG:-${LANG:-en}}"
language="${language%%[._@]*}"
i18n_load "$language" "${I18N_DIR:-$repo/i18n}" 2>/dev/null || i18n_load en "${I18N_DIR:-$repo/i18n}" 2>/dev/null || true

exec 9>"$lock"
flock -n 9 || exit 0

restarts=0 quiet=0 round=0 told=0
while :; do
	if ((rounds)); then
		((round++ < rounds)) || break
	fi
	if ((quiet > 0)); then
		((quiet--)) || true
	elif pgrep -u "$(id -u)" -x waybar >/dev/null 2>&1; then
		restarts=0
	elif ((restarts >= max)); then
		if ((!told)); then
			notify-send -u critical -a vivac "$(i18n_get bar.keep_title)" "$(i18n_format bar.keep_gave_up "$max")" || true
			told=1
		fi
		restarts=0 quiet=$backoff
	else
		setsid -f "$bin" >/dev/null 2>&1 || true
		((++restarts))
	fi
	sleep "$interval"
done
