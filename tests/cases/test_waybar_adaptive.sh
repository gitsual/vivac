#!/usr/bin/env bash
set -Eeuo pipefail

# The Waybar config is rendered per machine: a laptop shows battery and
# backlight, a VM shows neither, and only NVIDIA machines poll nvidia-smi.
# Every render must be valid JSON in which each listed module is defined.

repo_root="${REPO_ROOT:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)}"
renderer="$repo_root/scripts/render-config.sh"

sandbox="$(mktemp -d "${TMPDIR:-/tmp}/vivac-waybar.XXXXXX")"
trap 'rm -rf -- "$sandbox"' EXIT

fail() {
	printf '%s\n' "$1" >&2
	exit 1
}

render() {
	local archetype="$1" home="$sandbox/$1"
	mkdir -p -- "$home"
	HOME="$home" XDG_CONFIG_HOME="$home/.config" XDG_STATE_HOME="$home/.state" \
		FACTS_FILE="$repo_root/tests/golden/$archetype/hardware-facts" FACTS_OVERRIDE="$sandbox/none" \
		bash "$renderer" --deploy >/dev/null || fail "render failed for $archetype"
	printf '%s' "$home/.config/waybar/config"
}

# modules CONFIG — the module ids Waybar would place, one per line, after
# checking that each one has a definition and the file parses.
modules() {
	python - "$1" <<'PY'
import json, sys
config = json.load(open(sys.argv[1]))
placed = config["modules-left"] + config["modules-center"] + config["modules-right"]
missing = [m for m in placed if m not in config]
if missing:
    sys.exit(f"modules placed but not defined: {missing}")
print("\n".join(placed))
PY
}

expect() {
	local archetype="$1" present="$2" absent="$3" config listed module
	config="$(render "$archetype")"
	listed="$(modules "$config")" || fail "$archetype: $listed"
	for module in $present; do
		grep -Fxq "$module" <<<"$listed" || fail "$archetype: missing module $module"
	done
	for module in $absent; do
		grep -Fxq "$module" <<<"$listed" && fail "$archetype: unexpected module $module"
	done
	return 0
}

expect vm-virtio 'network#wired cpu memory disk pulseaudio custom/power custom/weather hyprland/window' 'battery backlight bluetooth custom/gpu temperature'
expect laptop-intel 'network#wireless network#wired battery backlight bluetooth temperature' 'custom/gpu'
expect laptop-amd-hybrid 'battery backlight custom/gpu temperature' 'bluetooth'
expect desktop-nvidia 'network#wired custom/gpu temperature' 'network#wireless battery backlight bluetooth'
expect headless-unknown 'network#wired custom/power' 'network#wireless battery backlight bluetooth custom/gpu temperature'

# The temperature module reads the sensor the facts found, never a hardcoded
# hwmon index: probe order differs between machines, and a config that names
# hwmon2 on this one shows the wrong chip — or nothing — on the next.
for archetype in desktop-nvidia laptop-intel laptop-amd-hybrid; do
	declared="$(python -c 'import json,sys; print(json.load(open(sys.argv[1]))["temperature"]["hwmon-path"])' \
		"$sandbox/$archetype/.config/waybar/config")"
	expected="$(sed -nE 's/^cpu_temp_path=(.*)$/\1/p' "$repo_root/tests/golden/$archetype/hardware-facts")"
	[[ "$declared" == "$expected" ]] ||
		fail "$archetype: temperature reads $declared, the facts say $expected"
done

# Exactly one weather definition survives the guards. Both surviving would be
# a duplicate key, and neither would place a module with no definition — the
# two failures a pair of complementary guards can produce.
for archetype in vm-virtio laptop-intel; do
	count="$(grep -c '"custom/weather":' "$sandbox/$archetype/.config/waybar/config")"
	((count == 1)) || fail "$archetype: $count weather definitions survived the guards"
done

# The last placed module is never guarded, so the JSON array never ends in a
# comma whichever facts hold.
for archetype in vm-virtio laptop-intel; do
	tail -n1 <<<"$(modules "$sandbox/$archetype/.config/waybar/config")" | grep -Fxq 'custom/power' || fail "$archetype: custom/power is not last"
done

printf 'waybar: adaptive modules verified on 5 archetypes\n'
