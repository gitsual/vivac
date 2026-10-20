#!/usr/bin/env bash
set -Eeuo pipefail

# A hybrid machine gets both families and PRIME offload, never a compositor-
# wide NVIDIA environment; DKMS stacks get the headers of every installed
# kernel; Secure Boot with a DKMS module is warned about, not hidden and not
# refused. Fixtures: the AMD+NVIDIA laptop (two kernels), the NVIDIA desktop,
# the Intel laptop, plus facts edited in place for Secure Boot.

repo_root="${REPO_ROOT:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)}"
# shellcheck source=lib/kv.sh
source "$repo_root/lib/kv.sh"
# shellcheck source=lib/gpu.sh
source "$repo_root/lib/gpu.sh"

sandbox="$(mktemp -d "${TMPDIR:-/tmp}/vivac-hybrid.XXXXXX")"
trap 'rm -rf -- "$sandbox"' EXIT

fail() {
	printf '%s\n' "$1" >&2
	exit 1
}
gpu_load_catalogue "$repo_root/data/gpu-catalogue.tsv"

declare -A facts=()
load() {
	# shellcheck disable=SC2034  # forwarded by name to lib/gpu.sh
	facts=()
	kv_load "$repo_root/tests/golden/$1/hardware-facts" facts
}
has() { grep -Fxq -- "$2" <<<"$1"; }

# --- hybrid: two stacks, PRIME offload, headers for both kernels ------------------------
load laptop-amd-hybrid
[[ "$(gpu_stack_families facts)" == 'amd_amdgpu nvidia_open' ]] || fail 'hybrid: expected both families'
manifests="$(gpu_stack_manifests facts)"
has "$manifests" packages/gpu-amd_amdgpu.txt || fail 'hybrid: AMD manifest missing'
has "$manifests" packages/gpu-nvidia_open.txt || fail 'hybrid: NVIDIA manifest missing'
has "$manifests" packages/gpu-prime-offload.txt || fail 'hybrid: PRIME offload manifest missing'
stack="$(gpu_stack_packages facts "$repo_root")"
for package in vulkan-radeon nvidia-open-dkms nvidia-prime linux-headers linux-zen-headers; do
	has "$stack" "$package" || fail "hybrid: $package not in the stack"
done
has "$stack" nvidia-dkms && fail 'hybrid: the proprietary driver leaked into an open-modules stack'
[[ "$(gpu_stack_warnings facts "$repo_root")" == *'prime-run'* ]] || fail 'hybrid: no PRIME guidance'

# --- sole NVIDIA: one family, headers for its one kernel, no PRIME ------------------------
load desktop-nvidia
[[ "$(gpu_stack_families facts)" == nvidia_open ]] || fail 'desktop: expected nvidia_open alone'
stack="$(gpu_stack_packages facts "$repo_root")"
has "$stack" linux-headers || fail 'desktop: linux-headers missing for a DKMS stack'
has "$stack" linux-zen-headers && fail 'desktop: headers for a kernel that is not installed'
has "$stack" nvidia-prime && fail 'desktop: PRIME offload on a non-hybrid machine'
[[ -z "$(gpu_stack_warnings facts "$repo_root")" ]] || fail 'desktop: unexpected warning'

# --- Intel: Mesa stack, no DKMS, so no headers at all ------------------------------------------
load laptop-intel
stack="$(gpu_stack_packages facts "$repo_root")"
has "$stack" vulkan-intel || fail 'intel: vulkan-intel missing'
grep -q -- '-headers$' <<<"$stack" && fail 'intel: headers added without a DKMS module'
grep -qi nvidia <<<"$stack" && fail 'intel: an NVIDIA package in an Intel stack'

# --- Secure Boot: a warning with a DKMS module, silence without one ---------------------------
load desktop-nvidia
# shellcheck disable=SC2034
facts[secure_boot]=enabled
warning="$(gpu_stack_warnings facts "$repo_root")"
[[ "$warning" == *'Secure Boot is enabled'* && "$warning" == *sbctl* ]] || fail "secure boot: no usable warning: $warning"
load laptop-intel
# shellcheck disable=SC2034
facts[secure_boot]=enabled
[[ -z "$(gpu_stack_warnings facts "$repo_root")" ]] || fail 'secure boot: warned about a stack with no DKMS module'

# --- the rendered Hyprland fragment on a hybrid carries guidance, not NVIDIA env ------------
home="$sandbox/home"
mkdir -p -- "$home"
HOME="$home" XDG_CONFIG_HOME="$home/.config" XDG_STATE_HOME="$sandbox/state" \
	FACTS_FILE="$repo_root/tests/golden/laptop-amd-hybrid/hardware-facts" FACTS_OVERRIDE="$sandbox/none" \
	bash "$repo_root/scripts/render-config.sh" --deploy >/dev/null || fail 'hybrid render failed'
fragment="$home/.config/hypr/generated/hardware.lua"
grep -q 'prime-run' "$fragment" || fail 'hybrid fragment: no PRIME guidance'
grep -Eq '^hl\.env\(.*nvidia' "$fragment" && fail 'hybrid fragment: NVIDIA environment set compositor-wide'

printf 'gpu hybrid: two stacks + PRIME, headers per kernel, Secure Boot warned, fragment clean\n'
