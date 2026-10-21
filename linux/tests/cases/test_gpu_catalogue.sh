#!/usr/bin/env bash
set -Eeuo pipefail

# The catalogue maps every fixture's devices to the family the coverage
# matrix promises, a hybrid machine is reported rather than guessed, an
# unknown device is generic, and the gate refuses each way the catalogue or
# the matrix can rot: a duplicate family, a missing or orphan manifest, a
# bad range, and a status the matrix does not agree with.

repo_root="${REPO_ROOT:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)}"
# shellcheck source=lib/kv.sh
source "$repo_root/lib/kv.sh"
# shellcheck source=lib/gpu.sh
source "$repo_root/lib/gpu.sh"

sandbox="$(mktemp -d "${TMPDIR:-/tmp}/vivac-gpu.XXXXXX")"
trap 'rm -rf -- "$sandbox"' EXIT

fail() {
	printf '%s\n' "$1" >&2
	exit 1
}

gpu_load_catalogue "$repo_root/data/gpu-catalogue.tsv" || fail 'the committed catalogue does not load'

# --- every archetype resolves to what the golden facts record -------------------------
expect() {
	local archetype="$1" want="$2" got
	got="$(gpu_families "$(kv_get "$repo_root/tests/golden/$archetype/hardware-facts" gpu_devices)")"
	[[ "$got" == "$want" ]] || fail "$archetype: families '$got', expected '$want'"
	[[ "$(kv_get "$repo_root/tests/golden/$archetype/hardware-facts" gpu_families)" == "$want" ]] ||
		fail "$archetype: the golden facts file disagrees with the catalogue"
}
expect desktop-nvidia nvidia_open
expect laptop-amd-hybrid 'amd_amdgpu nvidia_open'
expect laptop-intel intel_i915
expect vm-virtio virtio
expect headless-unknown generic

# --- ranges pick the right NVIDIA and Intel branch, and order breaks ties ---------------
[[ "$(gpu_family_for_device 10de:1b80)" == nvidia_proprietary ]] || fail 'Pascal must be proprietary'
[[ "$(gpu_family_for_device 10de:1180)" == nvidia_legacy_470 ]] || fail 'Kepler must be legacy 470'
[[ "$(gpu_family_for_device 8086:6420)" == intel_xe ]] || fail 'Lunar Lake must be xe'
[[ "$(gpu_family_for_device 8086:e20b)" == intel_xe ]] || fail 'Battlemage must be xe'
[[ "$(gpu_family_for_device 8086:0416)" == intel_i915 ]] || fail 'Haswell must be i915'
[[ "$(gpu_family_for_device 1234:5678)" == generic ]] || fail 'an unknown vendor must be generic'
[[ "$(gpu_family_for_device garbage)" == generic ]] || fail 'a malformed id must be generic, not a crash'
[[ "$(gpu_families '10de:2504 10de:2504')" == nvidia_open ]] || fail 'duplicate devices must collapse to one family'

# --- a hybrid machine is reported, not resolved to one stack -------------------------------
# shellcheck disable=SC2034  # forwarded by name to gpu_single_family
declare -A facts=()
kv_load "$repo_root/tests/golden/laptop-amd-hybrid/hardware-facts" facts
gpu_single_family facts >/dev/null && fail 'a hybrid machine resolved to a single family'
kv_load "$repo_root/tests/golden/desktop-nvidia/hardware-facts" facts
[[ "$(gpu_single_family facts)" == nvidia_open ]] || fail 'a sole NVIDIA machine must resolve to nvidia_open'
[[ "$(gpu_status nvidia_open)" == observed && "$(gpu_status virtio)" == observed ]] || fail 'the two run families must be observed'
for id in nvidia_proprietary nvidia_legacy_470 intel_xe intel_i915 amd_amdgpu generic; do
	[[ "$(gpu_status "$id")" == recommendation ]] || fail "$id must be a recommendation: nobody has run it"
done

# --- the gate, on a disposable copy ------------------------------------------------------
copy="$sandbox/repo"
mkdir -p -- "$copy/data" "$copy/docs" "$copy/packages" "$copy/lib" "$copy/scripts"
cp -- "$repo_root/data/gpu-catalogue.tsv" "$copy/data/"
cp -- "$repo_root/docs/coverage-matrix.md" "$copy/docs/"
cp -- "$repo_root"/packages/gpu-*.txt "$copy/packages/"
cp -- "$repo_root/lib/gpu.sh" "$copy/lib/"
cp -- "$repo_root/scripts/check-gpu-catalogue.sh" "$copy/scripts/"
gate() { bash "$copy/scripts/check-gpu-catalogue.sh"; }
refuse() {
	local reason="$1" needle="$2" output
	output="$(gate 2>&1)" && fail "gate passed with $reason"
	[[ "$output" == *"$needle"* ]] || fail "gate refused $reason without naming it: $output"
}
gate >/dev/null || fail 'gate: refused an unmodified copy'

printf 'virtio\t1af4\t*\tpackages/gpu-virtio.txt\tvm\tgpu.virtio\n' >>"$copy/data/gpu-catalogue.tsv"
refuse 'a duplicated family' 'listed twice'
sed -i '$d' "$copy/data/gpu-catalogue.tsv"

sed -i 's|packages/gpu-amd_amdgpu.txt|packages/gpu-amd_missing.txt|' "$copy/data/gpu-catalogue.tsv"
refuse 'a missing manifest' 'does not exist'
sed -i 's|packages/gpu-amd_missing.txt|packages/gpu-amd_amdgpu.txt|' "$copy/data/gpu-catalogue.tsv"

printf 'mesa\n' >"$copy/packages/gpu-orphan.txt"
refuse 'an orphan manifest' 'not named by any catalogue row'
rm -- "$copy/packages/gpu-orphan.txt"

sed -i 's|1340-1dff|1dff-1340|' "$copy/data/gpu-catalogue.tsv"
refuse 'an inverted range' 'bad device ranges'
sed -i 's|1dff-1340|1340-1dff|' "$copy/data/gpu-catalogue.tsv"

# A family nobody ran must never read as observed: flip the matrix and the gate must say so.
# shellcheck disable=SC2016  # the \1 is sed's, not the shell's
sed -i 's/| `amd_amdgpu` |\(.*\)| Recommendation, untested on hardware |/| `amd_amdgpu` |\1| Observed on the author'"'"'s workstation |/' "$copy/docs/coverage-matrix.md"
refuse 'a matrix claiming an unverified family is observed' 'coverage matrix says'
cp -- "$repo_root/docs/coverage-matrix.md" "$copy/docs/"

# And the other direction: a run family the matrix demotes.
sed -i 's/^virtio\t1af4\t\*\tpackages\/gpu-virtio.txt\tvm/virtio\t1af4\t*\tpackages\/gpu-virtio.txt\t-/' "$copy/data/gpu-catalogue.tsv"
refuse 'a catalogue and matrix disagreeing on virtio' 'coverage matrix says'

printf 'gpu catalogue: 5 archetypes resolved, hybrid reported, 6 gate refusals\n'
