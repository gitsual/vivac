#!/usr/bin/env bash
set -Eeuo pipefail

# vivac-os-upstream prints the build number GrapheneOS currently ships on a
# channel for a device, read from the same "<device>-<channel>" file the
# Updater app reads ("BUILD TIMESTAMP DEVICE CHANNEL"). Anything malformed,
# for another device or another channel prints nothing and exits non-zero,
# so the monthly pipeline never builds from a bad answer.

repo_root="${REPO_ROOT:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)}"
tool="$repo_root/os/bin/vivac-os-upstream"

fail() {
	printf '%s\n' "$1" >&2
	exit 1
}
sandbox="$(mktemp -d "${TMPDIR:-/tmp}/vivac-os-upstream.XXXXXX")"
trap 'rm -rf -- "$sandbox"' EXIT

run() { VIVAC_OS_UPSTREAM_URL="file://$sandbox" bash "$tool" "$@"; }

printf '2026111300 1794537720 shiba stable\n' >"$sandbox/shiba-stable"
printf '2026111401 1794600000 shiba beta\n' >"$sandbox/shiba-beta"
[[ "$(run)" == 2026111300 ]] || fail "default (shiba stable) not read"
[[ "$(run --device shiba --channel beta)" == 2026111401 ]] || fail "beta channel not read"

check_bad() {
	printf '%s' "$2" >"$sandbox/shiba-stable"
	if out="$(run 2>/dev/null)"; then fail "accepted $1"; fi
	[[ -z "$out" ]] || fail "printed something for $1"
}
check_bad 'a short build number' '202611130 1794537720 shiba stable'
check_bad 'another device' '2026111300 1794537720 husky stable'
check_bad 'another channel' '2026111300 1794537720 shiba beta'
check_bad 'extra fields' '2026111300 1794537720 shiba stable extra'
check_bad 'a non-numeric timestamp' '2026111300 soon shiba stable'
check_bad 'an empty file' ''
rm -f "$sandbox/shiba-stable"
if run >/dev/null 2>&1; then fail "accepted a missing file"; fi
if run --device '../x' >/dev/null 2>&1; then fail "accepted a device name with a path"; fi
if run --channel nightly >/dev/null 2>&1; then fail "accepted an unknown channel"; fi
