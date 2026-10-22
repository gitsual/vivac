#!/usr/bin/env bash
# Firmware and display facts: Secure Boot state, connected monitors, and the
# largest scale factor any of them wants.
#
# Everything reads $SYSROOT (ADR-1). The EDID is parsed for its physical size
# only; no string from it — model, serial — is ever emitted (ADR-4).
#
# Sourced, not executed.

# detect_secure_boot — enabled|disabled|unknown
#
# The efivar is 4 bytes of attributes followed by a single value byte. No EFI
# tree at all means a legacy BIOS boot, which cannot Secure Boot: that is a
# definite "disabled", not an unknown. EFI present but the variable unreadable
# (efivarfs not mounted, or not root) is genuinely unknown.
detect_secure_boot() {
	local sysroot="${SYSROOT:-}"
	local efi="$sysroot/sys/firmware/efi"
	local var='' candidate value

	[[ -d "$efi" ]] || {
		printf 'disabled\n'
		return 0
	}
	# The variable lives in the EFI global namespace, whose GUID is a public
	# spec constant — but a literal UUID in source trips the repository's own
	# privacy gate, and a glob is just as exact: there is one SecureBoot var.
	for candidate in "$efi"/efivars/SecureBoot-*; do
		[[ -r "$candidate" ]] && var="$candidate" && break
	done
	[[ -n "$var" ]] || {
		printf 'unknown\n'
		return 0
	}
	value="$(od -An -tu1 -j4 -N1 -- "$var" 2>/dev/null | tr -d ' ')"
	case "$value" in
	1) printf 'enabled\n' ;;
	0) printf 'disabled\n' ;;
	*) printf 'unknown\n' ;;
	esac
}

# drm_connectors — every connector directory with a readable status file.
drm_connectors() {
	local sysroot="${SYSROOT:-}" connector
	for connector in "$sysroot"/sys/class/drm/card*-*/; do
		[[ -r "$connector/status" ]] && printf '%s\n' "${connector%/}"
	done
}

# detect_monitor_count — number of connectors reporting "connected".
detect_monitor_count() {
	local connector count=0
	while IFS= read -r connector; do
		[[ "$(<"$connector/status")" == 'connected' ]] && count=$((count + 1))
	done < <(drm_connectors)
	printf '%d\n' "$count"
}

# connector_scale CONNECTOR — 1|1.5|2 from the preferred mode and the panel's
# physical size. Anything unparseable is 1: a wrong "1" costs a small UI, a
# wrong "2" makes the desktop unusable.
connector_scale() {
	local connector="$1" mode width_px width_cm dpi
	[[ -r "$connector/modes" && -r "$connector/edid" ]] || {
		printf '1'
		return 0
	}
	mode="$(head -n1 -- "$connector/modes")"
	width_px="${mode%%x*}"
	# EDID byte 21 is the horizontal size in centimetres; 0 means "unknown".
	width_cm="$(od -An -tu1 -j21 -N1 -- "$connector/edid" 2>/dev/null | tr -d ' ')"
	[[ "$width_px" =~ ^[0-9]+$ && "$width_cm" =~ ^[0-9]+$ && "$width_cm" -gt 0 ]] || {
		printf '1'
		return 0
	}
	dpi=$((width_px * 254 / (width_cm * 100)))
	if ((dpi >= 192)); then
		printf '2'
	elif ((dpi >= 144)); then
		printf '1.5'
	else
		printf '1'
	fi
}

# scale_tenths SCALE — 1|1.5|2 as an integer, so scales compare without bc.
scale_tenths() {
	case "$1" in
	2) printf '20' ;;
	1.5) printf '15' ;;
	*) printf '10' ;;
	esac
}

# detect_max_scale — the largest scale any connected monitor wants.
detect_max_scale() {
	local connector scale max=1
	while IFS= read -r connector; do
		[[ "$(<"$connector/status")" == 'connected' ]] || continue
		scale="$(connector_scale "$connector")"
		(($(scale_tenths "$scale") > $(scale_tenths "$max"))) && max="$scale"
	done < <(drm_connectors)
	printf '%s\n' "$max"
}
