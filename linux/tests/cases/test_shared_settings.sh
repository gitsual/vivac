#!/usr/bin/env bash
set -Eeuo pipefail

# Three keys (theme, weather_location, language) can be mirrored to an optional
# flat KV file that another OS also reads. The write goes through on a local
# change; the read happens once at session start and never writes back.

repo_root="${REPO_ROOT:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)}"
# shellcheck source=lib/kv.sh
source "$repo_root/lib/kv.sh"
# shellcheck source=lib/settings.sh
source "$repo_root/lib/settings.sh"
sync="$repo_root/scripts/sync-shared-settings.sh"

fail() {
	printf '%s\n' "$1" >&2
	exit 1
}
sandbox="$(mktemp -d "${TMPDIR:-/tmp}/vivac-shared.XXXXXX")"
trap 'rm -rf -- "$sandbox"' EXIT
mkdir -p "$sandbox/bin" "$sandbox/cfg/vivac" "$sandbox/shared"
export XDG_STATE_HOME="$sandbox/state"
local_file="$sandbox/cfg/vivac/settings"
shared="$sandbox/shared/settings"
calls="$sandbox/calls"
for tool in apply render; do
	printf '#!/bin/sh\necho %s >>"%s"\n' "$tool" "$calls" >"$sandbox/bin/$tool"
done
printf '#!/bin/sh\necho "reload $*" >>"%s"\n' "$calls" >"$sandbox/bin/pkill"
chmod +x "$sandbox/bin/"*

pull() {
	: >"$calls"
	PATH="$sandbox/bin:$PATH" HOME="$sandbox" XDG_CONFIG_HOME="$sandbox/cfg" XDG_STATE_HOME="$sandbox/state" \
		APPLY_THEME="$sandbox/bin/apply" RENDER_CONFIG="$sandbox/bin/render" \
		"$sync" --pull 2>"$sandbox/err"
}
stamp() { stat -c '%i %Y %s' "$1"; }

# --- the two new local keys are known and validated -----------------------------------------------------
settings_defaults
{ [[ "${SETTINGS[shared_settings]}" == none && "${SETTINGS[language]}" == auto ]]; } || fail 'defaults: shared_settings=none, language=auto'
{ settings_valid language es && settings_valid language auto; } || fail 'language: auto or a short code'
settings_valid language 'es;x' && fail 'language accepted shell metacharacters'
# shellcheck disable=SC2088  # the literal ~/ is the value under test
{ settings_valid shared_settings "~/m2/shared/settings" && settings_valid shared_settings /mnt/x/settings; } || fail 'shared_settings: absolute or ~/'
settings_valid shared_settings relative/path && fail 'shared_settings accepted a relative path'

# --- write-through: in place, foreign lines kept, LF only -----------------------------------------------
printf 'shared_settings=%s\n' "$shared" >"$local_file"
printf '\xef\xbb\xbfmod=lwin\r\ntheme=carmen\r\nzzz=1\r\n' >"$shared"
settings_write "$local_file" theme cosmos
[[ "$(cat "$shared")" == $'mod=lwin\ntheme=cosmos\nzzz=1' ]] || fail "shared file after a theme change: $(od -c "$shared" | head -3)"
before="$(stamp "$shared")"
settings_write "$local_file" theme cosmos
[[ "$(stamp "$shared")" == "$before" ]] || fail 'an unchanged value rewrote the shared file'
settings_write "$local_file" language es
[[ "$(cat "$shared")" == $'mod=lwin\ntheme=cosmos\nzzz=1\nlanguage=es' ]] || fail 'a new key was not appended after the foreign lines'
settings_write "$local_file" keymap us
grep -q keymap "$shared" && fail 'keymap leaked into the shared file'
settings_write "$local_file" xkb_layout us
grep -q xkb "$shared" && fail 'xkb_layout leaked into the shared file'
grep -q '^theme=cosmos$' "$local_file" || fail 'the local file lost the theme'

# --- nothing is written when sharing is off or the folder is gone ----------------------------------
printf 'theme=carmen\n' >"$local_file"
settings_write "$local_file" theme cosmos
{ [[ "$(cat "$shared")" == *theme=cosmos* && "$(grep -c . "$shared")" == 4 ]]; } || fail 'shared_settings=none (unset) wrote to the shared file'
printf 'shared_settings=%s\n' "$sandbox/unmounted/settings" >"$local_file"
settings_write "$local_file" theme carmen
[[ ! -e "$sandbox/unmounted" ]] || fail 'a missing parent folder was created'
grep -q '^theme=carmen$' "$local_file" || fail 'the local write failed with the shared folder missing'
printf 'shared_settings=%s\n' "$sandbox/shared/missing-file" >"$local_file"
settings_write "$local_file" theme carmen
settings_write "$local_file" theme 'bad value' 2>/dev/null && fail 'an invalid value was written'

# --- pull: absence is silent -----------------------------------------------------------------------------------
rm -f "$local_file"
pull || fail 'pull failed with no settings at all'
printf 'shared_settings=%s\n' "$sandbox/shared/absent" >"$local_file"
pull || fail 'pull failed with the shared file missing'
{ [[ ! -s "$sandbox/err" && ! -s "$calls" && ! -e "$sandbox/shared/absent" ]]; } || fail 'a missing shared file was not silent or was created'

# --- pull: the other OS changed the theme ------------------------------------------------------------------
printf 'shared_settings=%s\ntheme=carmen\nkeymap=es\n' "$shared" >"$local_file"
printf 'mod=lwin\r\ntheme=cosmos\r\nkeymap=us\r\n' >"$shared"
before="$(stamp "$shared")"
pull || fail 'pull failed'
grep -q '^theme=cosmos$' "$local_file" || fail 'the shared theme did not reach the local file'
grep -q '^keymap=es$' "$local_file" || fail 'the shared file changed the local keymap'
[[ "$(cat "$calls")" == apply ]] || fail "expected exactly one apply-theme run, saw: $(cat "$calls")"
[[ "$(stamp "$shared")" == "$before" ]] || fail 'the pull wrote to the shared file'
# Equal values: no write, no render.
before="$(stamp "$local_file")"
pull
{ [[ ! -s "$calls" && "$(stamp "$local_file")" == "$before" ]]; } || fail 'equal values caused a write or a reload'

# --- pull: location re-renders, language does nothing -------------------------------------------------
printf 'theme=cosmos\nweather_location=Lisbon\nlanguage=es\n' >"$shared"
pull
[[ "$(cat "$calls")" == $'render\nreload -SIGUSR2 -x waybar' ]] || fail "location change: $(cat "$calls")"
grep -q '^language=es$' "$local_file" || fail 'language was not applied'
printf 'language=en\n' >"$shared"
pull
{ [[ ! -s "$calls" ]] && grep -q '^language=en$' "$local_file"; } || fail 'a language change triggered a reload'

# --- pull: bad values are rejected one by one --------------------------------------------------------------
printf 'theme=not-a-theme\nlanguage=xx\nweather_location=Porto\n' >"$shared"
pull || fail 'a bad shared value made the pull fail'
{ grep -q 'theme' "$sandbox/err" && grep -q 'language' "$sandbox/err"; } || fail "warnings do not name the keys: $(cat "$sandbox/err")"
{ grep -q '^theme=cosmos$' "$local_file" && grep -q '^weather_location=Porto$' "$local_file"; } || fail 'a bad key stopped the good ones'
printf '\x00\xff\x01garbage\nno-equals\ntheme=\x01\n=x\n' >"$shared"
before="$(stamp "$local_file")"
pull || fail 'a garbled file crashed the pull'
[[ "$(stamp "$local_file")" == "$before" ]] || fail 'a garbled file changed local settings'

# --- a change made while the shared folder is away is kept and sent later -----------------------------------
pending="$sandbox/state/vivac/shared-pending"
offline="$sandbox/offline-share"
rm -rf "$sandbox/state" "$offline"
printf 'shared_settings=%s\ntheme=carmen\n' "$offline/settings" >"$local_file"
settings_write "$local_file" theme cosmos 2>"$sandbox/err"
[[ ! -e "$offline" ]] || fail 'the absent shared folder was created'
grep -q '^theme=cosmos$' "$local_file" || fail 'the offline change did not reach the local file'
grep -qx theme "$pending" || fail 'the skipped shared write was not recorded as pending'
{ [[ "$(grep -c . "$sandbox/err")" == 1 ]] && grep -qi theme "$sandbox/err"; } || fail "expected exactly one warning naming the key: $(cat "$sandbox/err")"
settings_write "$local_file" theme gatsby 2>"$sandbox/err"
[[ ! -s "$sandbox/err" ]] || fail "the same key warned twice: $(cat "$sandbox/err")"
[[ "$(grep -c theme "$pending")" == 1 ]] || fail 'the pending list holds a key twice'
settings_write "$local_file" language es 2>/dev/null
[[ "$(sort "$pending" | tr '\n' ' ')" == 'language theme ' ]] || fail "pending keys: $(cat "$pending")"
# The share comes back with the other OS's older value: the local choice wins and is sent.
mkdir -p "$offline"
printf 'mod=lwin\ntheme=carmen\nlanguage=en\n' >"$offline/settings"
pull || fail 'pull with pending keys failed'
grep -q '^theme=gatsby$' "$local_file" || fail "the shared value overwrote a pending local key: $(cat "$local_file")"
[[ "$(cat "$offline/settings")" == $'mod=lwin\ntheme=gatsby\nlanguage=es' ]] || fail "pending keys were not pushed: $(cat "$offline/settings")"
[[ ! -s "$calls" ]] || fail "pushing pending keys reloaded the desktop: $(cat "$calls")"
{ [[ ! -s "$pending" ]]; } || fail "pending was not cleared after the push: $(cat "$pending")"
# Pending cleared: the next change by the other OS is taken like any other.
printf 'mod=lwin\ntheme=cosmos\nlanguage=es\n' >"$offline/settings"
pull
grep -q '^theme=cosmos$' "$local_file" || fail 'after the push the shared file no longer wins'
# A push that cannot be written keeps the key pending and keeps the local value.
rm -f "$pending"
printf 'shared_settings=%s\ntheme=carmen\n' "$offline/settings" >"$local_file"
printf 'theme=cosmos\n' >"$offline/settings"
printf 'theme\n' >"$pending"
chmod 500 "$offline"
pull
chmod 700 "$offline"
{ grep -q '^theme=carmen$' "$local_file" && grep -qx theme "$pending"; } || fail 'a failed push lost the pending key or took the shared value'
pull
[[ "$(cat "$offline/settings")" == 'theme=carmen' && ! -s "$pending" ]] || fail 'the pending key was not pushed once the folder was writable'
# A pending key with the share present but no shared file yet creates it.
printf 'theme\n' >"$pending"
mkdir -p "$offline/fresh-dir"
printf 'shared_settings=%s\ntheme=cosmos\n' "$offline/fresh-dir/settings" >"$local_file"
pull
[[ "$(cat "$offline/fresh-dir/settings")" == 'theme=cosmos' ]] || fail 'a pending key did not create the shared file'
# An existing but empty folder (an unmounted mountpoint looks like this) cannot be told from a
# present one: the write goes through. Only a MISSING folder is treated as away.
rm -f "$pending"
mkdir -p "$sandbox/mountpoint"
printf 'shared_settings=%s\n' "$sandbox/mountpoint/settings" >"$local_file"
settings_write "$local_file" theme carmen
[[ "$(cat "$sandbox/mountpoint/settings")" == 'theme=carmen' && ! -e "$pending" ]] || fail 'an existing empty folder was treated as away'

# --- the lock really excludes: a busy pull gives up, a busy write defers -----------------------------------
lockfile="$sandbox/state/vivac/shared-sync.lock"
mkdir -p "$sandbox/state/vivac" "$sandbox/lockshare"
printf 'shared_settings=%s\ntheme=carmen\n' "$sandbox/lockshare/settings" >"$local_file"
printf 'theme=cosmos\n' >"$sandbox/lockshare/settings"
rm -f "$pending" "$sandbox/held"
(
	flock -x 9
	: >"$sandbox/held"
	sleep 6
) 9>"$lockfile" &
holder=$!
until [[ -e "$sandbox/held" ]]; do sleep 0.1; done
before="$(stamp "$local_file")"
start=$SECONDS
VIVAC_SYNC_LOCK_WAIT=1 pull || fail 'a pull that could not get the lock failed'
((SECONDS - start < 5)) || fail 'the pull waited for the lock past its configured wait'
{ [[ "$(stamp "$local_file")" == "$before" && ! -s "$calls" ]]; } || fail 'a pull without the lock changed settings or reloaded'
VIVAC_SETTINGS_LOCK_WAIT=1 settings_write "$local_file" theme gatsby 2>"$sandbox/err"
grep -q '^theme=gatsby$' "$local_file" || fail 'a busy lock lost the local change'
[[ "$(cat "$sandbox/lockshare/settings")" == 'theme=cosmos' ]] || fail 'a write went through without holding the lock'
grep -qx theme "$pending" || fail 'a write that could not lock was not recorded as pending'
wait "$holder"
pull
[[ "$(cat "$sandbox/lockshare/settings")" == 'theme=gatsby' ]] || fail 'the deferred write was not sent after the lock was released'
# Two session starts at once: the change is applied once.
printf 'shared_settings=%s\ntheme=carmen\n' "$sandbox/lockshare/settings" >"$local_file"
printf 'theme=cosmos\n' >"$sandbox/lockshare/settings"
printf '#!/bin/sh\nsleep 1\necho apply >>"%s"\n' "$calls" >"$sandbox/bin/slowapply"
chmod +x "$sandbox/bin/slowapply"
: >"$calls"
for _ in 1 2; do
	PATH="$sandbox/bin:$PATH" HOME="$sandbox" XDG_CONFIG_HOME="$sandbox/cfg" XDG_STATE_HOME="$sandbox/state" \
		APPLY_THEME="$sandbox/bin/slowapply" RENDER_CONFIG="$sandbox/bin/render" "$sync" --pull 2>/dev/null &
done
wait
[[ "$(grep -c apply "$calls")" == 1 ]] || fail "two concurrent pulls applied the change $(grep -c apply "$calls") times"

printf 'shared settings: write-through, pull, validation, absence silent\n'
