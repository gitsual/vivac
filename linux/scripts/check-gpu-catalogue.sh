#!/usr/bin/env bash
set -Eeuo pipefail

# Gate for data/gpu-catalogue.tsv: every row parses, every manifest it names
# exists, every packages/gpu-*.txt is named by exactly one row, the last row
# is the catch-all, and docs/coverage-matrix.md states each family's status
# in the exact words its verified_on column implies. A family nobody has run
# must never read as observed, and a family someone has run must say where.

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
# shellcheck source=lib/gpu.sh
source "$repo_root/lib/gpu.sh"

catalogue="${GPU_CATALOGUE_FILE:-$repo_root/data/gpu-catalogue.tsv}"
matrix="${COVERAGE_MATRIX:-$repo_root/docs/coverage-matrix.md}"
packages_dir="${PACKAGES_DIR:-$repo_root/packages}"
gpu_load_catalogue "$catalogue"

status=0
problem() {
	printf 'gpu catalogue: %s\n' "$1" >&2
	status=1
}

declare -A referenced=()
for id in "${GPU_IDS[@]}"; do
	manifest="${GPU_MANIFEST["$id"]}"
	[[ "$manifest" == packages/gpu-*.txt ]] || problem "$id names a manifest outside packages/gpu-*.txt: $manifest"
	[[ -f "$repo_root/$manifest" ]] || problem "$id names a manifest that does not exist: $manifest"
	[[ ! -v referenced["$manifest"] ]] || problem "$manifest is named by both ${referenced["$manifest"]} and $id"
	referenced["$manifest"]="$id"

	case "${GPU_VERIFIED["$id"]}" in
	workstation) expected="Observed on the author's workstation" ;;
	vm) expected='VM-verified' ;;
	-) expected='Recommendation, untested on hardware' ;;
	esac
	row="$(grep -F "| \`$id\` |" "$matrix" || true)"
	[[ -n "$row" ]] || {
		problem "$id has no row in docs/coverage-matrix.md"
		continue
	}
	[[ "$row" == *"| $expected |"* ]] || problem "$id: coverage matrix says '${row##*| }' but the catalogue implies '$expected'"
	if [[ "$expected" == 'Recommendation, untested on hardware' ]] && grep -Fq "| \`$id\` |" <<<"$row" && [[ "$row" == *Observed* ]]; then
		problem "$id reads as observed without a verified_on"
	fi
done

for manifest in "$packages_dir"/gpu-*.txt; do
	name="packages/$(basename -- "$manifest")"
	[[ "$name" == "$GPU_PRIME_MANIFEST" ]] && continue # reached by lib/gpu.sh on hybrids
	[[ -v referenced["$name"] ]] || problem "$name is not named by any catalogue row"
done
[[ -f "$repo_root/$GPU_PRIME_MANIFEST" ]] || problem "the PRIME offload manifest $GPU_PRIME_MANIFEST is missing"

last="${GPU_IDS[-1]}"
[[ "${GPU_VENDOR["$last"]}" == '*' && "${GPU_RANGES["$last"]}" == '*' ]] || problem "the last row ($last) must be the catch-all (* *)"

observed=0
for id in "${GPU_IDS[@]}"; do
	[[ "${GPU_VERIFIED["$id"]}" == '-' ]] || observed=$((observed + 1))
done

((status == 0)) || exit 1
printf 'gpu catalogue: %d families, %d observed, every manifest named once, matrix agrees\n' "${#GPU_IDS[@]}" "$observed"
