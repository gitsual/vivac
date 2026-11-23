#!/usr/bin/env bash
# shellcheck disable=SC2016
set -Eeuo pipefail

# waybar-keep.sh: the bar comes back when it dies (windows/bin/vivac-bar-watch.ps1
# on this side): nothing is started while a bar runs, one is started when none
# does, a bar that keeps dying is given up on for a while with one notice, and
# a second keeper steps aside.

repo_root="${REPO_ROOT:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)}"
tool="$repo_root/dotfiles/waybar/.config/waybar/scripts/waybar-keep.sh"
fail() {
	printf '%s\n' "$1" >&2
	exit 1
}
sandbox="$(mktemp -d "${TMPDIR:-/tmp}/waybar-keep.XXXXXX")"
trap 'rm -rf -- "$sandbox"' EXIT
mkdir -p "$sandbox/bin"
cat >"$sandbox/bin/pgrep" <<'FAKE'
#!/usr/bin/env bash
[[ -f "$SANDBOX/running" ]]
FAKE
cat >"$sandbox/bin/fakebar" <<'FAKE'
#!/usr/bin/env bash
echo start >>"$SANDBOX/starts"
FAKE
cat >"$sandbox/bin/notify-send" <<'FAKE'
#!/usr/bin/env bash
echo "$*" >>"$SANDBOX/notices"
FAKE
chmod +x "$sandbox/bin/"*
export PATH="$sandbox/bin:$PATH" SANDBOX="$sandbox" WAYBAR_BIN="$sandbox/bin/fakebar" \
	KEEP_LOCK="$sandbox/lock" KEEP_INTERVAL=0 KEEP_STATE="$sandbox/state"

touch "$sandbox/running"
KEEP_ROUNDS=3 "$tool"
[[ ! -e "$sandbox/starts" ]] || fail "started a bar while one runs"

rm "$sandbox/running"
KEEP_ROUNDS=1 "$tool"
[[ "$(wc -l <"$sandbox/starts")" -eq 1 ]] || fail "no bar started when none ran"

: >"$sandbox/starts"
KEEP_ROUNDS=12 KEEP_MAX_RESTARTS=5 KEEP_BACKOFF=100 "$tool"
[[ "$(wc -l <"$sandbox/starts")" -le 6 ]] || fail "a dying bar was restarted without end: $(wc -l <"$sandbox/starts")"
[[ "$(wc -l <"$sandbox/notices")" -eq 1 ]] || fail "expected one notice when giving up"

exec 9>"$sandbox/lock"
flock -n 9
: >"$sandbox/starts"
KEEP_ROUNDS=2 "$tool"
[[ ! -s "$sandbox/starts" ]] || fail "a second keeper did not step aside"
printf 'ok: waybar-keep\n'
