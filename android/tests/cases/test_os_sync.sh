#!/usr/bin/env bash
set -Eeuo pipefail

# vivac-os-sync fetches one GrapheneOS release tag into $VIVAC_OS_ROOT/src:
# a shallow repo init of the tag (no history: a cut fetch of a full-history
# kernel restarts from zero and leaves gigabytes of tmp_pack behind), the tag's
# signature checked against GrapheneOS' allowed signers BEFORE any sync, and a
# sync of only that revision with retries. repo, git, curl and getent are
# stubs here: no network, nothing outside the sandbox.

repo_root="${REPO_ROOT:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)}"
tool="$repo_root/os/bin/vivac-os-sync"

fail() {
	printf '%s\n' "$1" >&2
	exit 1
}
sandbox="$(mktemp -d "${TMPDIR:-/tmp}/vivac-os-sync.XXXXXX")"
trap 'rm -rf -- "$sandbox"' EXIT
stubs="$sandbox/stubs"
fakehome="$sandbox/userhome"
mkdir -p "$stubs" "$sandbox/root/src/.repo/manifests" "$fakehome/.ssh"
calls="$sandbox/calls"

cat >"$stubs/repo" <<'EOF'
#!/usr/bin/env bash
printf 'repo %s\n' "$*" >>"$CALLS"
if [[ "$1" == sync ]]; then
	n=$(($(cat "$SYNC_COUNT" 2>/dev/null || echo 0) + 1))
	printf '%s' "$n" >"$SYNC_COUNT"
	((n > SYNC_FAILS))
fi
EOF
cat >"$stubs/git" <<'EOF'
#!/usr/bin/env bash
printf 'git %s\n' "$*" >>"$CALLS"
case "$1" in
describe) printf '2026111300\n' ;;
verify-tag) [[ "$TAG_OK" == 1 ]] ;;
esac
EOF
cat >"$stubs/curl" <<'EOF'
#!/usr/bin/env bash
printf 'curl %s\n' "$*" >>"$CALLS"
printf 'grapheneos-signer ssh-ed25519 AAAA\n'
EOF
printf '#!/usr/bin/env bash\nexit 0\n' >"$stubs/getent"
chmod +x "$stubs"/*

run() {
	: >"$calls"
	rm -f "$sandbox/count"
	PATH="$stubs:$PATH" HOME="$fakehome" CALLS="$calls" SYNC_COUNT="$sandbox/count" \
		VIVAC_OS_ROOT="$sandbox/root" VIVAC_OS_SYNC_WAIT=0 bash "$tool" "$@"
}

# Happy path: shallow init of the tag, verified, then a one-revision sync.
TAG_OK=1 SYNC_FAILS=0 run 2026111300 >/dev/null 2>&1 || fail "a good tag did not sync"
rg -q -- '^repo init .*-b refs/tags/2026111300' "$calls" || fail "did not init the tag"
rg -q -- '^repo init .*--depth=1' "$calls" || fail "init is not shallow"
rg -q -- '^git verify-tag 2026111300$' "$calls" || fail "tag signature not verified"
rg -q -- '^repo sync .*-c' "$calls" || fail "sync fetches more than the current revision"
rg -q -- '^repo sync .*--no-tags' "$calls" || fail "sync fetches every tag"
rg -q -- '^repo sync .*-j2( |$)' "$calls" || fail "default sync jobs is not 2"
[[ "$(rg -n '^(git verify-tag|repo sync)' "$calls" | head -1)" == *verify-tag* ]] ||
	fail "synced before verifying the tag"
[[ -s "$fakehome/.ssh/grapheneos_allowed_signers" ]] || fail "allowed signers not saved"

# A bad signature never syncs.
if TAG_OK=0 SYNC_FAILS=0 run 2026111300 >/dev/null 2>&1; then fail "accepted a bad tag signature"; fi
if rg -q '^repo sync' "$calls"; then fail "synced a tag with a bad signature"; fi

# Network drops are retried; giving up exits non-zero.
TAG_OK=1 SYNC_FAILS=2 run 2026111300 >/dev/null 2>&1 || fail "did not retry a failed sync"
[[ "$(rg -c '^repo sync' "$calls")" == 3 ]] || fail "expected 3 sync attempts"
if TAG_OK=1 SYNC_FAILS=99 VIVAC_OS_SYNC_TRIES=3 run 2026111300 >/dev/null 2>&1; then
	fail "reported success after every sync failed"
fi
[[ "$(rg -c '^repo sync' "$calls")" == 3 ]] || fail "did not stop after VIVAC_OS_SYNC_TRIES"

# Jobs can be raised on a fast link.
TAG_OK=1 SYNC_FAILS=0 VIVAC_OS_SYNC_JOBS=8 run 2026111300 >/dev/null 2>&1 || fail "jobs override broke sync"
rg -q -- '^repo sync .*-j8( |$)' "$calls" || fail "VIVAC_OS_SYNC_JOBS ignored"

# Bad input.
if run 202611130 >/dev/null 2>&1; then fail "accepted a 9-digit tag"; fi
if run >/dev/null 2>&1; then fail "accepted no tag"; fi
true
