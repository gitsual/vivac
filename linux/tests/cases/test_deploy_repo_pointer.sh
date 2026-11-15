#!/usr/bin/env bash
set -Eeuo pipefail

# ~/.config/vivac/repo tells every runtime script (the waybar dispatcher,
# hypridle's dpms, the shared-settings sync) where the checkout is. A checkout
# that moved left it naming the old root, and those scripts broke the moment
# the old road went away. deploy.sh writes it like deploy-host.sh does: the old
# value backed up, a dry run only saying so, a right value left alone.

repo_root="${REPO_ROOT:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)}"
deploy="$repo_root/scripts/deploy.sh"
sandbox="$(mktemp -d "${TMPDIR:-/tmp}/vivac-repoptr.XXXXXX")"
trap 'rm -rf -- "$sandbox"' EXIT
fail() {
	printf '%s\n' "$1" >&2
	exit 1
}
home="$sandbox/home"
pointer="$home/.config/vivac/repo"
mkdir -p -- "$home/.config/vivac"
printf '%s\n' "$sandbox/old-root" >"$pointer"
run() { HOME="$home" XDG_CONFIG_HOME="$home/.config" XDG_STATE_HOME="$sandbox/state" DEPLOY_BACKUP_ROOT="$sandbox/bk" "$deploy" --no-theme "$@"; }

out="$(run --dry-run welcome 2>&1)" || fail "the dry run failed: $out"
[[ "$out" == *"would write $pointer ($repo_root)"* ]] || fail "the dry run did not plan the pointer: $out"
[[ "$(cat "$pointer")" == "$sandbox/old-root" ]] || fail 'the dry run wrote the pointer'

out="$(run welcome 2>&1)" || fail "deploy failed: $out"
[[ "$(cat "$pointer")" == "$repo_root" ]] || fail "the pointer still names $(cat "$pointer")"
[[ "$(cat "$sandbox/bk/.config/vivac/repo")" == "$sandbox/old-root" ]] || fail 'the old pointer was not backed up'
[[ "$out" == *"wrote $pointer ($repo_root)"* ]] || fail "deploy did not say so: $out"

# Right already: untouched, nothing said, nothing backed up.
rm -rf -- "$sandbox/bk"
out="$(run welcome 2>&1)" || fail "the second deploy failed: $out"
[[ "$out" != *"$pointer"* ]] || fail "a right pointer was rewritten: $out"
[[ ! -e "$sandbox/bk/.config/vivac/repo" ]] || fail 'a right pointer was backed up'

# None yet: written, nothing to back up.
rm -f -- "$pointer"
run welcome >/dev/null 2>&1 || fail 'deploy without a pointer failed'
[[ "$(cat "$pointer")" == "$repo_root" ]] || fail 'a missing pointer was not written'

printf 'repo pointer: written on deploy, old value backed up, dry run inert, a right one untouched\n'
