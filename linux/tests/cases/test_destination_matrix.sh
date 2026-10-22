#!/usr/bin/env bash
set -Eeuo pipefail

# docs/destination-tests.md: every claim has exactly one of the three statuses,
# every GPU family of the catalogue has a row, and a GPU row's status agrees
# with the catalogue's verified_on column. The README links the page.

repo_root="${REPO_ROOT:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)}"
doc="$repo_root/docs/destination-tests.md"

fail() {
	printf '%s\n' "$1" >&2
	exit 1
}
[[ -f "$doc" ]] || fail 'docs/destination-tests.md is missing'
rows=0
while IFS= read -r line; do
	[[ "$line" == '| Claim'* || "$line" == '|---'* ]] && continue
	claim="$(sed -E 's/^\| *//; s/ *\|.*$//' <<<"$line")"
	status="$(sed -E 's/^\|[^|]*\| *//; s/ *\|$//' <<<"$line")"
	[[ -n "$claim" ]] || fail "a row has no claim: $line"
	case "$status" in
	'verified on author hardware' | 'VM-verified' | 'untested') ;;
	'') fail "blank status: $claim" ;;
	*) fail "unknown status '$status': $claim" ;;
	esac
	rows=$((rows + 1))
done < <(grep -E '^\|' "$doc")
((rows >= 25)) || fail "only $rows rows; the matrix lost claims"

while IFS=$'\t' read -r id verified; do
	row="$(grep -E "^\| ${id}[: ]" "$doc" || true)"
	[[ -n "$row" ]] || fail "GPU family $id has no row"
	case "$verified" in
	-) expected=untested ;;
	vm) expected='VM-verified' ;;
	*) expected='verified on author hardware' ;;
	esac
	[[ "$row" == *"| $expected |" ]] || fail "$id: the matrix says '$row', the catalogue says $expected"
done < <(awk -F'\t' '!/^#/ && NF { print $1 "\t" $5 }' "$repo_root/data/gpu-catalogue.tsv")

for needle in 'ReGreet' 'tuigreet' 'fcitx5' 'Mozc' 'hypridle'; do
	grep -q "$needle" "$doc" || fail "no claim about $needle"
done
grep -q 'docs/destination-tests.md' "$repo_root/README.md" || fail 'the README does not link the destination tests'
grep -q 'author-run evidence' "$repo_root/README.md" || fail 'the README no longer says the evidence is author-run'

printf 'destination matrix: %d claims, one status each, GPU rows agree with the catalogue\n' "$rows"
