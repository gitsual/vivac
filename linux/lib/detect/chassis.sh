#!/usr/bin/env bash
# Chassis and virtualisation detection.
#
# Every read is rooted at $SYSROOT (empty on a real machine, a fixture tree in
# tests) so the whole GPU and form-factor matrix is testable on one laptop.
# See ADR-1.
#
# Sourced, not executed.

# DMI chassis types that mean "carried around" and "sits on a desk". Anything
# else — including the 1/2 (Other/Unknown) that virtual machines usually report
# — stays unknown rather than being guessed into a category.
DETECT_CHASSIS_PORTABLE=(8 9 10 11 14 30 31 32)
DETECT_CHASSIS_STATIONARY=(3 4 5 6 7 13 15 17 23 24 28 29)

# detect_virt — none|kvm|qemu|other
#
# DMI is read first and wins, because it is the only source a fixture tree can
# provide. The external detector is consulted only on a real machine, where
# $SYSROOT is empty.
detect_virt() {
	local sysroot="${SYSROOT:-}" vendor='' product='' reported

	[[ -r "$sysroot/sys/class/dmi/id/sys_vendor" ]] &&
		vendor="$(<"$sysroot/sys/class/dmi/id/sys_vendor")"
	[[ -r "$sysroot/sys/class/dmi/id/product_name" ]] &&
		product="$(<"$sysroot/sys/class/dmi/id/product_name")"

	case "${vendor,,} ${product,,}" in
	*qemu*) printf 'qemu\n' && return 0 ;;
	*kvm*) printf 'kvm\n' && return 0 ;;
	*vmware* | *virtualbox* | *innotek* | *xen* | *microsoft*virtual* | *bochs* | *parallels*)
		printf 'other\n' && return 0
		;;
	esac

	if [[ -n "$sysroot" ]]; then
		# A fixture tree that shows no virtualisation marker means bare metal.
		printf 'none\n'
		return 0
	fi

	# systemd-detect-virt exits non-zero precisely when there is no
	# virtualisation, so its status is not an error to propagate.
	reported="$(${VIRT_CMD:-systemd-detect-virt} 2>/dev/null)" || reported='none'
	case "$reported" in
	'' | none) printf 'none\n' ;;
	kvm) printf 'kvm\n' ;;
	qemu) printf 'qemu\n' ;;
	*) printf 'other\n' ;;
	esac
}

# detect_chassis — laptop|desktop|vm|unknown
#
# Virtualisation outranks the DMI form factor: a guest reporting "Desktop" is
# still a VM as far as every consumer of this fact is concerned.
detect_chassis() {
	local sysroot="${SYSROOT:-}" raw type

	[[ "$(detect_virt)" == 'none' ]] || {
		printf 'vm\n'
		return 0
	}

	local chassis_file="$sysroot/sys/class/dmi/id/chassis_type"
	[[ -r "$chassis_file" ]] || {
		printf 'unknown\n'
		return 0
	}

	raw="$(<"$chassis_file")"
	raw="${raw//[[:space:]]/}"
	[[ "$raw" =~ ^[0-9]+$ ]] || {
		printf 'unknown\n'
		return 0
	}

	for type in "${DETECT_CHASSIS_PORTABLE[@]}"; do
		[[ "$raw" == "$type" ]] && {
			printf 'laptop\n'
			return 0
		}
	done
	for type in "${DETECT_CHASSIS_STATIONARY[@]}"; do
		[[ "$raw" == "$type" ]] && {
			printf 'desktop\n'
			return 0
		}
	done

	printf 'unknown\n'
}
