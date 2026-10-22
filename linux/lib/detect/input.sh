#!/usr/bin/env bash
# Input device capabilities.
#
# Sourced, not executed. Reads $SYSROOT (ADR-1).

# detect_has_touchpad — yes|no
#
# Matched on the device name rather than a capability bitmask: the bitmask
# distinguishes a touchpad from a mouse only indirectly, while every driver in
# practice puts "Touchpad", "TouchPad" or "Synaptics" in the name. A name file
# that cannot be read is skipped rather than failing the whole detection.
detect_has_touchpad() {
	local sysroot="${SYSROOT:-}" name_file name
	for name_file in "$sysroot"/sys/class/input/*/name; do
		[[ -r "$name_file" ]] || continue
		name="$(<"$name_file")"
		case "${name,,}" in
		*touchpad* | *trackpad* | *synaptics*)
			printf 'yes\n'
			return 0
			;;
		esac
	done
	printf 'no\n'
}
