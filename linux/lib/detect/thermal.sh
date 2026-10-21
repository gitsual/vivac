#!/usr/bin/env bash
# Where this machine reports its CPU temperature.
#
# Sourced, not executed. Reads $SYSROOT (ADR-1).

# detect_cpu_temp_path — an absolute /sys path to a temperature input, or
# "none".
#
# Waybar's temperature module needs a concrete file, and the hwmon index that
# names it is assigned in probe order: the k10temp that is hwmon2 on one
# machine is hwmon4 on the next, and a config that hardcodes one shows either
# nothing or the wrong chip. So the driver name decides, not the index.
#
# The preference order is the chip that actually reports the CPU package:
# k10temp and zenpower on AMD, coretemp on Intel. A generic acpitz is the last
# resort because it often reads a board sensor several degrees off the die, and
# no sensor at all is the honest answer in a VM.
#
# The path is emitted without the sysroot prefix: a fact describes the machine
# the file was collected from, not the directory a fixture happens to live in.
detect_cpu_temp_path() {
	local sysroot="${SYSROOT:-}" preferred=(k10temp zenpower coretemp acpitz) \
		driver chip name input
	for driver in "${preferred[@]}"; do
		for chip in "$sysroot"/sys/class/hwmon/*/; do
			[[ -r "$chip/name" ]] || continue
			name="$(<"$chip/name")"
			[[ "$name" == "$driver" ]] || continue
			for input in "$chip"temp*_input; do
				[[ -r "$input" ]] || continue
				printf '%s\n' "${input#"$sysroot"}"
				return 0
			done
		done
	done
	printf 'none\n'
}
