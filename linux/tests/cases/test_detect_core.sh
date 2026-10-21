#!/usr/bin/env bash
set -Eeuo pipefail

# Detectors must describe the tree at $SYSROOT and nothing else. That isolation
# is what lets one machine test every form factor, so it is asserted first and
# explicitly: with a fixture root in place, a real capability of THIS host must
# not leak into the answer.

repo_root="${REPO_ROOT:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)}"
for detector in chassis power input net thermal; do
	# shellcheck source=/dev/null
	source "$repo_root/lib/detect/$detector.sh"
done

sandbox="$(mktemp -d "${TMPDIR:-/tmp}/vivac-detect.XXXXXX")"
trap 'rm -rf -- "$sandbox"' EXIT

fail() {
	printf '%s\n' "$1" >&2
	exit 1
}

# archetype NAME — create an empty sysfs skeleton and print its root.
archetype() {
	local root="$sandbox/$1/sysroot"
	mkdir -p -- "$root/sys/class/dmi/id" \
		"$root/sys/class/power_supply" \
		"$root/sys/class/backlight" \
		"$root/sys/class/input" \
		"$root/sys/class/net" \
		"$root/sys/class/bluetooth"
	printf '%s' "$root"
}

expect() {
	local label="$1" expected="$2" actual="$3"
	[[ "$expected" == "$actual" ]] || fail "$label: expected '$expected', got '$actual'"
}

# --- isolation --------------------------------------------------------------
# This host has wifi (asserted below on the real root), so an empty fixture
# reporting "yes" would mean a detector reached past $SYSROOT.
empty="$(archetype empty)"
SYSROOT="$empty" expect 'isolation/wifi' 'no' "$(SYSROOT="$empty" detect_has_wifi)"
expect 'isolation/chassis' 'unknown' "$(SYSROOT="$empty" detect_chassis)"
expect 'isolation/battery' 'no' "$(SYSROOT="$empty" detect_has_battery)"

# --- a fully equipped laptop ------------------------------------------------
laptop="$(archetype laptop)"
printf '10\n' >"$laptop/sys/class/dmi/id/chassis_type"
printf 'LENOVO\n' >"$laptop/sys/class/dmi/id/sys_vendor"
mkdir -p -- "$laptop/sys/class/power_supply/BAT0" "$laptop/sys/class/power_supply/AC"
printf 'Battery\n' >"$laptop/sys/class/power_supply/BAT0/type"
printf 'Mains\n' >"$laptop/sys/class/power_supply/AC/type"
mkdir -p -- "$laptop/sys/class/backlight/intel_backlight"
mkdir -p -- "$laptop/sys/class/input/input5" "$laptop/sys/class/input/input0"
printf 'AT Translated Set 2 keyboard\n' >"$laptop/sys/class/input/input0/name"
printf 'SynPS/2 Synaptics TouchPad\n' >"$laptop/sys/class/input/input5/name"
mkdir -p -- "$laptop/sys/class/net/wlan0/wireless" "$laptop/sys/class/net/lo"
mkdir -p -- "$laptop/sys/class/bluetooth/hci0"

expect 'laptop/chassis' 'laptop' "$(SYSROOT="$laptop" detect_chassis)"
expect 'laptop/virt' 'none' "$(SYSROOT="$laptop" detect_virt)"
expect 'laptop/battery' 'yes' "$(SYSROOT="$laptop" detect_has_battery)"
expect 'laptop/backlight' 'yes' "$(SYSROOT="$laptop" detect_has_backlight)"
expect 'laptop/touchpad' 'yes' "$(SYSROOT="$laptop" detect_has_touchpad)"
expect 'laptop/wifi' 'yes' "$(SYSROOT="$laptop" detect_has_wifi)"
expect 'laptop/bluetooth' 'yes' "$(SYSROOT="$laptop" detect_has_bluetooth)"

# --- a desktop: mains power is not a battery --------------------------------
desktop="$(archetype desktop)"
printf '3\n' >"$desktop/sys/class/dmi/id/chassis_type"
mkdir -p -- "$desktop/sys/class/power_supply/AC"
printf 'Mains\n' >"$desktop/sys/class/power_supply/AC/type"
mkdir -p -- "$desktop/sys/class/input/input0"
printf 'USB Optical Mouse\n' >"$desktop/sys/class/input/input0/name"
mkdir -p -- "$desktop/sys/class/net/eth0"

expect 'desktop/chassis' 'desktop' "$(SYSROOT="$desktop" detect_chassis)"
expect 'desktop/battery' 'no' "$(SYSROOT="$desktop" detect_has_battery)"
expect 'desktop/backlight' 'no' "$(SYSROOT="$desktop" detect_has_backlight)"
expect 'desktop/touchpad' 'no' "$(SYSROOT="$desktop" detect_has_touchpad)"
expect 'desktop/wifi' 'no' "$(SYSROOT="$desktop" detect_has_wifi)"

# --- a QEMU guest: virtualisation outranks the reported form factor ---------
guest="$(archetype guest)"
printf '1\n' >"$guest/sys/class/dmi/id/chassis_type"
printf 'QEMU\n' >"$guest/sys/class/dmi/id/sys_vendor"
printf 'Standard PC (Q35 + ICH9, 2009)\n' >"$guest/sys/class/dmi/id/product_name"

expect 'guest/virt' 'qemu' "$(SYSROOT="$guest" detect_virt)"
expect 'guest/chassis' 'vm' "$(SYSROOT="$guest" detect_chassis)"

# A guest whose DMI claims Desktop is still a VM.
printf '3\n' >"$guest/sys/class/dmi/id/chassis_type"
expect 'guest/chassis-claiming-desktop' 'vm' "$(SYSROOT="$guest" detect_chassis)"

# --- malformed and edge input degrades to unknown, never to a guess ---------
odd="$(archetype odd)"
printf '  10  \n' >"$odd/sys/class/dmi/id/chassis_type"
expect 'odd/whitespace-is-tolerated' 'laptop' "$(SYSROOT="$odd" detect_chassis)"

printf 'Laptop\n' >"$odd/sys/class/dmi/id/chassis_type"
expect 'odd/non-numeric-is-unknown' 'unknown' "$(SYSROOT="$odd" detect_chassis)"

printf '99\n' >"$odd/sys/class/dmi/id/chassis_type"
expect 'odd/unmapped-type-is-unknown' 'unknown' "$(SYSROOT="$odd" detect_chassis)"

# A power supply directory with no type file must not count as a battery.
mkdir -p -- "$odd/sys/class/power_supply/mystery"
expect 'odd/typeless-supply' 'no' "$(SYSROOT="$odd" detect_has_battery)"

# cfg80211 exposes phy80211 rather than the legacy wireless directory.
mkdir -p -- "$odd/sys/class/net/wlp5s0"
touch -- "$odd/sys/class/net/wlp5s0/phy80211"
expect 'odd/phy80211-counts-as-wifi' 'yes' "$(SYSROOT="$odd" detect_has_wifi)"

# Device names vary in case between drivers.
mkdir -p -- "$odd/sys/class/input/input9"
printf 'ELAN0000:00 04F3:3140 Touchpad\n' >"$odd/sys/class/input/input9/name"
expect 'odd/mixed-case-touchpad' 'yes' "$(SYSROOT="$odd" detect_has_touchpad)"

# --- the real machine still answers -----------------------------------------
# With no SYSROOT the detectors read the live host. The values are not asserted
# (they differ per machine) but they must be well-formed, which is what catches
# a detector that only ever worked against fixtures.
for probe in detect_chassis detect_virt detect_has_battery detect_has_backlight \
	detect_has_touchpad detect_has_wifi detect_has_bluetooth; do
	value="$(SYSROOT='' "$probe")"
	case "$probe" in
	detect_chassis) [[ "$value" =~ ^(laptop|desktop|vm|unknown)$ ]] ;;
	detect_virt) [[ "$value" =~ ^(none|kvm|qemu|other)$ ]] ;;
	*) [[ "$value" =~ ^(yes|no)$ ]] ;;
	esac || fail "live host: $probe returned an out-of-domain value: '$value'"
done

printf 'detect: 4 archetypes, isolation from the live host proven, malformed input degraded\n'
