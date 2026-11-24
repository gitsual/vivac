#!/usr/bin/env bash
set -Eeuo pipefail

# Claude Code on the phone (android/bin/claude, vivac-claude). There is no
# Android build: the linux-arm64 one runs through glibc-runner (grun).
# - without it installed, `claude` says how to install it;
# - `vivac-claude update` installs the latest version from npm, and a second
#   update with nothing new downloads nothing;
# - `claude ARGS` runs that version through grun with ARGS intact and its own
#   auto-updater off (it would fetch a build Android cannot run directly);
# - a newer version replaces it, and only the one before it is kept.

repo_root="${REPO_ROOT:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)}"
bin="$repo_root/bin"

fail() {
	printf '%s\n' "$1" >&2
	exit 1
}
sandbox="$(mktemp -d "${TMPDIR:-/tmp}/vivac-claude.XXXXXX")"
trap 'rm -rf -- "$sandbox"' EXIT
export PREFIX="$sandbox/usr" HOME="$sandbox/home" CALLS="$sandbox/calls" LATEST=2.1.331
mkdir -p "$PREFIX/bin" "$HOME"
fakes="$sandbox/fakes"
mkdir -p "$fakes"
cat >"$fakes/npm" <<'FAKE'
#!/usr/bin/env bash
printf 'npm %s\n' "$*" >>"$CALLS"
case "$1" in
view) echo "$LATEST" ;;
pack)
	v="${2##*@}"
	mkdir -p p/package
	printf '#!/bin/sh\necho "claude %s $*"\n' "$v" >p/package/claude
	chmod +x p/package/claude
	tar czf "anthropic-ai-claude-code-linux-arm64-$v.tgz" -C p package
	rm -rf p
	echo "anthropic-ai-claude-code-linux-arm64-$v.tgz"
	;;
esac
FAKE
cat >"$fakes/grun" <<'FAKE'
#!/usr/bin/env bash
printf 'grun DISABLE_AUTOUPDATER=%s %s\n' "${DISABLE_AUTOUPDATER:-}" "$*" >>"$CALLS"
exec "$@"
FAKE
chmod +x "$fakes"/*
export PATH="$fakes:$bin:$PATH"

out="$(bash "$bin/claude" --version 2>&1)" && fail "ran with nothing installed"
[[ "$out" == *"vivac-claude update"* ]] || fail "no hint to install: $out"

bash "$bin/vivac-claude" update >/dev/null || fail "update failed"
grep -q 'npm pack @anthropic-ai/claude-code-linux-arm64@2.1.331' "$CALLS" || fail "did not fetch the linux-arm64 build"
out="$(bash "$bin/claude" -p "two words")"
[[ "$out" == 'claude 2.1.331 -p two words' ]] || fail "arguments not kept: $out"
grep -q '^grun DISABLE_AUTOUPDATER=1 ' "$CALLS" || fail "not run through grun with its updater off"

: >"$CALLS"
bash "$bin/vivac-claude" update >/dev/null || fail "second update failed"
! grep -q 'npm pack' "$CALLS" || fail "downloaded again with nothing new"

LATEST=2.1.400 bash "$bin/vivac-claude" update >/dev/null || fail "update to a newer version failed"
[[ "$(bash "$bin/claude")" == 'claude 2.1.400 ' ]] || fail "newer version not in use"
LATEST=2.1.500 bash "$bin/vivac-claude" update >/dev/null
kept="$(ls "$HOME/.local/lib/vivac-claude/versions" | sort | tr '\n' ' ')"
[[ "$kept" == '2.1.400 2.1.500 ' ]] || fail "should keep only the current and the one before: $kept"
true
