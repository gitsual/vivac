#!/usr/bin/env bash
set -Eeuo pipefail

# android/bin/vivac-desk in a fake Termux: the phone's own desktop, which
# needs no computer and no network. Without its packages it says how to get
# them and starts nothing; `install` asks pkg for the X11 repository and then
# for the desktop's packages; `start` brings up the X server on display :1,
# waits for its socket, starts i3 on it and opens the Termux:X11 app; a second
# `start` reuses what is running and only opens the app; `stop` ends both;
# `status` tells which is the case. Nothing touches the network.

repo_root="${REPO_ROOT:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)}"
desk="$repo_root/bin/vivac-desk"

fail() {
	printf '%s\n' "$1" >&2
	exit 1
}
sandbox="$(mktemp -d "${TMPDIR:-/tmp}/vivac-desk.XXXXXX")"
cleanup() {
	[[ -n "${PREFIX:-}" ]] && PATH="$fakes:$PATH" bash "$desk" stop >/dev/null 2>&1 || true
	rm -rf -- "$sandbox"
}
trap cleanup EXIT
export PREFIX="$sandbox/usr" HOME="$sandbox/home" TMPDIR="$sandbox/usr/tmp"
mkdir -p "$PREFIX/bin" "$HOME" "$TMPDIR"
log="$sandbox/calls.log"
export CALLS="$log"
: >"$log"

fakes="$sandbox/fakes"
mkdir -p "$fakes"
for cmd in am pkg curl; do
	cat >"$fakes/$cmd" <<'FAKE'
#!/usr/bin/env bash
printf '%s %s\n' "$(basename "$0")" "$*" >>"$CALLS"
FAKE
	chmod +x "$fakes/$cmd"
done
export PATH="$fakes:$PATH"

# 1. No desktop packages yet: a clear hint, nothing started.
out="$(bash "$desk" start 2>&1)" && fail "start succeeded without termux-x11"
[[ "$out" == *"vivac-desk install"* ]] || fail "no hint to install: $out"
! grep -q '^am ' "$log" || fail "opened the app with nothing to show"

# 2. install: the X11 repository first, then the desktop.
bash "$desk" install >/dev/null || fail "install failed"
first="$(grep '^pkg ' "$log" | head -1)"
[[ "$first" == *"install"*"x11-repo"* ]] || fail "x11-repo not installed first: $first"
second="$(grep '^pkg ' "$log" | sed -n 2p)"
for p in termux-x11-nightly i3 polybar kitty rofi picom feh termux-api; do
	[[ " $second " == *" $p "* ]] || fail "install does not ask for $p: $second"
done

# The installed X server and window manager, as fakes: the server makes its
# socket and stays up; i3 records the display it was given and stays up.
cat >"$PREFIX/bin/termux-x11" <<'FAKE'
#!/usr/bin/env bash
printf 'termux-x11 %s\n' "$*" >>"$CALLS"
mkdir -p "$TMPDIR/.X11-unix" && : >"$TMPDIR/.X11-unix/X${1#:}"
exec sleep 60
FAKE
cat >"$PREFIX/bin/i3" <<'FAKE'
#!/usr/bin/env bash
printf 'i3 DISPLAY=%s %s\n' "$DISPLAY" "$*" >>"$CALLS"
exec sleep 60
FAKE
chmod +x "$PREFIX/bin/termux-x11" "$PREFIX/bin/i3"
export PATH="$PREFIX/bin:$PATH"

# 3. start: server on :1, i3 on it with the desktop rendered from the theme
# in the vivac settings, the app opened.
mkdir -p "$HOME/.config/vivac"
printf 'theme=cosmos\n' >"$HOME/.config/vivac/settings"
: >"$log"
bash "$desk" start >/dev/null || fail "start failed"
grep -qx 'termux-x11 :1' "$log" || fail "X server not started on :1: $(cat "$log")"
conf="$HOME/.config/vivac/desk"
grep -qx "i3 DISPLAY=:1 -c $conf/i3.config" "$log" || fail "i3 not started on :1 with the rendered config: $(cat "$log")"
accent="$(sed -n 's/^COLOR_ACCENT=//p' "$repo_root/data/themes/cosmos.conf")"
for f in i3.config polybar.ini picom.conf rofi.rasi kitty.conf; do
	[[ -s "$conf/$f" ]] || fail "$f was not rendered"
	! grep -q '@[A-Z_]*\(:[a-z]*\)\?@' "$conf/$f" || fail "$f kept a token: $(grep -o '@[A-Z_:a-z]*@' "$conf/$f" | head -3)"
done
grep -qi "$accent" "$conf/polybar.ini" || fail "the bar does not wear the theme's accent ($accent)"
grep -qi "$accent" "$conf/i3.config" || fail "the windows do not wear the theme's accent ($accent)"
grep -qi "$accent" "$conf/rofi.rasi" || fail "the launcher does not wear the theme's accent ($accent)"
wall="$(sed -n 's/.*feh --no-fehbg --bg-fill "\([^"]*\)".*/\1/p' "$conf/i3.config")"
[[ "$wall" == */linux/assets/wallpapers/cosmos.png && -f "$wall" ]] || fail "the wallpaper is not the theme's: $wall"
grep -q "polybar -c \"$conf/polybar.ini\"" "$conf/i3.config" || fail "i3 does not start the rendered bar"
grep -q "picom --config \"$conf/picom.conf\"" "$conf/i3.config" || fail "i3 does not start the compositor"
grep -q '^am start.*com.termux.x11' "$log" || fail "Termux:X11 app not opened: $(cat "$log")"
[[ "$(bash "$desk" status)" == *running* ]] || fail "status does not say running"

# 4. A second start reuses the running desktop.
: >"$log"
bash "$desk" start >/dev/null || fail "second start failed"
! grep -q '^termux-x11 ' "$log" || fail "second start launched another X server"
! grep -q '^i3 ' "$log" || fail "second start launched another i3"
grep -q '^am start.*com.termux.x11' "$log" || fail "second start did not open the app"

# 5. stop ends both.
bash "$desk" stop >/dev/null || fail "stop failed"
[[ "$(bash "$desk" status)" == *stopped* ]] || fail "status does not say stopped after stop"
! pgrep -f "$PREFIX/bin/termux-x11" >/dev/null || fail "X server still running after stop"

# 6. The bar's gauges, from Termux:API: battery level and charging, Wi-Fi.
cat >"$fakes/termux-battery-status" <<'FAKE'
#!/usr/bin/env bash
printf '{\n  "percentage": %s,\n  "status": "%s"\n}\n' "${PCT:-54}" "${STATUS:-DISCHARGING}"
FAKE
cat >"$fakes/termux-wifi-connectioninfo" <<'FAKE'
#!/usr/bin/env bash
printf '{\n  "ssid": "%s",\n  "supplicant_state": "%s"\n}\n' "${SSID:-casa}" "${WSTATE:-COMPLETED}"
FAKE
chmod +x "$fakes/termux-battery-status" "$fakes/termux-wifi-connectioninfo"
[[ "$(PCT=54 bash "$desk" bar battery)" == "󰁾 54%" ]] || fail "battery at 54%: $(PCT=54 bash "$desk" bar battery)"
[[ "$(PCT=9 bash "$desk" bar battery)" == "%{F#"*"}󰁺 9%%{F-}" ]] || fail "a low battery does not stand out: $(PCT=9 bash "$desk" bar battery)"
[[ "$(PCT=97 STATUS=CHARGING bash "$desk" bar battery)" == "󰂄 97%" ]] || fail "charging: $(PCT=97 STATUS=CHARGING bash "$desk" bar battery)"
[[ "$(bash "$desk" bar wifi)" == "󰖩" ]] || fail "wifi: $(bash "$desk" bar wifi)"
[[ "$(PCT=54 bash "$desk" bar status)" == "󰖩  󰁾 54%" ]] || fail "status: $(PCT=54 bash "$desk" bar status)"
[[ "$(WSTATE=DISCONNECTED bash "$desk" bar wifi)" == "󰖪" ]] || fail "no wifi: $(WSTATE=DISCONNECTED bash "$desk" bar wifi)"

# 7. Offline: nothing above reached for the network.
! grep -q '^curl ' "$log" || fail "the desktop used the network"
true
