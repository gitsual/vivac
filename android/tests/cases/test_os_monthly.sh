#!/usr/bin/env bash
set -Eeuo pipefail

# vivac-os-monthly decides and drives one update run: it asks upstream for
# the current build; if it is not newer than the last build recorded in
# STATE_DIR/last-build it does nothing; otherwise it runs build, sign and
# publish (testing) in order, records the new build only when all succeed,
# and reports the outcome through the notify command either way.

repo_root="${REPO_ROOT:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)}"
tool="$repo_root/os/bin/vivac-os-monthly"

fail() {
	printf '%s\n' "$1" >&2
	exit 1
}
sandbox="$(mktemp -d "${TMPDIR:-/tmp}/vivac-os-monthly.XXXXXX")"
trap 'rm -rf -- "$sandbox"' EXIT
mkdir -p "$sandbox/bin" "$sandbox/state"
for step in upstream build sign publish notify; do
	cat >"$sandbox/bin/$step" <<STEP
#!/usr/bin/env bash
printf '%s %s\n' "$step" "\$*" >>"$sandbox/calls"
[[ "$step" == upstream ]] && printf '%s\n' "\${FAKE_UPSTREAM}"
[[ "\${FAKE_FAIL:-}" == "$step" ]] && exit 1
exit 0
STEP
	chmod +x "$sandbox/bin/$step"
done
export VIVAC_OS_STATE="$sandbox/state" \
	VIVAC_OS_UPSTREAM_CMD="$sandbox/bin/upstream" VIVAC_OS_BUILD_CMD="$sandbox/bin/build" \
	VIVAC_OS_SIGN_CMD="$sandbox/bin/sign" VIVAC_OS_PUBLISH_CMD="$sandbox/bin/publish" \
	VIVAC_OS_NOTIFY_CMD="$sandbox/bin/notify"
run() { rm -f "$sandbox/calls"; bash "$tool"; }

printf '2026111300\n' >"$sandbox/state/last-build"
FAKE_UPSTREAM=2026111300 run || fail "up-to-date run failed"
! grep -qE '^(build|sign|publish)' "$sandbox/calls" || fail "built when already up to date"

FAKE_UPSTREAM=2026121000 run || fail "update run failed"
[[ "$(grep -oE '^(build|sign|publish)' "$sandbox/calls" | tr '\n' ' ')" == 'build sign publish ' ]] || fail "steps not run in order"
grep -q '^build 2026121000' "$sandbox/calls" || fail "build not given the new tag"
[[ "$(cat "$sandbox/state/last-build")" == 2026121000 ]] || fail "new build not recorded"
grep -q '^notify .*2026121000' "$sandbox/calls" || fail "success not notified"

if FAKE_UPSTREAM=2027010500 FAKE_FAIL=sign run; then fail "a failed sign reported success"; fi
! grep -q '^publish' "$sandbox/calls" || fail "published after a failed sign"
[[ "$(cat "$sandbox/state/last-build")" == 2026121000 ]] || fail "recorded a failed build"
grep -qi '^notify .*fail' "$sandbox/calls" || fail "failure not notified"

if FAKE_UPSTREAM='' run; then fail "an empty upstream answer reported success"; fi
! grep -qE '^build' "$sandbox/calls" || fail "built without an upstream answer"
FAKE_UPSTREAM=2026110100 run || fail "older upstream run failed"
! grep -qE '^build' "$sandbox/calls" || fail "built an older upstream build"

# The Pi only accepts SSH from the LAN. On the PC the bare name "nasbackup"
# resolves to its tailnet address first (MagicDNS), where port 22 is closed,
# so the default mirror target must be the LAN name served by the home DNS.
grep -qx 'pi_host=nasbackup\.home\.arpa' "$tool" ||
	fail "default mirror target is not the Pi's LAN name"
