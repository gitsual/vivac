#!/usr/bin/env bash
# Installed kernels — installed, not running. A driver stack has to be built
# for every kernel the user can boot, not just the one booted today.
#
# Fixture first ($SYSROOT/pacman-Qq.txt), live command second (${PACMAN_CMD}
# with LC_ALL=C at the call site). See ADR-1.
#
# Sourced, not executed.

# Package names that ARE a kernel. `linux-api-headers` and `linux-firmware`
# start the same way and are not.
KERNEL_PACKAGE_PATTERN='^linux(-lts|-zen|-hardened|-rt|-rt-lts)?$'

# Kernels for which Arch ships prebuilt out-of-tree driver packages. Anything
# else needs DKMS to build the module against its headers.
KERNELS_WITH_PREBUILT_DRIVERS=(linux linux-lts)

installed_packages() {
	local sysroot="${SYSROOT:-}"
	local source_file="$sysroot/pacman-Qq.txt"
	if [[ -n "$sysroot" ]]; then
		[[ -r "$source_file" ]] && cat -- "$source_file"
		return 0
	fi
	LC_ALL=C "${PACMAN_CMD:-pacman}" -Qq 2>/dev/null || true
}

# detect_kernels — space-separated installed kernel package names, sorted.
detect_kernels() {
	installed_packages | grep -E "$KERNEL_PACKAGE_PATTERN" | LC_ALL=C sort -u | tr '\n' ' ' | sed 's/ $//'
	printf '\n'
}

# detect_needs_dkms — yes|no: at least one installed kernel has no prebuilt
# driver packages. With no kernel detected at all the answer is no: there is
# nothing to build for, and "unknown" would push every consumer into the
# expensive path by default.
detect_needs_dkms() {
	local kernel prebuilt found
	for kernel in $(detect_kernels); do
		found=no
		for prebuilt in "${KERNELS_WITH_PREBUILT_DRIVERS[@]}"; do
			[[ "$kernel" == "$prebuilt" ]] && found=yes
		done
		[[ "$found" == yes ]] || {
			printf 'yes\n'
			return 0
		}
	done
	printf 'no\n'
}
