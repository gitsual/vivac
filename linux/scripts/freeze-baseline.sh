#!/usr/bin/env bash
set -Eeuo pipefail

# The default profile — what `deploy.sh` installs with no selector flags — must
# stay byte-identical as the portability program adds selectors around it. This
# holds the frozen hashes of every file Stow deploys.
#
# A unit that changes one of these files on purpose runs --update in its own PR,
# so the baseline moves in review rather than drifting silently.

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
baseline="${DEPLOY_BASELINE:-$repo_root/data/baseline-deploy.sha256}"
update=false

usage() {
	cat <<'USAGE'
Usage: scripts/freeze-baseline.sh [--update]

Verifies data/baseline-deploy.sha256 against the deployable tree.
  --update  re-freeze the baseline from the current tree
USAGE
}

while (($#)); do
	case "$1" in
	--update) update=true ;;
	-h | --help)
		usage
		exit 0
		;;
	*)
		printf 'Unknown option: %s\n' "$1" >&2
		usage >&2
		exit 2
		;;
	esac
	shift
done

header() {
	cat <<'HEADER'
# Frozen baseline of the default deploy, captured before phase 0 of the
# daily-driver-distro program. Later units assert that the default profile
# (no selector flags) is byte-identical to this. A unit that changes a file
# here intentionally updates this manifest in its own PR, which makes the
# change visible in review instead of silently moving the baseline.
# Regenerate: scripts/freeze-baseline.sh --update
HEADER
}

current() {
	(cd "$repo_root" && find dotfiles -type f -print0 | LC_ALL=C sort -z | xargs -0 sha256sum)
}

if $update; then
	{
		header
		current
	} >"$baseline"
	printf 'deploy baseline frozen: %s\n' "$baseline"
	exit 0
fi

[[ -f "$baseline" ]] || {
	printf 'deploy baseline missing: %s\n' "$baseline" >&2
	exit 1
}

expected="$(mktemp)"
actual="$(mktemp)"
trap 'rm -f -- "$expected" "$actual"' EXIT

grep -v '^#' "$baseline" >"$expected"
current >"$actual"

if ! diff -u --label 'baseline' "$expected" --label 'working tree' "$actual"; then
	printf '\ndefault profile drifted from its frozen baseline.\n' >&2
	printf 'If the change is intentional, re-freeze it in this PR: scripts/freeze-baseline.sh --update\n' >&2
	exit 1
fi

printf 'deploy baseline: unchanged (%d files)\n' "$(wc -l <"$expected")"
