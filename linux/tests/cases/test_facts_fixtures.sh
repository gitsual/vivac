#!/usr/bin/env bash
set -Eeuo pipefail

# Every archetype fixture must emit exactly its golden facts file, byte for
# byte. This is the regression net for the whole detection layer: a detector
# changed without intent shows up here as a diff against a machine shape the
# author cannot otherwise reach.
#
# Goldens are regenerated deliberately with tests/update-golden.sh, never from
# inside this test — a golden that heals itself asserts nothing.

repo_root="${REPO_ROOT:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)}"
cli="$repo_root/scripts/hardware-facts.sh"

sandbox="$(mktemp -d "${TMPDIR:-/tmp}/vivac-fixtures.XXXXXX")"
trap 'rm -rf -- "$sandbox"' EXIT

fail() {
	printf '%s\n' "$1" >&2
	exit 1
}

mapfile -t fixtures < <(find "$repo_root/tests/fixtures" -mindepth 1 -maxdepth 1 -type d | LC_ALL=C sort)
((${#fixtures[@]} > 0)) || fail 'no archetype fixtures found'

checked=0
for fixture in "${fixtures[@]}"; do
	archetype="$(basename -- "$fixture")"
	golden="$repo_root/tests/golden/$archetype/hardware-facts"

	[[ -d "$fixture/sysroot" ]] || fail "$archetype: fixture has no sysroot/ tree"
	[[ -r "$golden" ]] ||
		fail "$archetype: fixture has no golden facts file; run tests/update-golden.sh"

	emitted="$sandbox/$archetype"
	SYSROOT="$fixture/sysroot" FACTS_FILE="$emitted" bash "$cli" --emit >/dev/null

	if ! cmp -s "$golden" "$emitted"; then
		printf '%s: emitted facts differ from the golden file\n' "$archetype" >&2
		diff -u --label "golden/$archetype" "$golden" --label 'emitted' "$emitted" >&2 || true
		printf '\nIf this change is intended, re-run tests/update-golden.sh in the same PR.\n' >&2
		exit 1
	fi

	# Emission is deterministic: the same fixture twice must give the same bytes,
	# or golden comparison would be noise rather than signal.
	SYSROOT="$fixture/sysroot" FACTS_FILE="$emitted.again" bash "$cli" --emit >/dev/null
	cmp -s "$emitted" "$emitted.again" ||
		fail "$archetype: two emissions from one fixture produced different bytes"

	checked=$((checked + 1))
done

# Every golden must belong to a fixture, or a deleted archetype leaves a stale
# expectation behind that nothing ever runs.
while IFS= read -r golden_dir; do
	archetype="$(basename -- "$golden_dir")"
	[[ -d "$repo_root/tests/fixtures/$archetype/sysroot" ]] ||
		fail "$archetype: golden file with no fixture behind it"
done < <(find "$repo_root/tests/golden" -mindepth 1 -maxdepth 1 -type d)

# The archetypes must actually disagree about something: a fixture whose facts
# match another's adds review weight without adding coverage. Compared on the
# core facts only, so a later unit may legitimately add two fixtures that differ
# solely by graphics.
distinct="$(for golden in "$repo_root"/tests/golden/*/hardware-facts; do
	grep -v '^#' "$golden" | LC_ALL=C sort | tr '\n' ' '
	printf '\n'
done | LC_ALL=C sort -u | wc -l)"
((distinct > 1)) || fail 'every archetype produced identical facts; the fixtures test nothing'

printf 'fixtures: %d archetypes match their goldens byte-for-byte (%d distinct fact sets)\n' \
	"$checked" "$distinct"
