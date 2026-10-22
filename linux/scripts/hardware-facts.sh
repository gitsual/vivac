#!/usr/bin/env bash
set -Eeuo pipefail

# Describe this machine as a small, closed set of facts that the rest of the
# repository is allowed to branch on: which modules the status bar shows, which
# graphics stack gets installed, which selectors bootstrap offers.
#
# The generated file is machine-specific and therefore never committed. What is
# committed is hardware-facts.example, for documentation and fixtures.
#
# Exit codes follow the repository convention: 0 success, 1 runtime failure,
# 2 usage error, 3 request valid but inapplicable to this machine.

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"

# shellcheck source=lib/kv.sh
source "$repo_root/lib/kv.sh"
# shellcheck source=lib/facts.sh
source "$repo_root/lib/facts.sh"
# shellcheck source=lib/gpu.sh
source "$repo_root/lib/gpu.sh"
for detector in chassis power input net thermal graphics kernels display; do
	# shellcheck source=/dev/null
	source "$repo_root/lib/detect/$detector.sh"
done

facts_file="${FACTS_FILE:-${XDG_STATE_HOME:-$HOME/.local/state}/vivac/hardware-facts}"
facts_override="${FACTS_OVERRIDE:-${XDG_CONFIG_HOME:-$HOME/.config}/vivac/hardware-facts.override}"
action=''
print_key=''

usage() {
	cat <<'USAGE'
Usage: scripts/hardware-facts.sh [--emit | --print KEY | --check | --dry-run]

  --emit       detect this machine and write the facts file
  --print KEY  print one fact, applying the override file
  --check      verify the facts file exists and matches this code's schema
  --dry-run    detect and print what --emit would write, touching nothing

Environment:
  SYSROOT         read hardware state from this root instead of /
  FACTS_FILE      where the generated file lives
  FACTS_OVERRIDE  user overrides, merged last so they always win
USAGE
}

set_action() {
	[[ -z "$action" ]] || {
		printf 'Choose one action at a time.\n' >&2
		usage >&2
		exit 2
	}
	action="$1"
}

while (($#)); do
	case "$1" in
	--emit) set_action emit ;;
	--check) set_action check ;;
	--dry-run) set_action dry-run ;;
	--print)
		set_action print
		shift
		[[ $# -gt 0 ]] || {
			printf -- '--print needs a key.\n' >&2
			exit 2
		}
		print_key="$1"
		;;
	-h | --help)
		usage
		exit 0
		;;
	*)
		printf 'Unknown option: %s\n' "$1" >&2
		usage >&2
		exit 2
		;;
	esac
	shift
done

[[ -n "$action" ]] || {
	usage >&2
	exit 2
}

# Run every detector once. Adding a fact means adding a line here and a key to
# the allowlist in lib/facts.sh — the allowlist is what stops anything else
# reaching the file.
collect() {
	# shellcheck disable=SC2034  # filled through the nameref for the caller
	local -n out="$1"
	out['chassis']="$(detect_chassis)"
	out['virt']="$(detect_virt)"
	out['has_battery']="$(detect_has_battery)"
	out['has_backlight']="$(detect_has_backlight)"
	out['has_touchpad']="$(detect_has_touchpad)"
	out['has_wifi']="$(detect_has_wifi)"
	out['has_bluetooth']="$(detect_has_bluetooth)"
	out['cpu_temp_path']="$(detect_cpu_temp_path)"
	out['gpu_vendors']="$(detect_gpu_vendors)"
	out['gpu_devices']="$(detect_gpu_devices)"
	out['gpu_hybrid']="$(detect_gpu_hybrid)"
	# Not detected: joined from the catalogue, so a new family is one row.
	gpu_load_catalogue "${GPU_CATALOGUE_FILE:-$repo_root/data/gpu-catalogue.tsv}"
	out['gpu_families']="$(gpu_families "${out['gpu_devices']}")"
	out['kernels']="$(detect_kernels)"
	out['needs_dkms']="$(detect_needs_dkms)"
	out['secure_boot']="$(detect_secure_boot)"
	out['monitor_count']="$(detect_monitor_count)"
	out['max_scale']="$(detect_max_scale)"
}

case "$action" in
emit)
	# shellcheck disable=SC2034  # passed by name to collect and facts_emit
	declare -A detected=()
	collect detected
	mkdir -p -- "$(dirname -- "$facts_file")"
	facts_emit detected "$facts_file"
	printf 'hardware facts written: %s\n' "$facts_file"
	;;

dry-run)
	# shellcheck disable=SC2034  # passed by name to collect and facts_emit
	declare -A detected=()
	collect detected
	scratch="$(mktemp)"
	trap 'rm -f -- "$scratch"' EXIT
	facts_emit detected "$scratch"
	cat -- "$scratch"
	;;

check)
	[[ -r "$facts_file" ]] || {
		printf 'no facts file at %s; run --emit first\n' "$facts_file" >&2
		exit 3
	}
	facts_require_schema "$facts_file" || exit 1
	printf 'hardware facts: schema %s, %d facts\n' \
		"$FACTS_SCHEMA" "$(grep -cv '^#' "$facts_file")"
	;;

print)
	[[ -r "$facts_file" ]] || {
		printf 'no facts file at %s; run --emit first\n' "$facts_file" >&2
		exit 3
	}
	facts_require_schema "$facts_file" || exit 1
	facts_key_allowed "$print_key" || {
		printf '%s is not a fact this repository records\n' "$print_key" >&2
		exit 2
	}
	# The override is merged last, so a user's correction always wins over
	# whatever detection concluded.
	declare -A merged=()
	facts_load merged "$facts_file" "$facts_override" || {
		printf 'could not read %s\n' "$facts_file" >&2
		exit 1
	}
	[[ -v merged["$print_key"] ]] || exit 1
	printf '%s\n' "${merged["$print_key"]}"
	;;
esac
