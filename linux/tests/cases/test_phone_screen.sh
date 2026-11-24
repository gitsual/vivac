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
# (adb reverse), where the viewer opens, and the phone is turned to
# landscape and held there. Off (again, or the phone unplugged):
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
	# BLIPS: how many times in a row the phone is missing first (a USB blip).
	if [[ -n "${BLIPS:-}" ]]; then
		n="$(cat "$BLIPFILE" 2>/dev/null || echo 0)"
		printf '%s\n' "$((n + 1))" >"$BLIPFILE"
		((n < BLIPS)) && exit 0
	fi
	[[ -n "${SERIAL:-}" ]] && printf '%s\tdevice\n' "$SERIAL"
	exit 0
fi
printf 'adb %s\n' "$*" >>"$CALLS"
# The phone's rotation, as Android prints it: "free", or "lock N".
[[ "$*" == *'shell cmd window user-rotation' ]] && printf '%s\n' "${ROTATION:-free}"
[[ "$*" == *'shell wm size' ]] && printf 'Physical size: 1080x2400\n'
[[ "$*" == *'shell settings get global stay_on_while_plugged_in' ]] && printf '%s\n' "${STAYON:-0}"
[[ "$*" == *'shell settings get system screen_off_timeout' ]] && printf '30000\n'
[[ "$*" == *'shell settings get system screen_brightness' ]] && printf '60\n'
# The camera cutout, as dumpsys prints it in portrait: 132 px at the top.
[[ "$*" == *'shell dumpsys window displays' ]] && printf '      mDisplayCutout=DisplayCutout{insets=Rect(0, %s - 0, 0) waterfall=Insets{}}\n' "${CUTOUT:-132}"
exit 0
FAKE
cat >"$sandbox/bin/hyprctl" <<'FAKE'
#!/usr/bin/env bash
[[ "$*" == 'monitors -j' ]] && { printf '%s\n' "$MONITORS"; exit 0; }
printf 'hyprctl %s\n' "$*" >>"$CALLS"
FAKE
# systemd-inhibit holds its lock for as long as the command it runs.
cat >"$sandbox/bin/systemd-inhibit" <<'FAKE'
#!/usr/bin/env bash
printf 'systemd-inhibit %s\n' "$*" >>"$CALLS"
exec sleep 300
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
# The phone's size less its camera cutout: the viewer then fills it edge to
# edge instead of shrinking the screen to clear the cutout.
has 'hl.monitor({ output = "VIVAC-PHONE", mode = "2268x1080@60", position = "1920x0", scale = "2" })' "the phone's monitor is not right of it at the phone's usable size and scale"
has 'hl.workspace_rule({ workspace = "11", monitor = "VIVAC-PHONE", default = true })' "workspace 11 is not the phone's first"
has 'hl.workspace_rule({ workspace = "20", monitor = "VIVAC-PHONE" })' "workspace 20 is not the phone's"
has 'hl.workspace_rule({ workspace = "1", monitor = "HDMI-A-1" })' "workspace 1 does not stay on the computer"
has 'hl.workspace_rule({ workspace = "10", monitor = "HDMI-A-1" })' "workspace 10 does not stay on the computer"
grep -q '^waybar .*waybar/phone/config' "$calls" || fail "the phone has no bar of its own: $(cat "$calls")"
has 'wayvnc -o VIVAC-PHONE 127.0.0.1 5900' "the screen is not served on 127.0.0.1 only"
has 'adb -s PHONE1 reverse tcp:5900 tcp:5900' "the phone does not reach the screen over USB"
has 'vnc://127.0.0.1:5900' "the viewer was not opened on the phone"
[[ -s "$state" ]] || fail "the mode left no watcher"
# The screen is landscape, so the phone is turned to landscape and held there:
# a phone left in portrait shows it small, between black bands.
has 'adb -s PHONE1 shell cmd window user-rotation lock 1' "the phone was not turned to landscape"
# A screen does not go dark while it is in use: the phone stays awake on the
# cable and is woken now.
has 'adb -s PHONE1 shell svc power stayon usb' "the phone may sleep while it is a screen"
has 'adb -s PHONE1 shell input keyevent KEYCODE_WAKEUP' "the phone was not woken"
# Awake is not enough: a Pixel still dims after its screen timeout, so the
# timeout is stretched and the brightness raised while it is a screen.
has 'adb -s PHONE1 shell settings put system screen_off_timeout 1800000' "the phone still dims after its timeout"
has 'adb -s PHONE1 shell settings put system screen_brightness 255' "the phone stays at its own low brightness"
# Nor does the computer lock or turn its screens off while the phone is one
# (the owner's choice: reading on the phone is not input here).
has 'systemd-inhibit --what=idle --who=vivac' "the computer may still go idle while the phone is a screen"
inhibitor="$(cat "$sandbox/run/vivac-phone-screen.inhibit" 2>/dev/null)"
[[ "$inhibitor" =~ ^[0-9]+$ ]] && kill -0 "$inhibitor" 2>/dev/null || fail "no idle lock is held: ${inhibitor:-none}"
# Alt+number goes to the phone's workspaces, Alt+Shift+number sends the window
# there: only while the phone is a screen, since many programs take Alt+number.
has 'hl.bind("ALT + 1", hl.dsp.focus({ workspace = 11 }))' "Alt+1 does not go to workspace 11"
has 'hl.bind("ALT + 0", hl.dsp.focus({ workspace = 20 }))' "Alt+0 does not go to workspace 20"
has 'hl.bind("ALT + SHIFT + 1", hl.dsp.window.move({ workspace = 11 }))' "Alt+Shift+1 does not send the window to 11"
has 'hl.bind("ALT + SHIFT + 0", hl.dsp.window.move({ workspace = 20 }))' "Alt+Shift+0 does not send the window to 20"
# The viewer starts afresh, after the turn: one left open from before keeps
# the zoom it had in portrait and shows the screen small.
stop="$(grep -n 'am force-stop com.gaurav.avnc' "$calls" | head -1 | cut -d: -f1)"
view="$(grep -n 'vnc://127.0.0.1:5900' "$calls" | head -1 | cut -d: -f1)"
turn="$(grep -n 'user-rotation lock 1' "$calls" | head -1 | cut -d: -f1)"
[[ -n "$stop" && "$turn" -lt "$view" && "$stop" -lt "$view" ]] || fail "the viewer was not started afresh after the turn: $(cat "$calls")"

# Off: everything undone.
: >"$calls"
SERIAL=PHONE1 "$tool" toggle 2>/dev/null || fail "the screen did not turn off"
settle
has 'hyprctl output remove VIVAC-PHONE' "the virtual monitor was not removed"
grep -q '^pkill .*wayvnc' "$calls" || fail "the screen was still served"
grep -q '^pkill .*waybar/phone/config' "$calls" || fail "the phone's bar was left"
has 'adb -s PHONE1 reverse --remove tcp:5900' "the USB forward was left"
[[ ! -e "$state" ]] || fail "the watcher was left"
has 'adb -s PHONE1 shell cmd window user-rotation free' "the phone's own rotation was not given back"
has 'adb -s PHONE1 shell am force-stop com.gaurav.avnc' "the viewer was left open on a screen that is gone"
has 'adb -s PHONE1 shell settings put global stay_on_while_plugged_in 0' "the phone's own stay-awake setting was not given back"
has 'adb -s PHONE1 shell settings put system screen_off_timeout 30000' "the phone's own screen timeout was not given back"
has 'adb -s PHONE1 shell settings put system screen_brightness 60' "the phone's own brightness was not given back"
has 'hl.unbind("ALT + 1")' "Alt+1 was left bound"
kill -0 "$inhibitor" 2>/dev/null && fail "the idle lock outlived the phone screen"
[[ ! -e "$sandbox/run/vivac-phone-screen.inhibit" ]] || fail "the idle lock left its record"
has 'hl.unbind("ALT + SHIFT + 0")' "Alt+Shift+0 was left bound"

# A phone that was held in a rotation of its own gets that one back.
: >"$calls"
ROTATION='lock 0' SERIAL=PHONE1 "$tool" toggle 2>/dev/null || fail "the screen did not turn on (held rotation)"
settle
: >"$calls"
SERIAL=PHONE1 "$tool" toggle 2>/dev/null || fail "the screen did not turn off (held rotation)"
settle
has 'adb -s PHONE1 shell cmd window user-rotation lock 0' "the phone's held rotation was not given back"

# A USB blip (the phone gone for one check, then back) leaves it on: only a
# phone missing several checks in a row is taken as unplugged.
SERIAL=PHONE1 "$tool" toggle 2>/dev/null || fail "the screen did not turn on before the blip"
settle
: >"$calls"
BLIPS=1 BLIPFILE="$sandbox/blips" SERIAL=PHONE1 "$tool" watch 2>/dev/null &
watcher=$!
sleep 1.2
kill "$watcher" 2>/dev/null || true
wait "$watcher" 2>/dev/null || true
[[ -s "$state" ]] || fail "a USB blip turned the phone screen off"
! grep -q 'output remove' "$calls" || fail "a USB blip removed the phone's monitor"
# Back from the blip, the USB forward is gone with the old connection: it is
# made again and the viewer reopened, or the phone says no server runs.
has 'adb -s PHONE1 reverse tcp:5900 tcp:5900' "after a USB blip the forward was not made again"
has 'vnc://127.0.0.1:5900' "after a USB blip the viewer was not reopened"
SERIAL=PHONE1 "$tool" toggle 2>/dev/null || fail "the screen did not turn off after the blip"
settle

# The phone unplugged while on: everything undone by the watcher.
SERIAL=PHONE1 "$tool" toggle 2>/dev/null || fail "the screen did not turn on again"
settle
: >"$calls"
SERIAL='' "$tool" watch 2>/dev/null || true
has 'hyprctl output remove VIVAC-PHONE' "unplugging the phone left the virtual monitor"
# Unplugged, the phone cannot be given its rotation back: it is kept, and the
# next time the screen goes off with the phone there it gets that one, not the
# landscape this held it in meanwhile.
grep -qx 'free' "$sandbox/run/vivac-phone-screen.rotation" || fail "unplugged, the phone's own rotation was lost"
: >"$calls"
ROTATION='lock 1' SERIAL=PHONE1 "$tool" toggle 2>/dev/null || fail "the screen did not turn on after the unplug"
settle
grep -qx 'free' "$sandbox/run/vivac-phone-screen.rotation" || fail "turning on again overwrote the phone's own rotation"
: >"$calls"
SERIAL=PHONE1 "$tool" toggle 2>/dev/null || fail "the screen did not turn off after the unplug"
settle
has 'adb -s PHONE1 shell cmd window user-rotation free' "after an unplug, the phone's own rotation was not given back"
[[ ! -e "$sandbox/run/vivac-phone-screen.rotation" ]] || fail "the saved rotation outlived its return"

# Only toggle and watch.
"$tool" 3 2>/dev/null && fail "an unknown argument was accepted"

hypr="$repo_root/templates/hypr/.config/hypr/hyprland.lua.in"
for n in 1 2 3 4 5 6 7 8 9 10; do
	grep -qF "hl.bind(\"SUPER + ALT + $((n % 10))\", hl.dsp.focus({ workspace = $((10 + n)) }))" "$hypr" ||
		fail "SUPER+ALT+$((n % 10)) does not go to the phone's workspace $((10 + n))"
done
grep -q '"output": "!VIVAC-PHONE"' "$repo_root/render/waybar/config.in" || fail "the computer's bar would show on the phone too"
# The phone's bar reads as the computer's: the time and the weather in the
# middle, the workspaces and the window on the left.
python3 -c '
import json, sys
c = json.load(open(sys.argv[1]))
assert c["modules-center"] == ["clock", "custom/weather"], c["modules-center"]
# The widgets on the right are those of the computer bar, through include: one
# definition, hover and all. A shorter set, since the phone is half as wide:
# each one defined by the computer bar, none of its own.
assert c.get("include") == ["~/.config/waybar/config"], c.get("include")
right = c["modules-right"]
# Half as wide as the computer: on the right only the power button and one
# folded chip that unfolds the rest on hover or a tap, as the system drawer
# does on the computer.
assert right == ["cffi/hover", "group/phone-status", "custom/power"], right
fold = c["group/phone-status"]
assert "drawer" in fold and fold["modules"][0] == "custom/fold", fold
leaves = fold["modules"][1:]
assert "pulseaudio" in leaves and "network#wireless" in leaves, leaves
import re
template = open(sys.argv[2]).read()
for m in leaves + ["cffi/hover", "custom/power"]:
    assert re.search("\"" + re.escape(m) + "\": [{]", template), ("not defined by the computer bar", m)
    assert m not in c, ("defined again on the phone", m)
assert c["modules-left"] == ["hyprland/workspaces"], c["modules-left"]
assert c["output"] == "VIVAC-PHONE"
# Its workspaces read 11 to 20: a continuation of 1 to 10 on the computer.
icons = c["hyprland/workspaces"].get("format-icons", {})
assert all(k == v for k, v in icons.items()), icons
assert c["modules-left"][0] == "hyprland/workspaces", c["modules-left"]
assert "custom/weather" in c and "vivac-panel waybar forecast" in c["custom/weather"]["exec"], c.get("custom/weather")
' "$repo_root/dotfiles/waybar/.config/waybar/phone/config" "$repo_root/render/waybar/config.in" || fail "the phone's bar does not have the time and the weather in the middle"
echo "phone screen: its own monitor, workspaces 11-20 and bar, served over USB only, undone off or unplugged"
