#!/usr/bin/env bash
set -Eeuo pipefail

# Every script that boots a machine hands the guest the same disc, built from
# one definition of what "the repository" is. Three hand-rolled copies drifted
# once already: open-tested-vm.sh never learned to skip dist/, so re-opening a
# VM after publishing an image tried to tar the published image into the disc
# it was writing, and never finished.

repo_root="${REPO_ROOT:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)}"
helper="$repo_root/lib/repository-iso.sh"

fail() {
	printf '%s\n' "$1" >&2
	exit 1
}
[[ -f "$helper" ]] || fail 'the shared repository-disc helper is missing'

# The heavy directories are named once, in the helper, and every one of them is
# named: a published image, a build overlay and a test overlay all live inside
# the tree and none of them belongs on the disc.
for excluded in .git .vm-test .vm-image dist; do
	grep -Fq -- "--exclude=$excluded" "$helper" ||
		fail "the repository disc would carry $excluded into the guest"
done

# ...and nobody builds that disc by hand any more.
while IFS= read -r script; do
	grep -Fq 'repository.iso' "$script" || continue
	[[ "$script" == "$helper" ]] && continue
	# shellcheck disable=SC2016  # the pattern is literal shell source to search for
	grep -Fq 'repository_iso "$repo_root" "$run"' "$script" ||
		fail "$(basename -- "$script") builds the repository disc itself instead of calling the helper"
	grep -Eq '^tar .*--exclude=.*repository\.tar\.gz' "$script" &&
		fail "$(basename -- "$script") still packs the repository itself"
done < <(find "$repo_root/scripts" -type f -name '*.sh' | LC_ALL=C sort)

printf 'repository disc: one definition, %s exclusions, no hand-rolled copies\n' \
	"$(grep -o -- '--exclude=' "$helper" | wc -l)"
