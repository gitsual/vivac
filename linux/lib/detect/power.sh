#!/usr/bin/env bash
# Power-related capabilities: is there a battery, is there a backlight.
#
# These two drive whether the status bar shows battery and brightness modules
# at all, so a wrong answer is visible on screen. Both read $SYSROOT (ADR-1).
#
# Sourced, not executed.

# detect_has_battery — yes|no
#
# A power supply whose type is "Battery". Mains adapters also live under
# power_supply and report "Mains", so the type file is what decides, not the
# presence of the directory.
detect_has_battery() {
	local sysroot="${SYSROOT:-}" supply type_file
	for supply in "$sysroot"/sys/class/power_supply/*/; do
		[[ -d "$supply" ]] || continue
		type_file="$supply/type"
		[[ -r "$type_file" ]] || continue
		if [[ "$(<"$type_file")" == 'Battery' ]]; then
			printf 'yes\n'
			return 0
		fi
	done
	printf 'no\n'
}

# detect_has_backlight — yes|no
#
# Any entry under /sys/class/backlight means something can be dimmed. Desktops
# with an external monitor have none, which is the common false-positive risk
# this avoids by not inferring backlight from chassis type.
detect_has_backlight() {
	local sysroot="${SYSROOT:-}" device
	for device in "$sysroot"/sys/class/backlight/*/; do
		[[ -d "$device" ]] || continue
		printf 'yes\n'
		return 0
	done
	printf 'no\n'
}
