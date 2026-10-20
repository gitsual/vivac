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

# --- the pull is serialised --------------------------------------------------------------------------------------
grep -q 'flock' "$sync" || fail 'the pull is not serialised'
printf 'shared settings: write-through, pull, validation, absence silent\n'
