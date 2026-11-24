#!/usr/bin/env bash
# The fakes are shell source written out literally: their $ expands when they run.
# shellcheck disable=SC2016
set -Eeuo pipefail

# The phone's desktops (vivac-phone-desk N): against fake adb, scrcpy, hyprctl
# and dispatcher. Desktop N opens as a new virtual display of the phone, in a
# window titled vivac-movil-N, and the view moves to workspace 10+N; a desktop
# already open is only switched to, never opened twice; no phone over adb is
# said, and nothing is started; anything but 1-10 is refused. Hyprland sends
# each title to its workspace and binds SUPER+ALT+number to it.

repo_root="${REPO_ROOT:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)}"
tool="$repo_root/dotfiles/bridge/.local/bin/vivac-phone-desk"
fail() {
	printf '%s\n' "$1" >&2
	exit 1
}
sandbox="$(mktemp -d "${TMPDIR:-/tmp}/vivac-desk.XXXXXX")"
trap 'rm -rf -- "$sandbox"' EXIT
mkdir -p "$sandbox/bin"
calls="$sandbox/calls"
cat >"$sandbox/bin/adb" <<'FAKE'
#!/usr/bin/env bash
printf 'List of devices attached\n'
[[ -n "${SERIAL:-}" ]] && printf '%s\tdevice\n' "$SERIAL"
exit 0
FAKE
cat >"$sandbox/bin/scrcpy" <<'FAKE'
#!/usr/bin/env bash
printf 'scrcpy %s\n' "$*" >>"$CALLS"
FAKE
cat >"$sandbox/bin/hyprctl" <<'FAKE'
#!/usr/bin/env bash
[[ "$*" == 'clients -j' ]] && printf '[%s]\n' "${CLIENTS:-}"
exit 0
FAKE
cat >"$sandbox/bin/dispatch" <<'FAKE'
#!/usr/bin/env bash
printf 'dispatch %s\n' "$*" >>"$CALLS"
FAKE
printf '#!/usr/bin/env bash\nexit 0\n' >"$sandbox/bin/notify-send"
cat >"$sandbox/bin/pkill" <<'FAKE'
#!/usr/bin/env bash
printf 'pkill %s\n' "$*" >>"$CALLS"
FAKE
chmod +x "$sandbox/bin"/*
export PATH="$sandbox/bin:$PATH" CALLS="$calls" VIVAC_DISPATCH="$sandbox/bin/dispatch" ADB="$sandbox/bin/adb"
export XDG_RUNTIME_DIR="$sandbox/run" XDG_STATE_HOME="$sandbox/state"
mkdir -p "$XDG_RUNTIME_DIR"
export I18N_DIR="$repo_root/i18n" LANG=en_US.UTF-8

# scrcpy is started detached (setsid -f): give it a moment to be written down.
settle() { sleep 0.3; }
run() {
	: >"$calls"
	local rc=0
	"$tool" "$@" 2>"$sandbox/err" >/dev/null || rc=$?
	settle
	return "$rc"
}

SERIAL=PHONE1 run 3 || fail "desktop 3 did not open"
grep -q '^scrcpy .*-s PHONE1' "$calls" || fail "scrcpy not pointed at the phone: $(cat "$calls")"
grep -q -- '--new-display=' "$calls" || fail "the desktop is not a virtual display of its own"
grep -q -- '--window-title=vivac-movil-3' "$calls" || fail "the window is not titled for desktop 3"
grep -q -- '--no-vd-destroy-content' "$calls" || fail "closing the desktop would kill its apps"
grep -qx 'dispatch workspace 13' "$calls" || fail "the view did not move to workspace 13"

SERIAL=PHONE1 CLIENTS='{"title":"vivac-movil-3"}' run 3 || fail "an open desktop could not be switched to"
! grep -q '^scrcpy' "$calls" || fail "an open desktop was opened twice"
grep -qx 'dispatch workspace 13' "$calls" || fail "an open desktop was not switched to"

SERIAL=PHONE1 run 10 && grep -q -- '--window-title=vivac-movil-10' "$calls" && grep -qx 'dispatch workspace 20' "$calls" ||
	fail "desktop 10 does not land on workspace 20"

SERIAL='' run 1 && fail "no phone was not an error"
! grep -q '^scrcpy' "$calls" || fail "scrcpy started with no phone"
[[ -s "$sandbox/err" ]] || fail "no phone was not said"

for bad in 0 11 x ''; do
	SERIAL=PHONE1 run "$bad" && fail "desktop '$bad' was accepted"
	! grep -q '^scrcpy' "$calls" || fail "desktop '$bad' started scrcpy"
done

# The mode follows Hyprland: arriving at workspace 14 opens desktop 4, a
# workspace outside 11-20 opens nothing, an open desktop is not reopened.
: >"$calls"
printf 'workspace>>14\nworkspace>>5\nactivewindow>>x,y\n' | SERIAL=PHONE1 "$tool" follow 2>/dev/null
settle
grep -q -- '--window-title=vivac-movil-4' "$calls" || fail "visiting workspace 14 did not open desktop 4"
[[ "$(grep -c '^scrcpy' "$calls")" == 1 ]] || fail "visiting a workspace outside 11-20 opened a desktop: $(cat "$calls")"
! grep -q '^dispatch' "$calls" || fail "following moved the view by itself"
: >"$calls"
printf 'workspace>>14\n' | SERIAL=PHONE1 CLIENTS='{"title":"vivac-movil-4"}' "$tool" follow 2>/dev/null
settle
! grep -q '^scrcpy' "$calls" || fail "an open desktop was reopened on a visit"

# The phone unplugged while following: every phone desktop closes.
: >"$calls"
(sleep 3; printf 'workspace>>3\n') | SERIAL='' VIVAC_PHONE_DESK_CHECK=1 "$tool" follow 2>/dev/null || true
grep -q "^pkill .*vivac-movil-" "$calls" || fail "the phone unplugged did not close its desktops"

# Turning the mode on without a phone starts nothing.
: >"$calls"
SERIAL='' "$tool" toggle 2>/dev/null && fail "the mode turned on without a phone"
! grep -q '^scrcpy' "$calls" || fail "the mode started scrcpy without a phone"
[[ ! -e "$XDG_RUNTIME_DIR/vivac-phone-desk.pid" ]] || fail "the mode left a watcher without a phone"

hypr="$repo_root/templates/hypr/.config/hypr/hyprland.lua.in"
for n in 1 2 3 4 5 6 7 8 9 10; do
	key=$((n % 10))
	grep -qF "hl.bind(\"SUPER + ALT + $key\", hl.dsp.exec_cmd(\"\$HOME/.local/bin/vivac-phone-desk $n\"))" "$hypr" ||
		fail "SUPER+ALT+$key does not open the phone's desktop $n"
	grep -qF "match = { title = \"^(vivac-movil-$n)\$\" }, workspace = \"$((10 + n))\"" "$hypr" ||
		fail "the phone's desktop $n is not sent to workspace $((10 + n))"
done
echo "phone desktops: 1-10 on workspaces 11-20, opened once, refused without a phone"
