#!/usr/bin/env bash
# shellcheck disable=SC2034  # GPU_* tables are read by the gate and by gpu-setup
# The GPU catalogue: which driver family a PCI id belongs to, and what that
# family installs. data/gpu-catalogue.tsv is the data; this file reads it and
# answers two questions: "which families are in this machine" (one per
# detected device, in device order) and "which single family should a
# non-hybrid machine get". Hybrid machines have two families by definition
# and are resolved by a later unit; here they are reported, not guessed.
#
# Matching is a linear scan in row order: the first row whose vendor matches
# and whose device ranges contain the id wins, so a specific row (intel_xe's
# id ranges) is listed before the vendor's catch-all (intel_i915 *). A device
# no row claims is generic, which installs Mesa and nothing vendor-specific.
#
# Sourced, not executed. Requires nothing else.

GPU_CATALOGUE_FILE="${GPU_CATALOGUE_FILE:-}"
declare -ga GPU_IDS=()
declare -gA GPU_VENDOR=() GPU_RANGES=() GPU_MANIFEST=() GPU_VERIFIED=() GPU_LABEL=()

# gpu_load_catalogue FILE — read every row; a malformed row is an error.
gpu_load_catalogue() {
	local file="$1" line lineno=0 id
	local -a cols
	GPU_IDS=()
	GPU_VENDOR=()
	GPU_RANGES=()
	GPU_MANIFEST=()
	GPU_VERIFIED=()
	GPU_LABEL=()
	[[ -r "$file" ]] || {
		printf 'gpu: catalogue %s is unreadable\n' "$file" >&2
		return 1
	}
	while IFS= read -r line || [[ -n "$line" ]]; do
		lineno=$((lineno + 1))
		[[ -z "$line" || "$line" == '#'* ]] && continue
		mapfile -t -d $'\t' cols < <(printf '%s' "$line")
		((${#cols[@]} == 6)) || {
			printf 'gpu: %s line %d has %d columns, expected 6\n' "$file" "$lineno" "${#cols[@]}" >&2
			return 1
		}
		id="${cols[0]}"
		[[ "$id" =~ ^[a-z][a-z0-9_]*$ ]] || {
			printf 'gpu: %s line %d: bad family id %q\n' "$file" "$lineno" "$id" >&2
			return 1
		}
		[[ ! -v GPU_VENDOR["$id"] ]] || {
			printf 'gpu: %s line %d: family %s listed twice\n' "$file" "$lineno" "$id" >&2
			return 1
		}
		[[ "${cols[1]}" == '*' || "${cols[1]}" =~ ^[0-9a-f]{4}$ ]] || {
			printf 'gpu: %s line %d: bad vendor id %q\n' "$file" "$lineno" "${cols[1]}" >&2
			return 1
		}
		gpu_ranges_valid "${cols[2]}" || {
			printf 'gpu: %s line %d: bad device ranges %q\n' "$file" "$lineno" "${cols[2]}" >&2
			return 1
		}
		[[ "${cols[4]}" =~ ^(workstation|vm|-)$ ]] || {
			printf 'gpu: %s line %d: verified_on must be workstation, vm or -, got %q\n' "$file" "$lineno" "${cols[4]}" >&2
			return 1
		}
		GPU_IDS+=("$id")
		GPU_VENDOR["$id"]="${cols[1]}"
		GPU_RANGES["$id"]="${cols[2]}"
		GPU_MANIFEST["$id"]="${cols[3]}"
		GPU_VERIFIED["$id"]="${cols[4]}"
		GPU_LABEL["$id"]="${cols[5]}"
	done <"$file"
	((${#GPU_IDS[@]})) || {
		printf 'gpu: catalogue %s has no rows\n' "$file" >&2
		return 1
	}
}

# gpu_ranges_valid RANGES — `*` or comma-separated hex min-max pairs, min <= max.
gpu_ranges_valid() {
	local ranges="$1" range
	local -a pairs
	[[ "$ranges" == '*' ]] && return 0
	IFS=',' read -ra pairs <<<"$ranges"
	for range in "${pairs[@]}"; do
		[[ "$range" =~ ^([0-9a-f]{4})-([0-9a-f]{4})$ ]] || return 1
		((16#${BASH_REMATCH[1]} <= 16#${BASH_REMATCH[2]})) || return 1
	done
}

# gpu_ranges_contain RANGES DEVICE — 0 when the hex device id falls in RANGES.
gpu_ranges_contain() {
	local ranges="$1" device="$2" range
	local -a pairs
	[[ "$ranges" == '*' ]] && return 0
	IFS=',' read -ra pairs <<<"$ranges"
	for range in "${pairs[@]}"; do
		[[ "$range" =~ ^([0-9a-f]{4})-([0-9a-f]{4})$ ]] || continue
		if ((16#${BASH_REMATCH[1]} <= 16#$device && 16#$device <= 16#${BASH_REMATCH[2]})); then
			return 0
		fi
	done
	return 1
}

# gpu_family_for_device VENDOR:DEVICE — print the first matching family.
gpu_family_for_device() {
	local entry="$1" vendor device id
	[[ "$entry" =~ ^([0-9a-f]{4}):([0-9a-f]{4})$ ]] || {
		printf 'generic'
		return 0
	}
	vendor="${BASH_REMATCH[1]}"
	device="${BASH_REMATCH[2]}"
	for id in "${GPU_IDS[@]}"; do
		[[ "${GPU_VENDOR["$id"]}" == '*' || "${GPU_VENDOR["$id"]}" == "$vendor" ]] || continue
		gpu_ranges_contain "${GPU_RANGES["$id"]}" "$device" || continue
		printf '%s' "$id"
		return 0
	done
	printf 'generic'
}

# gpu_families DEVICES — one family per device in DEVICES (space list of
# vendor:device), duplicates removed, order kept. Empty input is generic.
gpu_families() {
	local devices="$1" entry family out=''
	for entry in $devices; do
		family="$(gpu_family_for_device "$entry")"
		[[ " $out " == *" $family "* ]] || out+="${out:+ }$family"
	done
	printf '%s' "${out:-generic}"
}

# gpu_single_family FACTS_ARRAY_NAME — print the one family a non-hybrid
# machine gets. Returns 2, printing nothing, when the machine carries more
# than one family: that is the hybrid case and belongs to its own unit.
gpu_single_family() {
	local -n __gpu_facts="$1"
	local families
	families="$(gpu_families "${__gpu_facts[gpu_devices]:-}")"
	if [[ "$families" == *' '* || "${__gpu_facts[gpu_hybrid]:-no}" == yes ]]; then
		return 2
	fi
	printf '%s' "$families"
}

# gpu_status FAMILY — observed or recommendation, from verified_on.
gpu_status() {
	[[ -v GPU_VERIFIED["$1"] ]] || return 1
	if [[ "${GPU_VERIFIED["$1"]}" == '-' ]]; then
		printf 'recommendation'
	else
		printf 'observed'
	fi
}

# gpu_stack_families FACTS_ARRAY_NAME — every family the machine carries, in
# device order. A hybrid machine gets both: the integrated GPU drives the
# displays and the NVIDIA one is used per application through PRIME offload.
gpu_stack_families() {
	local -n __gpu_facts="$1"
	gpu_families "${__gpu_facts[gpu_devices]:-}"
}

# gpu_stack_manifests FACTS_ARRAY_NAME — the manifests to install, one per
# family, plus the PRIME offload manifest on a hybrid with NVIDIA.
gpu_stack_manifests() {
	local -n __gpu_facts="$1"
	local family
	for family in $(gpu_families "${__gpu_facts[gpu_devices]:-}"); do
		printf '%s\n' "${GPU_MANIFEST["$family"]}"
	done
	if [[ "${__gpu_facts[gpu_hybrid]:-no}" == yes ]] && gpu_stack_has_nvidia "$1"; then
		printf '%s\n' "$GPU_PRIME_MANIFEST"
	fi
}
GPU_PRIME_MANIFEST='packages/gpu-prime-offload.txt'

# gpu_stack_has_nvidia FACTS_ARRAY_NAME — 0 when any family is an NVIDIA one.
gpu_stack_has_nvidia() {
	local -n __gpu_facts="$1"
	[[ " $(gpu_families "${__gpu_facts[gpu_devices]:-}") " == *' nvidia_'* ]]
}

# gpu_stack_packages FACTS_ARRAY_NAME REPO_ROOT — the packages to install:
# every manifest's entries, and, when any of them is a DKMS module, the
# headers of every installed kernel, since DKMS builds against each one.
gpu_stack_packages() {
	local facts_name="$1" root="$2" manifest package kernel dkms=no
	local -a packages=()
	while IFS= read -r manifest; do
		while IFS= read -r package; do
			[[ -n "$package" && "$package" != '#'* ]] || continue
			packages+=("$package")
			[[ "$package" == *-dkms ]] && dkms=yes
		done <"$root/$manifest"
	done < <(gpu_stack_manifests "$facts_name")
	if [[ "$dkms" == yes ]]; then
		local -n __gpu_facts_k="$facts_name"
		for kernel in ${__gpu_facts_k[kernels]:-}; do
			packages+=("$kernel-headers")
		done
	fi
	printf '%s\n' "${packages[@]}" | LC_ALL=C sort -u
}

# gpu_stack_warnings FACTS_ARRAY_NAME REPO_ROOT — conditions the owner must
# know about before installing. Printed, never acted on: Secure Boot with an
# unsigned DKMS module is a boot with no driver, and hiding that behind a
# silent install or a silent refusal are both worse than saying it.
gpu_stack_warnings() {
	local facts_name="$1" root="$2"
	local -n __gpu_facts_w="$facts_name"
	if [[ "${__gpu_facts_w[secure_boot]:-unknown}" == enabled ]] &&
		gpu_stack_packages "$facts_name" "$root" | grep -q -- '-dkms$'; then
		printf 'Secure Boot is enabled and this stack builds out-of-tree modules with DKMS; unsigned modules will not load. Enrol a signing key (sbctl) or disable Secure Boot before rebooting.\n'
	fi
	if [[ "${__gpu_facts_w[gpu_hybrid]:-no}" == yes ]] && gpu_stack_has_nvidia "$facts_name"; then
		printf 'Hybrid graphics: the integrated GPU drives the displays; run a program on the NVIDIA GPU with prime-run.\n'
	fi
	return 0
}
