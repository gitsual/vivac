#!/usr/bin/env bash
# shellcheck disable=SC2016
set -Eeuo pipefail

# waybar-keep.sh: the bar comes back when it dies (windows/bin/vivac-bar-watch.ps1
# on this side): nothing is started while a bar runs, one is started when none
# does (the phone's own bar, waybar -c .../waybar/phone/config, is not the main
# bar and does not count), a bar that keeps dying is given up on for a while with one notice, and
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
# The fake pgrep lists the bars in $SANDBOX/running, one "pid args" per line.
cat >"$sandbox/bin/pgrep" <<'FAKE'
#!/usr/bin/env bash
[[ -s "$SANDBOX/running" ]] || exit 1
[[ " $* " == *" -a "* ]] && cat "$SANDBOX/running"
exit 0
FAKE
cat >"$sandbox/bin/fakebar" <<'FAKE'
#!/usr/bin/env bash
sleep 0.3
echo start >>"$SANDBOX/starts"
FAKE
cat >"$sandbox/bin/notify-send" <<'FAKE'
#!/usr/bin/env bash
echo "$*" >>"$SANDBOX/notices"
FAKE
chmod +x "$sandbox/bin/"*
# The keeper starts the bar detached (setsid -f) and returns at once: wait for
# every bar it started before counting. /usr/bin/pgrep, not the fake above.
settle() {
	local tries=50
	while /usr/bin/pgrep -f "$sandbox/bin/fakebar" >/dev/null && ((tries-- > 0)); do sleep 0.1; done
}
export PATH="$sandbox/bin:$PATH" SANDBOX="$sandbox" WAYBAR_BIN="$sandbox/bin/fakebar" \
	KEEP_LOCK="$sandbox/lock" KEEP_INTERVAL=0 KEEP_STATE="$sandbox/state"

echo '100 waybar' >"$sandbox/running"
KEEP_ROUNDS=3 "$tool"
settle
[[ ! -e "$sandbox/starts" ]] || fail "started a bar while one runs"

echo "200 waybar -c $HOME/.config/waybar/phone/config -s $HOME/.config/waybar/phone/style.css" >"$sandbox/running"
KEEP_ROUNDS=1 "$tool"
settle
[[ "$(wc -l <"$sandbox/starts")" -eq 1 ]] || fail "the phone's bar was taken for the main bar"

: >"$sandbox/starts"
rm "$sandbox/running"
KEEP_ROUNDS=1 "$tool"
settle
[[ "$(wc -l <"$sandbox/starts")" -eq 1 ]] || fail "no bar started when none ran"

# A bar the keeper started must not keep the keeper's lock: once the keeper is
# gone, the next one has to be able to take it while the bar still runs.
: >"$sandbox/starts"
KEEP_ROUNDS=1 "$tool"
flock -n "$sandbox/lock" true || fail "the bar it started holds the keeper's lock"
settle

: >"$sandbox/starts"
KEEP_ROUNDS=12 KEEP_MAX_RESTARTS=5 KEEP_BACKOFF=100 "$tool"
settle
[[ "$(wc -l <"$sandbox/starts")" -le 6 ]] || fail "a dying bar was restarted without end: $(wc -l <"$sandbox/starts")"
[[ "$(wc -l <"$sandbox/notices")" -eq 1 ]] || fail "expected one notice when giving up"

exec 9>"$sandbox/lock"
flock -n 9
: >"$sandbox/starts"
KEEP_ROUNDS=2 "$tool"
settle
[[ ! -s "$sandbox/starts" ]] || fail "a second keeper did not step aside"
printf 'ok: waybar-keep\n'
