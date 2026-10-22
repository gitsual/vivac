#!/usr/bin/env bash
# GPU detection: which vendors are present, which exact devices, and whether
# the machine is a hybrid (more than one vendor driving displays).
#
# Only the PCI class and vendor:device identifiers are recorded. Those name a
# product line, not a unit; the bus address (which ADR-4 forbids) is dropped.
#
# Fixture first, command second: a tree at $SYSROOT may carry an `lspci.txt`
# with the exact output of `lspci -mm -n`, and when it does the real command
# is never run. On a live machine ($SYSROOT empty) the command is consulted
# through ${LSPCI_CMD} with LC_ALL=C pinned at the call site (ADR-1).
#
# Sourced, not executed.

# graphics_pci_lines — machine-readable lspci lines for display-class devices.
# Classes: 0300 VGA, 0302 3D controller, 0380 other display controller.
graphics_pci_lines() {
	local sysroot="${SYSROOT:-}"
	local source_file="$sysroot/lspci.txt"
	if [[ -n "$sysroot" ]]; then
		[[ -r "$source_file" ]] && grep -E '^[^ ]+ "03(00|02|80)"' "$source_file"
		return 0
	fi
	LC_ALL=C "${LSPCI_CMD:-lspci}" -mm -n 2>/dev/null | grep -E '^[^ ]+ "03(00|02|80)"' || true
}

# graphics_vendor_name VENDOR_ID — the short name every consumer branches on.
graphics_vendor_name() {
	case "${1,,}" in
	8086) printf 'intel' ;;
	1002) printf 'amd' ;;
	10de) printf 'nvidia' ;;
	1af4) printf 'virtio' ;;
	1234 | 1b36) printf 'qemu' ;; # bochs std VGA, QXL
	15ad) printf 'vmware' ;;
	*) printf 'generic' ;;
	esac
}

# detect_gpu_devices — space-separated "vendor:device" list, sorted, or empty.
detect_gpu_devices() {
	local line vendor device
	while IFS= read -r line; do
		[[ -n "$line" ]] || continue
		# Field layout of `lspci -mm -n`: slot "class" "vendor" "device" ...
		vendor="$(printf '%s' "$line" | cut -d'"' -f4)"
		device="$(printf '%s' "$line" | cut -d'"' -f6)"
		[[ "$vendor" =~ ^[0-9a-fA-F]{4}$ && "$device" =~ ^[0-9a-fA-F]{4}$ ]] || continue
		printf '%s:%s\n' "${vendor,,}" "${device,,}"
	done < <(graphics_pci_lines) | LC_ALL=C sort -u | tr '\n' ' ' | sed 's/ $//'
	printf '\n'
}

# detect_gpu_vendors — space-separated vendor names, sorted, unique, or empty.
detect_gpu_vendors() {
	local entry
	for entry in $(detect_gpu_devices); do
		graphics_vendor_name "${entry%%:*}"
		printf '\n'
	done | LC_ALL=C sort -u | tr '\n' ' ' | sed 's/ $//'
	printf '\n'
}

# detect_gpu_hybrid — yes|no. Two real vendors means switchable graphics
# (PRIME); two devices from the same vendor is just two cards.
detect_gpu_hybrid() {
	local vendors count=0 vendor
	vendors="$(detect_gpu_vendors)"
	for vendor in $vendors; do
		case "$vendor" in intel | amd | nvidia) count=$((count + 1)) ;; esac
	done
	((count > 1)) && printf 'yes\n' || printf 'no\n'
}
