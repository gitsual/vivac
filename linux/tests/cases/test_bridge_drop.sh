#!/usr/bin/env bash
# The fakes are shell source written out literally: their $ expands when they run.
# shellcheck disable=SC2016
set -Eeuo pipefail

# The drop tray lives under the shared root, the folder of the shared settings
# file. What waits in drop/to-linux is counted (not the dot files and the
# desktop.ini a file manager leaves), announced once at session start with a
# click that opens it, and never moved; with shared_settings=none every action
# says so and does nothing else.

repo_root="${REPO_ROOT:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)}"
tool="$repo_root/dotfiles/bridge/.local/bin/vivac-drop"
# shellcheck source=lib/kv.sh
source "$repo_root/lib/kv.sh"
# shellcheck source=lib/settings.sh
source "$repo_root/lib/settings.sh"

fail() {
	printf '%s\n' "$1" >&2
	exit 1
}
sandbox="$(mktemp -d "${TMPDIR:-/tmp}/vivac-drop.XXXXXX")"
trap 'rm -rf -- "$sandbox"' EXIT
mkdir -p "$sandbox/bin" "$sandbox/cfg/vivac" "$sandbox/shared/drop/to-linux"
calls="$sandbox/calls"
# notify-send writes down its arguments and answers CLICK (the action name it
# would print); xdg-open writes down what it was asked to open.
printf '#!/usr/bin/env bash\nprintf "notify %%s\\n" "$*" >>"$CALLS"\nprintf "%%s\\n" "${CLICK:-}"\n' >"$sandbox/bin/notify-send"
printf '#!/usr/bin/env bash\nprintf "open %%s\\n" "$*" >>"$CALLS"\n' >"$sandbox/bin/xdg-open"
chmod +x "$sandbox/bin/"*
settings="$sandbox/cfg/vivac/settings"

drop() {
	PATH="$sandbox/bin:$PATH" CALLS="$calls" VIVAC_REPO="$repo_root" VIVAC_LANG=en HOME="$sandbox" \
		XDG_CONFIG_HOME="$sandbox/cfg" "$tool" "$@"
}
# The folder is opened in the background; give it a moment to say so.
opened() {
	local _
	for _ in 1 2 3 4 5 6 7 8 9 10; do
		grep -Fxq "open $1" "$calls" 2>/dev/null && return 0
		sleep 0.2
	done
	return 1
}

# --- the shared root is the folder of the shared file -----------------------------------------------------
printf 'shared_settings=%s\n' "$sandbox/shared/settings" >"$settings"
[[ "$(settings_shared_root "$settings")" == "$sandbox/shared" ]] || fail 'the shared root is not the folder of the shared file'
# shellcheck disable=SC2088  # the literal ~/ is the value under test
printf 'shared_settings=~/shared/settings\n' >"$settings"
[[ "$(HOME="$sandbox" settings_shared_root "$settings")" == "$sandbox/shared" ]] || fail 'a ~/ shared path did not expand'

# --- counting ------------------------------------------------------------------------------------------------------
[[ "$(drop --count)" == 0 ]] || fail 'an empty tray did not count 0'
: >"$sandbox/shared/drop/to-linux/.hidden"
: >"$sandbox/shared/drop/to-linux/desktop.ini"
: >"$sandbox/shared/drop/to-linux/Thumbs.db"
[[ "$(drop --count)" == 0 ]] || fail 'dot files and file-manager leftovers were counted'
: >"$calls"
drop --notify || fail 'the session-start pass failed with an empty tray'
[[ ! -s "$calls" ]] || fail "an empty tray notified: $(cat "$calls")"

printf 'one\n' >"$sandbox/shared/drop/to-linux/photo one.jpg"
[[ "$(drop --count)" == 1 ]] || fail 'one file did not count 1'
: >"$calls"
drop --notify || fail 'the session-start pass failed'
grep -q '^notify .*1 thing came from Windows' "$calls" || fail "one item was not announced in the singular: $(cat "$calls")"
grep -q -- '--action=open=Open' "$calls" || fail 'the notification has no click to open the tray'
grep -q '^open' "$calls" && fail 'the tray opened without a click'

mkdir "$sandbox/shared/drop/to-linux/a folder"
printf 'x\n' >"$sandbox/shared/drop/to-linux/notes.txt"
[[ "$(drop --count)" == 3 ]] || fail 'a folder and two files did not count 3'
: >"$calls"
CLICK=open drop --notify || fail 'the session-start pass failed with a click'
grep -q '^notify .*3 things came from Windows' "$calls" || fail "three items were not announced: $(cat "$calls")"
opened "$sandbox/shared/drop/to-linux" || fail "a click did not open the tray: $(cat "$calls")"
[[ "$(find "$sandbox/shared/drop/to-linux" -mindepth 1 -maxdepth 1 | wc -l)" == 6 ]] || fail 'something in the tray was moved or deleted'

# --- the menu actions open the folders, creating the outgoing one ----------------------------------------------
: >"$calls"
drop --open-out || fail 'Send to Windows failed'
[[ -d "$sandbox/shared/drop/to-windows" ]] || fail 'Send to Windows did not create drop/to-windows'
opened "$sandbox/shared/drop/to-windows" || fail 'Send to Windows did not open drop/to-windows'
: >"$calls"
drop --open-in || fail 'Drop tray failed'
opened "$sandbox/shared/drop/to-linux" || fail 'Drop tray did not open drop/to-linux'

# --- no shared folder: say so, do nothing else ------------------------------------------------------------------
for value in none "$sandbox/unmounted/settings"; do
	printf 'shared_settings=%s\n' "$value" >"$settings"
	: >"$calls"
	drop --notify 2>"$sandbox/err" || fail "the session-start pass failed with shared_settings=$value"
	[[ -s "$sandbox/err" ]] || fail "shared_settings=$value was not mentioned in the log"
	[[ ! -s "$calls" ]] || fail "shared_settings=$value notified at session start: $(cat "$calls")"
	if drop --open-out >/dev/null 2>&1; then fail "Send to Windows succeeded with shared_settings=$value"; fi
	grep -q '^notify ' "$calls" || fail "Send to Windows did not say why it did nothing (shared_settings=$value)"
	grep -q '^open' "$calls" && fail "something was opened with shared_settings=$value"
done
[[ ! -e "$sandbox/unmounted" ]] || fail 'a missing shared folder was created'
rm -f "$settings"
if drop --count 2>/dev/null; then fail 'no settings file at all still counted a tray'; fi

printf 'drop tray: shared root resolved, leftovers ignored, one notification with a click, nothing without a shared folder\n'
