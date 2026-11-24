#!/usr/bin/env bash
# The fakes are shell source written out literally: their $ expands when they run.
# shellcheck disable=SC2016
set -Eeuo pipefail

# vivac-dev: the developer's kit for any app, through adb to the phone itself
# (wireless debugging on localhost) or over USB from a PC. Against a fake adb
# that logs every call: the screen reads as a compact tree, taps land on the
# centre of the node they name and only while the named app has the focus,
# logs and crashes are scoped to one app, destructive verbs want --yes, and a
# missing device is explained instead of failing obscurely.

repo_root="${REPO_ROOT:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)}"
tool="$repo_root/bin/vivac-dev"

fail() {
	printf '%s\n' "$1" >&2
	exit 1
}
sandbox="$(mktemp -d "${TMPDIR:-/tmp}/vivac-dev.XXXXXX")"
trap 'rm -rf -- "$sandbox"' EXIT
mkdir -p "$sandbox/bin" "$sandbox/out"
log="$sandbox/adb.log"
: >"$log"

cat >"$sandbox/ui.xml" <<'XML'
<?xml version='1.0' encoding='UTF-8' standalone='yes' ?>
<hierarchy rotation="0">
  <node index="0" text="" resource-id="" class="android.widget.FrameLayout" package="com.example.app" content-desc="" clickable="false" bounds="[0,0][1080,2400]">
    <node index="0" text="Places" resource-id="com.example.app:id/title" class="android.widget.TextView" package="com.example.app" content-desc="" clickable="false" bounds="[40,100][400,180]" />
    <node index="1" text="" resource-id="" class="android.view.View" package="com.example.app" content-desc="" clickable="false" bounds="[0,200][1080,1100]" />
    <node index="2" text="Save" resource-id="com.example.app:id/save" class="android.widget.Button" package="com.example.app" content-desc="" clickable="true" bounds="[400,1150][680,1250]" />
    <node index="3" text="" resource-id="com.example.app:id/fab" class="android.widget.ImageButton" package="com.example.app" content-desc="Add place" clickable="true" bounds="[900,2200][1040,2340]" />
  </node>
</hierarchy>
XML

cat >"$sandbox/package.txt" <<'TXT'
Activity Resolver Table:
  Schemes:
      locapp:
        1f2e3d com.example.app/.MainActivity filter 9a8b
  Non-Data Actions:
      android.intent.action.MAIN:
        1f2e3d com.example.app/.MainActivity filter 7c6d
Packages:
  Package [com.example.app] (abc123):
    appId=10234
    versionCode=42 minSdk=26 targetSdk=35
    versionName=1.4.0
    flags=[ HAS_CODE ALLOW_CLEAR_USER_DATA DEBUGGABLE ]
    install permissions:
      android.permission.INTERNET: granted=true
    runtime permissions:
      android.permission.ACCESS_FINE_LOCATION: granted=true
      android.permission.CAMERA: granted=false
TXT

cat >"$sandbox/crash.txt" <<'TXT'
--------- beginning of crash
11-24 10:00:00.000  9000  9000 E AndroidRuntime: FATAL EXCEPTION: main
11-24 10:00:00.000  9000  9000 E AndroidRuntime: Process: org.other.app, PID: 9000
11-24 10:00:00.000  9000  9000 E AndroidRuntime: java.lang.IllegalStateException: not ours
11-24 11:00:00.000  4321  4321 E AndroidRuntime: FATAL EXCEPTION: main
11-24 11:00:00.000  4321  4321 E AndroidRuntime: Process: com.example.app, PID: 4321
11-24 11:00:00.000  4321  4321 E AndroidRuntime: java.lang.NullPointerException: boom
11-24 11:00:00.000  4321  4321 E AndroidRuntime: 	at com.example.app.MainActivity.onCreate(MainActivity.kt:12)
TXT

# focus.txt holds the package that has the focus; tests rewrite it.
printf 'com.example.app\n' >"$sandbox/focus.txt"

cat >"$sandbox/bin/adb" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$FAKE_DIR/adb.log"
if [[ "${FAKE_NO_DEVICE:-}" == 1 && "$1" == devices ]]; then
	printf 'List of devices attached\n\n'
	exit 0
fi
case "$*" in
devices) printf 'List of devices attached\nlocalhost:5555\tdevice\n\n' ;;
"connect localhost:5555") echo 'failed to connect to localhost:5555'; exit 1 ;;
"mdns services") printf 'List of discovered mdns services\nadb-39071FDJ-abc\t_adb-tls-connect._tcp\tadb-host.local:41234\n' ;;
"connect localhost:41234") echo 'connected to localhost:41234' ;;
*"shell dumpsys input"*) printf '      Viewport INTERNAL: displayId=0, orientation=1, logicalFrame=[0, 0, 2400, 1080], isActive=[1]\n' ;;
*"shell wm size"*) echo 'Physical size: 1080x2400' ;;
*"shell dumpsys window"*) printf '  mCurrentFocus=Window{abc u0 %s/%s.MainActivity}\n' "$(cat "$FAKE_DIR/focus.txt")" "$(cat "$FAKE_DIR/focus.txt")" ;;
*"shell uiautomator dump"*) echo 'UI hierchary dumped to: /sdcard/window_dump.xml' ;;
*"exec-out cat"*) cat "$FAKE_DIR/ui.xml" ;;
*"shell pm list packages -U com.example.app"*) echo 'package:com.example.app uid:10234' ;;
*"shell pm list packages -U org.other.app"*) echo 'package:org.other.app uid:10999' ;;
*"shell pm list packages -3"*) printf 'package:com.example.app\npackage:org.other.app\n' ;;
*"shell dumpsys package com.example.app"*) cat "$FAKE_DIR/package.txt" ;;
*"shell logcat -d -b crash"*) cat "$FAKE_DIR/crash.txt" ;;
*"shell logcat -d --uid=10234"*) echo '11-24 11:00:01.000  4321  4321 I Locapp: started' ;;
*"exec-out screencap -p"*) python3 -c 'import struct,sys; sys.stdout.buffer.write(b"\x89PNG\r\n\x1a\n"+struct.pack(">I",13)+b"IHDR"+struct.pack(">II",1080,2400)+b"\x08\x06\x00\x00\x00")' ;;
*) : ;;
esac
FAKE
chmod +x "$sandbox/bin/adb"

dev() { PATH="$sandbox/bin:$PATH" FAKE_DIR="$sandbox" VIVAC_DEV_OUT="$sandbox/out" VIVAC_MAGICK=none \
	VIVAC_DEV_POLL=0 python3 "$tool" "$@"; }
logged() { grep -qF -- "$1" "$log" || fail "expected adb call: $1"$'\n'"$(cat "$log")"; }
not_logged() { if grep -qF -- "$1" "$log"; then fail "unexpected adb call: $1"; fi; }

# The screen as a compact tree: meaningful nodes only, with centre coordinates.
out="$(dev ui)" || fail "ui failed"
[[ "$out" == *'"Save"'*'id=save'*'@540,1200'*'click'* ]] || fail "ui: Save button line missing: $out"
[[ "$out" == *'desc="Add place"'*'@970,2270'* ]] || fail "ui: icon button by its description missing: $out"
[[ "$out" == *'"Places"'* ]] || fail "ui: plain text missing: $out"
[[ "$(grep -c 'android.view.View' <<<"$out" || true)" == 0 ]] || fail "ui: empty layout node not pruned: $out"
[[ "$out" == *'focus: com.example.app'* ]] || fail "ui: no focus header: $out"

# A screen with nothing to read (a canvas, a game, a remote desktop) says so.
cp "$sandbox/ui.xml" "$sandbox/ui.full"
printf '%s\n' "<?xml version='1.0' encoding='UTF-8' standalone='yes' ?>" \
	'<hierarchy rotation="1"><node index="0" text="" resource-id="" class="android.widget.FrameLayout" package="com.example.app" content-desc="" clickable="false" bounds="[0,0][2400,1080]" /></hierarchy>' >"$sandbox/ui.xml"
out="$(dev ui)" || fail "ui on an empty screen failed"
[[ "$out" == *'nothing to read'*'shot'* ]] || fail "ui: empty screen not explained: $out"
cp "$sandbox/ui.full" "$sandbox/ui.xml"

# Focus.
[[ "$(dev focus)" == 'com.example.app/com.example.app.MainActivity' ]] || fail "focus: $(dev focus)"

# A tap by text lands on the centre of the node, only while the app has the focus.
: >"$log"
dev tap Save --pkg com.example.app >/dev/null || fail "tap by text failed"
logged 'shell input tap 540 1200'
: >"$log"
dev tap 'Add place' --pkg com.example.app >/dev/null || fail "tap by description failed"
logged 'shell input tap 970 2270'
: >"$log"
dev tap 10,20 --pkg com.example.app >/dev/null || fail "tap by coordinates failed"
logged 'shell input tap 10 20'
printf 'org.other.app\n' >"$sandbox/focus.txt"
: >"$log"
if dev tap Save --pkg com.example.app 2>"$sandbox/err"; then fail "tap went through on someone else's app"; fi
not_logged 'input tap'
grep -q 'org.other.app' "$sandbox/err" || fail "refusal does not name the app that has the focus"
if dev tap Save 2>/dev/null; then fail "tap without --pkg must be refused"; fi
printf 'com.example.app\n' >"$sandbox/focus.txt"
: >"$log"
if dev tap Nothing --pkg com.example.app 2>/dev/null; then fail "tap on a missing node succeeded"; fi
not_logged 'input tap'

# Typing escapes spaces for `input text`.
: >"$log"
dev type 'hola mundo' --pkg com.example.app >/dev/null || fail "type failed"
logged 'shell input text hola%smundo'

# A swipe uses the screen as it is turned now, not its portrait size.
: >"$log"
dev swipe up --pkg com.example.app >/dev/null || fail "swipe failed"
logged 'shell input swipe 1200 720 1200 360 300'

# Waiting for text already on screen returns at once.
dev wait Save --timeout 1 >/dev/null || fail "wait did not see Save"
if dev wait Missing --timeout 0 2>/dev/null; then fail "wait for missing text succeeded"; fi

# Logs and crashes are scoped to one app.
: >"$log"
out="$(dev log com.example.app)" || fail "log failed"
logged 'shell logcat -d --uid=10234'
[[ "$out" == *'Locapp: started'* ]] || fail "log output missing: $out"
out="$(dev crash com.example.app)" || fail "crash failed"
[[ "$out" == *'NullPointerException: boom'* && "$out" == *'MainActivity.kt:12'* ]] || fail "crash: ours missing: $out"
[[ "$out" != *'not ours'* ]] || fail "crash: another app's crash leaked in: $out"

out="$(dev log org.other.app)" || fail "log of a quiet app failed"
[[ "$out" == *'no log lines'* ]] || fail "log: silence not explained: $out"

# What an app is: version, debuggable, deep links, permissions.
out="$(dev info com.example.app)" || fail "info failed"
for want in 'version: 1.4.0 (42)' 'target sdk: 35' 'debuggable: yes' 'uid: 10234' 'locapp:' \
	'ACCESS_FINE_LOCATION granted' 'CAMERA denied'; do
	[[ "$out" == *"$want"* ]] || fail "info: missing '$want' in: $out"
done

# Apps, launch, deep links, stop.
[[ "$(dev apps)" == *'org.other.app'* ]] || fail "apps"
: >"$log"
dev open 'locapp://capture?cat=cafe' --pkg com.example.app >/dev/null || fail "open failed"
logged 'shell am start -W -a android.intent.action.VIEW -d '\''locapp://capture?cat=cafe'\'' -p com.example.app'
dev launch com.example.app >/dev/null || fail "launch failed"
logged 'shell monkey -p com.example.app -c android.intent.category.LAUNCHER 1'
dev stop com.example.app >/dev/null || fail "stop failed"
logged 'shell am force-stop com.example.app'

# Destructive verbs want --yes.
: >"$log"
if dev clear com.example.app 2>/dev/null; then fail "clear without --yes went through"; fi
not_logged 'pm clear'
dev clear com.example.app --yes >/dev/null || fail "clear --yes failed"
logged 'shell pm clear com.example.app'

# A screenshot is saved and its size and token cost are told.
out="$(dev shot)" || fail "shot failed"
[[ "$out" == *'1080x2400'* && "$out" == *'3456 tokens'* ]] || fail "shot: size/cost not reported: $out"
[[ -s "$sandbox/out/shot.png" ]] || fail "shot: no file"

# Connecting: the fixed port first, then the port wireless debugging announces.
: >"$log"
out="$(dev connect)" || fail "connect failed"
logged 'connect localhost:5555'
logged 'connect localhost:41234'
[[ "$out" == *'localhost:41234'* ]] || fail "connect: serial not reported: $out"

# No device: the way to get one is explained.
if FAKE_NO_DEVICE=1 dev focus 2>"$sandbox/err"; then fail "no device: succeeded"; fi
grep -q 'vivac-dev pair' "$sandbox/err" || fail "no device: no hint: $(cat "$sandbox/err")"

printf 'vivac-dev: all checks passed\n'
