#!/usr/bin/env bash
# The fakes are shell source written out literally: their $ expands when they run.
# shellcheck disable=SC2016
set -Eeuo pipefail

# vivac-phone-pull: bring a photo the phone's vivac-mcp took to this PC, so
# Hermes can send it with MEDIA:<path>. Against a fake ssh: it asks the
# phone's vivac-gate for exactly "vivac-photo-get NAME" on the configured host,
# accepts the bare name or the phone-side path vivac-mcp returned, writes into
# <xdg Downloads>/vivac-link/phone/ and prints that absolute path only; a name
# not shaped like a vivac photo is refused without calling ssh; a failed or
# empty transfer leaves no file behind.

repo_root="${REPO_ROOT:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)}"
tool="$repo_root/dotfiles/bridge/.local/bin/vivac-phone-pull"

fail() {
	printf '%s\n' "$1" >&2
	exit 1
}
sandbox="$(mktemp -d "${TMPDIR:-/tmp}/vivac-pull.XXXXXX")"
trap 'rm -rf -- "$sandbox"' EXIT
mkdir -p "$sandbox/bin" "$sandbox/me/.config"
export HOME="$sandbox/me" XDG_CONFIG_HOME="$sandbox/me/.config" CALLS="$sandbox/calls"
printf 'XDG_DOWNLOAD_DIR="$HOME/Descargas"\n' >"$XDG_CONFIG_HOME/user-dirs.dirs"
cat >"$sandbox/bin/ssh" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$CALLS"
[[ -n "${FAIL:-}" ]] && exit 255
printf 'JPEG'
FAKE
chmod +x "$sandbox/bin/ssh"
export PATH="$sandbox/bin:$PATH"
want="$HOME/Descargas/vivac-link/phone/photo-20261115-123456.jpg"

out="$(bash "$tool" /data/data/com.termux/files/usr/../photos/photo-20261115-123456.jpg)" ||
	fail "pull failed"
[[ "$out" == "$want" ]] || fail "printed '$out', want '$want'"
[[ "$(cat "$want")" == JPEG ]] || fail "file content wrong"
grep -qx -- '-o BatchMode=yes pixel vivac-photo-get photo-20261115-123456.jpg' "$CALLS" || fail "ssh asked: $(cat "$CALLS")"

: >"$CALLS"
VIVAC_PHONE_HOST=otherphone bash "$tool" photo-20261115-000000.jpg >/dev/null || fail "bare name refused"
grep -q 'otherphone vivac-photo-get photo-20261115-000000.jpg' "$CALLS" || fail "host override ignored"

: >"$CALLS"
for bad in ../x.jpg /etc/passwd 'photo-1.jpg' 'photo-20261115-123456.jpg;sh'; do
	if bash "$tool" "$bad" >/dev/null 2>&1; then fail "accepted '$bad'"; fi
done
[[ ! -s "$CALLS" ]] || fail "ssh called for a refused name"

if FAIL=1 bash "$tool" photo-20261115-111111.jpg >/dev/null 2>&1; then fail "failed transfer reported success"; fi
[[ ! -e "$HOME/Descargas/vivac-link/phone/photo-20261115-111111.jpg" ]] || fail "failed transfer left a file"

# A vivac ssh_config (the "pixel" alias lives there, not in ~/.ssh/config)
# is passed with -F when present.
mkdir -p "$XDG_CONFIG_HOME/vivac"
: >"$XDG_CONFIG_HOME/vivac/ssh_config"
: >"$CALLS"
bash "$tool" photo-20261115-222222.jpg >/dev/null || fail "pull with ssh_config failed"
grep -qx -- "-F $XDG_CONFIG_HOME/vivac/ssh_config -o BatchMode=yes pixel vivac-photo-get photo-20261115-222222.jpg" "$CALLS" ||
	fail "ssh_config not used: $(cat "$CALLS")"
