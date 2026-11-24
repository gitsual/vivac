#!/usr/bin/env bash
set -Eeuo pipefail

# Pairing the phone with the vivac computer (android/bin/vivac-pair,
# vivac-adb, vivac-pc) in a fake Termux with a fake ssh:
# - the phone gets its own key the first time, and keeps it after;
# - over the USB cable (the computer's sshd reached on 127.0.0.1:8222 through
#   adb reverse) it pairs with no network; without the cable it falls back to
#   the computer's Tailscale name; with neither it says how to authorise the
#   phone's key and pairs nothing;
# - the route found is the "pc" host in ~/.ssh/config, a marked block, the
#   rest of the file kept;
# - vivac-adb runs the computer's adb with every argument intact, so a
#   command with spaces and quotes reaches the phone as typed;
# - vivac-pc opens a terminal on the computer.

repo_root="${REPO_ROOT:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)}"
bin="$repo_root/bin"

fail() {
	printf '%s\n' "$1" >&2
	exit 1
}
sandbox="$(mktemp -d "${TMPDIR:-/tmp}/vivac-pair.XXXXXX")"
trap 'rm -rf -- "$sandbox"' EXIT
export PREFIX="$sandbox/usr" HOME="$sandbox/home" CALLS="$sandbox/calls"
mkdir -p "$PREFIX/bin" "$HOME/.ssh" "$HOME/.config/vivac"
printf 'Host other\n  HostName example.org\n' >"$HOME/.ssh/config"
printf 'pc_host=arch\nprompt_user=lorty\n' >"$HOME/.config/vivac/settings"

fakes="$sandbox/fakes"
mkdir -p "$fakes"
# ssh: REACH lists the hosts that answer ("usb" for 127.0.0.1:8222, "arch"
# for the Tailscale name). A command run on the pc host is echoed back, one
# argument per line after the remote command line, so quoting can be checked.
cat >"$fakes/ssh" <<'FAKE'
#!/usr/bin/env bash
printf 'ssh %s\n' "$*" >>"$CALLS"
host="" port=22 args=()
while (($#)); do
	case "$1" in
	-p) port="$2"; shift 2 ;;
	-l) printf 'user %s\n' "$2" >>"$CALLS"; shift 2 ;;
	-o|-F|-i) shift 2 ;;
	-t|-T|-q|-n) shift ;;
	*) if [[ -z "$host" ]]; then host="$1"; else args+=("$1"); fi; shift ;;
	esac
done
if [[ "$host" == pc ]]; then
	host="$(awk '/^# >>> vivac pc/{b=1} b&&/HostName/{print $2; exit}' "$HOME/.ssh/config")"
	port="$(awk '/^# >>> vivac pc/{b=1} b&&/Port/{print $2; exit}' "$HOME/.ssh/config")"
fi
key="$host"; [[ "$host:$port" == 127.0.0.1:8222 ]] && key=usb
[[ " ${REACH:-} " == *" $key "* ]] || exit 255
[[ ${#args[@]} -eq 0 ]] && exit 0
printf 'REMOTE %s\n' "${args[*]}"
FAKE
cat >"$fakes/ssh-keygen" <<'FAKE'
#!/usr/bin/env bash
printf 'ssh-keygen %s\n' "$*" >>"$CALLS"
while (($#)); do [[ "$1" == -f ]] && { f="$2"; shift; }; shift; done
printf 'PRIVATE\n' >"$f"; printf 'ssh-ed25519 AAAAphone vivac-phone\n' >"$f.pub"
FAKE
chmod +x "$fakes"/*
export PATH="$fakes:$bin:$PATH"

# 1. Neither route: no pairing, and the key to authorise is shown.
out="$(REACH='' bash "$bin/vivac-pair" 2>&1)" && fail "paired with nothing reachable"
[[ -f "$HOME/.ssh/id_ed25519" ]] || fail "the phone has no key of its own"
[[ "$out" == *"ssh-ed25519 AAAAphone"* ]] || fail "the key to authorise is not shown: $out"
[[ "$out" == *"vivac-phone-ssh authorize"* ]] || fail "no hint on how to authorise it: $out"
! grep -q '>>> vivac pc' "$HOME/.ssh/config" || fail "a route was written with none reachable"

grep -q '^user lorty' "$CALLS" || fail "probed the computer as the phone's own user"

# 2. Over the cable: 127.0.0.1:8222, with no network at all.
: >"$CALLS"
REACH='usb' bash "$bin/vivac-pair" >/dev/null || fail "did not pair over USB"
! grep -q '^ssh-keygen' "$CALLS" || fail "made a new key although it had one"
block="$(sed -n '/^# >>> vivac pc/,/^# <<< vivac pc/p' "$HOME/.ssh/config")"
[[ "$block" == *"HostName 127.0.0.1"* && "$block" == *"Port 8222"* && "$block" == *"User lorty"* ]] || fail "USB route not written: $block"
grep -q '^Host other' "$HOME/.ssh/config" || fail "the user's own ssh config was lost"
[[ "$(REACH='usb' bash "$bin/vivac-pair" status)" == *usb* ]] || fail "status does not say usb"

# 3. No cable: Tailscale, the name from the vivac settings.
REACH='arch' bash "$bin/vivac-pair" >/dev/null || fail "did not pair over Tailscale"
block="$(sed -n '/^# >>> vivac pc/,/^# <<< vivac pc/p' "$HOME/.ssh/config")"
[[ "$block" == *"HostName arch"* ]] || fail "Tailscale route not written: $block"
[[ "$(grep -c '>>> vivac pc' "$HOME/.ssh/config")" == 1 ]] || fail "route block written twice"

# 4. vivac-adb: the computer's adb, every argument intact.
out="$(REACH='arch' bash "$bin/vivac-adb" shell input text "hello world's")"
[[ "$out" == *"adb shell input text hello\\ world\\'s"* ]] || fail "adb arguments not kept: $out"

# 5. vivac-pc: a terminal on the computer.
: >"$CALLS"
REACH='arch' bash "$bin/vivac-pc" >/dev/null || fail "vivac-pc failed"
grep -q '^ssh -t pc' "$CALLS" || fail "vivac-pc does not open a terminal on pc: $(cat "$CALLS")"
true
