#!/usr/bin/env bash
# The fakes are shell source written out literally: their $ expands when they run.
# shellcheck disable=SC2016
set -Eeuo pipefail

# vivac-panel sound, its backend without a display: a sink's monitor is not
# an input, the default device is the one pactl names, an application's
# several streams are one entry at its loudest level and move together, and
# notification sounds (media.role=event) are not an application.

repo_root="${REPO_ROOT:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)}"
fail() {
	printf '%s\n' "$1" >&2
	exit 1
}
sandbox="$(mktemp -d "${TMPDIR:-/tmp}/vivac-sound.XXXXXX")"
trap 'rm -rf -- "$sandbox"' EXIT
mkdir -p "$sandbox/bin"
cat >"$sandbox/bin/pactl" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$SANDBOX/calls"
case "$*" in
"get-default-sink") echo speakers ;;
"get-default-source") echo mic ;;
"-f json list sinks") echo '[{"index":1,"name":"speakers","description":"Speakers","mute":false,"volume":{"front-left":{"value_percent":"40%"},"front-right":{"value_percent":"42%"}}},{"index":2,"name":"hdmi","description":"HDMI","mute":true,"volume":{"mono":{"value_percent":"70%"}}}]' ;;
"-f json list sources") echo '[{"index":3,"name":"speakers.monitor","description":"Monitor of Speakers","monitor_of_sink":"speakers","volume":{}},{"index":4,"name":"mic","description":"Mic","monitor_of_sink":"n/a","mute":false,"volume":{"mono":{"value_percent":"80%"}}}]' ;;
"-f json list sink-inputs") echo '[{"index":10,"mute":false,"volume":{"l":{"value_percent":"30%"}},"properties":{"application.name":"Firefox","application.icon_name":"firefox"}},{"index":11,"mute":false,"volume":{"l":{"value_percent":"55%"}},"properties":{"application.name":"Firefox"}},{"index":12,"mute":false,"volume":{"l":{"value_percent":"100%"}},"properties":{"application.name":"dunst","media.role":"event"}}]' ;;
esac
FAKE
chmod +x "$sandbox/bin/pactl"
export SANDBOX="$sandbox" VIVAC_PACTL="$sandbox/bin/pactl"

out="$(/usr/bin/python3 - "$repo_root/lib" <<'PY'
import sys
sys.path.insert(0, sys.argv[1])
from vivacpanel import sound
outs, ins, apps = sound.devices("sink"), sound.devices("source"), sound.apps()
print("outs", [(d.name, d.volume, d.muted, d.default) for d in outs])
print("ins", [(d.name, d.default) for d in ins])
print("apps", [(a.name, a.volume, a.streams, a.icon) for a in apps])
sound.set_app_volume(apps[0], 64)
sound.set_app_mute(apps[0], True)
sound.set_default("sink", "hdmi")
print("short", sound.short("Starship/Matisse HD Audio Controller Estéreo analógico"))
PY
)"
grep -qF "outs [('speakers', 42, False, True), ('hdmi', 70, True, False)]" <<<"$out" || fail "sinks: $out"
grep -qF "ins [('mic', True)]" <<<"$out" || fail "a monitor was taken for an input: $out"
grep -qF "apps [('Firefox', 55, [10, 11], 'firefox')]" <<<"$out" || fail "streams not grouped by application: $out"
grep -qF "short Starship/Matisse · Estéreo analógico" <<<"$out" || fail "device name not shortened: $out"
for call in "set-sink-input-volume 10 64%" "set-sink-input-volume 11 64%" "set-sink-input-mute 10 1" "set-sink-input-mute 11 1" "set-default-sink hdmi"; do
	grep -qxF "$call" "$sandbox/calls" || fail "missing pactl call: $call"
done
printf 'ok: sound panel backend\n'
