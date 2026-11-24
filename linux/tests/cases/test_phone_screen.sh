#!/usr/bin/env bash
# The fakes are shell source written out literally: their $ expands when they run.
# shellcheck disable=SC2016
set -Eeuo pipefail

# The phone as one more screen (vivac-phone-screen): against fake adb,
# hyprctl, wayvnc and waybar. On: a virtual monitor VIVAC-PHONE is created
# right of the monitors there are, at the phone's size and a scale it reads
# well at; those monitors are pinned where they were; workspaces 11-20 are
# the phone's and 1-10 stay on the computer's monitor; the phone gets its own
# bar; the screen is served on 127.0.0.1 only and reaches the phone over USB
# (adb reverse), where the viewer opens. Off (again, or the phone unplugged):
# all of it undone. No phone, nothing is created. SUPER+ALT+number goes to
# the phone's workspaces.

repo_root="${REPO_ROOT:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)}"
tool="$repo_root/dotfiles/bridge/.local/bin/vivac-phone-screen"
fail() {
	printf '%s\n' "$1" >&2
	exit 1
}
sandbox="$(mktemp -d "${TMPDIR:-/tmp}/vivac-screen.XXXXXX")"
trap 'rm -rf -- "$sandbox"' EXIT
mkdir -p "$sandbox/bin" "$sandbox/run"
calls="$sandbox/calls"
cat >"$sandbox/bin/adb" <<'FAKE'
#!/usr/bin/env bash
if [[ "$*" == devices ]]; then
	printf 'List of devices attached\n'
	[[ -n "${SERIAL:-}" ]] && printf '%s\tdevice\n' "$SERIAL"
	exit 0
fi
printf 'adb %s\n' "$*" >>"$CALLS"
FAKE
cat >"$sandbox/bin/hyprctl" <<'FAKE'
#!/usr/bin/env bash
[[ "$*" == 'monitors -j' ]] && { printf '%s\n' "$MONITORS"; exit 0; }
printf 'hyprctl %s\n' "$*" >>"$CALLS"
FAKE
for prog in wayvnc waybar pkill notify-send; do
	printf '#!/usr/bin/env bash\nprintf "%s %%s\\n" "$*" >>"$CALLS"\n' "$prog" >"$sandbox/bin/$prog"
done
chmod +x "$sandbox/bin"/*
export PATH="$sandbox/bin:$PATH" CALLS="$calls" ADB="$sandbox/bin/adb" XDG_RUNTIME_DIR="$sandbox/run"
export XDG_STATE_HOME="$sandbox/state" I18N_DIR="$repo_root/i18n" LANG=en_US.UTF-8 VIVAC_PHONE_SCREEN_CHECK=0.2
export MONITORS='[{"name":"HDMI-A-1","width":1920,"height":1080,"refreshRate":60.0,"x":0,"y":0,"scale":1.0}]'
state="$sandbox/run/vivac-phone-screen.pid"
settle() { sleep 0.4; }
has() { grep -qF -- "$1" "$calls" || fail "$2: $(cat "$calls")"; }

# No phone: nothing is created.
: >"$calls"
SERIAL='' "$tool" toggle 2>/dev/null && fail "the screen turned on without a phone"
settle
! grep -q 'output create\|^wayvnc\|^waybar' "$calls" || fail "something started without a phone: $(cat "$calls")"

# On.
: >"$calls"
SERIAL=PHONE1 "$tool" toggle 2>/dev/null || fail "the screen did not turn on"
settle
has 'hyprctl output create headless VIVAC-PHONE' "no virtual monitor was created"
has 'hl.monitor({ output = "HDMI-A-1", mode = "1920x1080@60", position = "0x0", scale = "1" })' "the computer's monitor was not pinned where it was"
has 'hl.monitor({ output = "VIVAC-PHONE", mode = "2400x1080@60", position = "1920x0", scale = "2" })' "the phone's monitor is not right of it at the phone's size and scale"
has 'hl.workspace_rule({ workspace = "11", monitor = "VIVAC-PHONE", default = true })' "workspace 11 is not the phone's first"
has 'hl.workspace_rule({ workspace = "20", monitor = "VIVAC-PHONE" })' "workspace 20 is not the phone's"
has 'hl.workspace_rule({ workspace = "1", monitor = "HDMI-A-1" })' "workspace 1 does not stay on the computer"
has 'hl.workspace_rule({ workspace = "10", monitor = "HDMI-A-1" })' "workspace 10 does not stay on the computer"
grep -q '^waybar .*waybar/phone/config' "$calls" || fail "the phone has no bar of its own: $(cat "$calls")"
has 'wayvnc -o VIVAC-PHONE 127.0.0.1 5900' "the screen is not served on 127.0.0.1 only"
has 'adb -s PHONE1 reverse tcp:5900 tcp:5900' "the phone does not reach the screen over USB"
has 'vnc://127.0.0.1:5900' "the viewer was not opened on the phone"
[[ -s "$state" ]] || fail "the mode left no watcher"

# Off: everything undone.
: >"$calls"
SERIAL=PHONE1 "$tool" toggle 2>/dev/null || fail "the screen did not turn off"
settle
has 'hyprctl output remove VIVAC-PHONE' "the virtual monitor was not removed"
grep -q '^pkill .*wayvnc' "$calls" || fail "the screen was still served"
grep -q '^pkill .*waybar/phone/config' "$calls" || fail "the phone's bar was left"
has 'adb -s PHONE1 reverse --remove tcp:5900' "the USB forward was left"
[[ ! -e "$state" ]] || fail "the watcher was left"

# The phone unplugged while on: everything undone by the watcher.
SERIAL=PHONE1 "$tool" toggle 2>/dev/null || fail "the screen did not turn on again"
settle
: >"$calls"
SERIAL='' "$tool" watch 2>/dev/null || true
has 'hyprctl output remove VIVAC-PHONE' "unplugging the phone left the virtual monitor"

# Only toggle and watch.
"$tool" 3 2>/dev/null && fail "an unknown argument was accepted"

hypr="$repo_root/templates/hypr/.config/hypr/hyprland.lua.in"
for n in 1 2 3 4 5 6 7 8 9 10; do
	grep -qF "hl.bind(\"SUPER + ALT + $((n % 10))\", hl.dsp.focus({ workspace = $((10 + n)) }))" "$hypr" ||
		fail "SUPER+ALT+$((n % 10)) does not go to the phone's workspace $((10 + n))"
done
grep -q '"output": "!VIVAC-PHONE"' "$repo_root/render/waybar/config.in" || fail "the computer's bar would show on the phone too"
echo "phone screen: its own monitor, workspaces 11-20 and bar, served over USB only, undone off or unplugged"
