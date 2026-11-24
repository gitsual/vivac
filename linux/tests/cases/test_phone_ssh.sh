#!/usr/bin/env bash
# The fakes are shell source written out literally: their $ expands when they run.
# shellcheck disable=SC2016
set -Eeuo pipefail

# The computer's own sshd for the phone (vivac-phone-ssh), against fake
# sshd, ssh-keygen, adb and tailscale. It runs as the user, not root: on port
# 8222, on 127.0.0.1 (the phone reaches it over the USB cable through adb
# reverse, with no network) and on this computer's Tailscale address when
# there is one; keys only, and only the keys authorised for the phone, kept
# apart from ~/.ssh/authorized_keys. While it serves, every phone plugged in
# gets the reverse once. authorize adds a phone's key once, and refuses
# anything that is not one ssh public key.

repo_root="${REPO_ROOT:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)}"
tool="$repo_root/dotfiles/bridge/.local/bin/vivac-phone-ssh"
fail() {
	printf '%s\n' "$1" >&2
	exit 1
}
sandbox="$(mktemp -d "${TMPDIR:-/tmp}/vivac-phone-ssh.XXXXXX")"
trap 'pkill -f -- "$sandbox" 2>/dev/null || true; rm -rf -- "$sandbox"' EXIT
mkdir -p "$sandbox/bin"
calls="$sandbox/calls"
cat >"$sandbox/bin/adb" <<'FAKE'
#!/usr/bin/env bash
if [[ "$*" == devices ]]; then printf 'List of devices attached\nPHONE1\tdevice\n'; exit 0; fi
printf 'adb %s\n' "$*" >>"$CALLS"
if [[ "$*" == *'reverse --list' ]]; then
	grep -q 'reverse tcp:8222 tcp:8222' "$CALLS" && printf 'UsbFfs tcp:8222 tcp:8222\n'
fi
exit 0
FAKE
cat >"$sandbox/bin/tailscale" <<'FAKE'
#!/usr/bin/env bash
[[ "$*" == 'ip -4' ]] && echo "${TS_IP:-}"
FAKE
cat >"$sandbox/bin/ssh-keygen" <<'FAKE'
#!/usr/bin/env bash
printf 'ssh-keygen %s\n' "$*" >>"$CALLS"
while (($#)); do [[ "$1" == -f ]] && { f="$2"; shift; }; shift; done
[[ -n "${f:-}" ]] && { printf 'HOSTKEY\n' >"$f"; printf 'ssh-ed25519 AAAAhost\n' >"$f.pub"; }
exit 0
FAKE
cat >"$sandbox/bin/sshd" <<'FAKE'
#!/usr/bin/env bash
printf 'sshd %s\n' "$*" >>"$CALLS"
exec sleep 60
FAKE
chmod +x "$sandbox/bin"/*
export PATH="$sandbox/bin:$PATH" CALLS="$calls" ADB="$sandbox/bin/adb" SSHD="$sandbox/bin/sshd"
export XDG_STATE_HOME="$sandbox/state" VIVAC_PHONE_SSH_CHECK=0.2
: >"$calls"

# The configuration: user-run, keys only, the phone's keys only.
conf="$(TS_IP=100.112.152.66 bash "$tool" config)"
for want in 'Port 8222' 'ListenAddress 127.0.0.1' 'ListenAddress 100.112.152.66' \
	'PasswordAuthentication no' 'KbdInteractiveAuthentication no' 'UsePAM no' \
	"AuthorizedKeysFile $sandbox/state/vivac/phone-ssh/authorized_keys" \
	"HostKey $sandbox/state/vivac/phone-ssh/host_ed25519"; do
	grep -qxF -- "$want" <<<"$conf" || fail "sshd config lacks: $want"
done
conf="$(TS_IP='' bash "$tool" config)"
[[ "$(grep -c '^ListenAddress' <<<"$conf")" == 1 ]] || fail "listens beyond 127.0.0.1 with no Tailscale"

# authorize: one ssh public key, once; anything else refused.
bash "$tool" authorize 'ssh-ed25519 AAAAphone vivac-phone' >/dev/null || fail "authorize failed"
bash "$tool" authorize 'ssh-ed25519 AAAAphone vivac-phone' >/dev/null || fail "authorize again failed"
keys="$sandbox/state/vivac/phone-ssh/authorized_keys"
[[ "$(grep -c AAAAphone "$keys")" == 1 ]] || fail "key added twice"
bash "$tool" authorize 'rm -rf /' >/dev/null 2>&1 && fail "authorized something that is not a key"
bash "$tool" authorize $'ssh-ed25519 AAAAx\nssh-rsa AAAAy' >/dev/null 2>&1 && fail "authorized two lines at once"
[[ "$(wc -l <"$keys")" == 1 ]] || fail "a refused key was written"

# serve: sshd with that configuration, the reverse made once per phone.
TS_IP='' bash "$tool" serve &
serve=$!
for _ in $(seq 50); do grep -q '^adb -s PHONE1 reverse tcp:8222' "$calls" && break; sleep 0.1; done
sleep 0.6
kill "$serve" 2>/dev/null || true
wait "$serve" 2>/dev/null || true
grep -q "^sshd -D -e -f $sandbox/state/vivac/phone-ssh/sshd_config" "$calls" || fail "sshd not started on its config: $(cat "$calls")"
[[ -f "$sandbox/state/vivac/phone-ssh/host_ed25519" ]] || fail "no host key made"
[[ "$(grep -c '^adb -s PHONE1 reverse tcp:8222 tcp:8222' "$calls")" == 1 ]] || fail "reverse not made exactly once: $(cat "$calls")"
! pgrep -f "$sandbox/bin/sshd" >/dev/null || fail "sshd left running after serve ended"
echo "phone ssh: user sshd on 8222 for the phone's keys only, over USB and Tailscale"
