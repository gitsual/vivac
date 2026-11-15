#!/usr/bin/env bash
# The fakes are shell source written out literally: their $ expands when they run.
# shellcheck disable=SC2016
set -Eeuo pipefail

# vivac-facts: what the phone is, as JSON, built from an allowlist. Against a
# fake getprop, termux-battery-status and /proc: every known field is there
# with the right type; identifiers (serial, IMEI-like props, MAC, phone
# number) never appear even when getprop has them; a missing Termux:API
# leaves battery null instead of failing.

repo_root="${REPO_ROOT:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)}"
tool="$repo_root/bin/vivac-facts"

fail() {
	printf '%s\n' "$1" >&2
	exit 1
}
sandbox="$(mktemp -d "${TMPDIR:-/tmp}/vivac-facts.XXXXXX")"
trap 'rm -rf -- "$sandbox"' EXIT
mkdir -p "$sandbox/bin" "$sandbox/proc"

cat >"$sandbox/bin/getprop" <<'FAKE'
#!/usr/bin/env bash
case "$1" in
ro.product.manufacturer) echo Google ;;
ro.product.model) echo 'Pixel 8' ;;
ro.product.device) echo shiba ;;
ro.build.version.release) echo 17 ;;
ro.build.version.sdk) echo 37 ;;
ro.build.id) echo CP2A.260805.005 ;;
ro.build.version.incremental) echo 2026110500 ;;
ro.build.version.security_patch) echo 2026-11-05 ;;
ro.soc.manufacturer) echo Google ;;
ro.soc.model) echo 'Tensor G3' ;;
ro.serialno | ro.boot.serialno) echo SERIAL39071FDJ ;;
gsm.imei) echo 356789012345678 ;;
*) echo '' ;;
esac
FAKE
cat >"$sandbox/bin/termux-battery-status" <<'FAKE'
#!/usr/bin/env bash
echo '{"health":"GOOD","percentage":81,"plugged":"PLUGGED_AC","status":"CHARGING","temperature":29.5,"current":1200}'
FAKE
chmod +x "$sandbox/bin/"*
printf 'MemTotal:        7864320 kB\nMemFree:          100000 kB\nMemAvailable:    3932160 kB\n' >"$sandbox/proc/meminfo"
printf '12345.67 99999.00\n' >"$sandbox/proc/uptime"

out="$(PATH="$sandbox/bin:$PATH" VIVAC_PROC="$sandbox/proc" VIVAC_STORAGE="$sandbox" python3 "$tool")" ||
	fail "vivac-facts failed"

check() { python3 -c "import json,sys; d=json.loads(sys.argv[1]); assert $2, d" "$out" ||
	fail "facts: $1"; }
check 'manufacturer' 'd["manufacturer"] == "Google"'
check 'model' 'd["model"] == "Pixel 8"'
check 'codename' 'd["codename"] == "shiba"'
check 'android' 'd["android"] == {"version": "17", "sdk": 37}'
check 'build' 'd["build"] == {"id": "CP2A.260805.005", "incremental": "2026110500", "security_patch": "2026-11-05"}'
check 'soc' 'd["soc"]["model"] == "Tensor G3" and d["soc"]["cores"] >= 1'
check 'memory' 'd["memory"] == {"total_mb": 7680, "available_mb": 3840}'
check 'storage' 'd["storage"]["total_gb"] > 0 and "free_gb" in d["storage"]'
check 'battery' 'd["battery"] == {"percent": 81, "status": "CHARGING", "plugged": "PLUGGED_AC", "health": "GOOD", "temperature_c": 29.5}'
check 'uptime' 'd["uptime_s"] == 12345'

for secret in SERIAL39071FDJ 356789012345678; do
	[[ "$out" != *"$secret"* ]] || fail "facts leak an identifier: $secret"
done

# Without Termux:API the battery is null and the rest still answers.
rm "$sandbox/bin/termux-battery-status"
out="$(PATH="$sandbox/bin:/usr/bin:/bin" VIVAC_PROC="$sandbox/proc" VIVAC_STORAGE="$sandbox" python3 "$tool")" ||
	fail "vivac-facts failed without Termux:API"
check 'battery null without termux-api' 'd["battery"] is None and d["model"] == "Pixel 8"'
