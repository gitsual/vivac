#!/usr/bin/env bash
# Network radio capabilities.
#
# Sourced, not executed. Reads $SYSROOT (ADR-1).

# detect_has_wifi — yes|no
#
# An interface is wireless when the kernel gives it a `wireless` directory or a
# `phy80211` link. Both are checked: the first is the legacy marker, the second
# is what cfg80211 drivers expose, and a fixture may reasonably carry either.
# Matching on an `wl*` interface name would be wrong — names are predictable
# but not guaranteed, and a renamed interface would vanish.
detect_has_wifi() {
	local sysroot="${SYSROOT:-}" interface
	for interface in "$sysroot"/sys/class/net/*/; do
		[[ -d "$interface" ]] || continue
		if [[ -d "$interface/wireless" || -e "$interface/phy80211" ]]; then
			printf 'yes\n'
			return 0
		fi
	done
	printf 'no\n'
}

# detect_has_bluetooth — yes|no
#
# Any hci device under /sys/class/bluetooth. An adapter that exists but is
# blocked by rfkill still counts: the fact answers "is there hardware", and
# whether it is currently usable is a runtime question, not a build-time one.
detect_has_bluetooth() {
	local sysroot="${SYSROOT:-}" device
	for device in "$sysroot"/sys/class/bluetooth/*/; do
		[[ -d "$device" ]] || continue
		printf 'yes\n'
		return 0
	done
	printf 'no\n'
}
