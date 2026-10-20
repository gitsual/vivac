#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
# shellcheck source=lib/kv.sh
source "$repo_root/lib/kv.sh"
# shellcheck source=lib/facts.sh
source "$repo_root/lib/facts.sh"
# shellcheck source=lib/selectors.sh
source "$repo_root/lib/selectors.sh"
# shellcheck source=lib/i18n.sh
source "$repo_root/lib/i18n.sh"
for detector in chassis power input net thermal graphics kernels display; do
	# shellcheck source=/dev/null
	source "$repo_root/lib/detect/$detector.sh"
done
selectors_load "${SELECTORS_FILE:-$repo_root/data/selectors.tsv}"

# Messages follow the `language` setting, else the session locale (the
# --locale axis sets it system-wide); VIVAC_LANG overrides for one run. C and
# POSIX mean the reference table.
language="$(i18n_session_language)"
i18n_load "$language" "${I18N_DIR:-$repo_root/i18n}" 2>/dev/null || i18n_load en "${I18N_DIR:-$repo_root/i18n}"

dry_run=false
no_install=false
system_profile=false
desktop_login=false
vm_profile=false
noninteractive=false
list_selectors=false
requested_selectors=()
gui_greeter=false

usage() {
	cat <<'USAGE'
Usage: scripts/bootstrap.sh [--dry-run] [--no-install] [--noconfirm] [--system] [--list-selectors] [SELECTOR-FLAG ...]

Profiles:
  base             Portable workstation packages and user configuration (always)
  --desktop-login  Add greetd/tuigreet for a complete graphical login path
  --vm             Add QEMU/SPICE guest integration
  --system         Apply selected system profiles after installation
  --list-selectors Show which optional profiles apply to this machine and exit

A profile that does not apply to this machine is not offered; asking for it
explicitly exits 3 and says why.
USAGE
}

# Detect this machine once, in memory. bootstrap runs on a fresh install, so it
# cannot assume a facts file exists yet.
declare -A facts=()
facts['chassis']="$(detect_chassis)"
facts['virt']="$(detect_virt)"
facts['has_battery']="$(detect_has_battery)"
facts['has_backlight']="$(detect_has_backlight)"
facts['has_touchpad']="$(detect_has_touchpad)"
facts['has_wifi']="$(detect_has_wifi)"
facts['has_bluetooth']="$(detect_has_bluetooth)"
facts['cpu_temp_path']="$(detect_cpu_temp_path)"
facts['gpu_vendors']="$(detect_gpu_vendors)"
facts['gpu_devices']="$(detect_gpu_devices)"
facts['gpu_hybrid']="$(detect_gpu_hybrid)"
facts['kernels']="$(detect_kernels)"
facts['needs_dkms']="$(detect_needs_dkms)"
facts['secure_boot']="$(detect_secure_boot)"
facts['monitor_count']="$(detect_monitor_count)"
facts['max_scale']="$(detect_max_scale)"

while (($#)); do
	case "$1" in
	--dry-run) dry_run=true ;;
	--no-install) no_install=true ;;
	--noconfirm) noninteractive=true ;;
	--system) system_profile=true ;;
	--list-selectors) list_selectors=true ;;
	-h | --help)
		usage
		exit 0
		;;
	--*)
		# Any other flag must be a selector's system_flag from the registry.
		if id="$(selector_for_flag "$1")"; then
			requested_selectors+=("$id")
		else
			printf 'Unknown option: %s\n' "$1" >&2
			exit 2
		fi
		;;
	*)
		printf 'Unknown option: %s\n' "$1" >&2
		exit 2
		;;
	esac
	shift
done

if $list_selectors; then
	printf '%s\n' "$(i18n_format bootstrap.this_machine "${facts[chassis]}" "${facts[gpu_vendors]:-none}")"
	for id in "${SELECTOR_IDS[@]}"; do
		if selector_applicable "$id" facts; then
			printf '  %-16s %s: %s\n' "${SELECTOR_FLAG["$id"]}" "$(i18n_get selector.applies)" "$(i18n_get "${SELECTOR_LABEL["$id"]}")"
		else
			printf '  %-16s %s: %s\n' "${SELECTOR_FLAG["$id"]}" "$(i18n_format selector.needs "${SELECTOR_PREDICATE["$id"]}")" "$(i18n_get "${SELECTOR_LABEL["$id"]}")"
		fi
	done
	exit 0
fi

# An explicit request for a selector this machine does not satisfy is a
# mistake worth stopping on, not something to quietly skip.
for id in "${requested_selectors[@]}"; do
	selector_applicable "$id" facts || {
		printf '%s\n' "$(i18n_format selector.not_applicable "${SELECTOR_FLAG["$id"]}" "${SELECTOR_PREDICATE["$id"]}") ($(for atom in ${SELECTOR_PREDICATE["$id"]}; do [[ "$atom" =~ ^([a-z_]+) ]] && printf '%s=%s ' "${BASH_REMATCH[1]}" "${facts[${BASH_REMATCH[1]}]:-}"; done))" >&2
		printf 'Run scripts/bootstrap.sh --list-selectors to see what applies.\n' >&2
		exit 3
	}
	case "$id" in
	desktop-login) desktop_login=true ;;
	vm) vm_profile=true ;;
	gui-greeter) gui_greeter=true ;;
	esac
done

# shellcheck disable=SC1091
source /etc/os-release
[[ "${ID:-}" == arch ]] || {
	printf 'This bootstrap supports Arch Linux only.\n' >&2
	exit 1
}

mapfile -t official < <(grep -Ev '^[[:space:]]*(#|$)' "$repo_root/packages/pacman.txt")
mapfile -t aur < <(grep -Ev '^[[:space:]]*(#|$)' "$repo_root/packages/aur.txt")
# Every requested selector contributes its manifest from the registry; the
# registry is the only place a selector and its packages are tied together.
for id in "${requested_selectors[@]}"; do
	mapfile -t optional < <(grep -Ev '^[[:space:]]*(#|$)' "$repo_root/${SELECTOR_MANIFEST["$id"]}")
	official+=("${optional[@]:-}")
	# A selector may also name packages that only exist as AUR build recipes,
	# in a sibling manifest. They are kept apart because installing them is a
	# different act: pacman fetches a binary, the AUR compiles one here.
	aur_manifest="$repo_root/${SELECTOR_MANIFEST["$id"]%.txt}-aur.txt"
	if [[ -f "$aur_manifest" ]]; then
		mapfile -t optional_aur < <(grep -Ev '^[[:space:]]*(#|$)' "$aur_manifest")
		aur+=("${optional_aur[@]:-}")
	fi
done
mapfile -t official < <(printf '%s\n' "${official[@]}" | grep -v '^$' | LC_ALL=C sort -u)
mapfile -t aur < <(printf '%s\n' "${aur[@]:-}" | grep -v '^$' | LC_ALL=C sort -u)

system_args=()
$desktop_login && system_args+=(--desktop-login)
$vm_profile && system_args+=(--vm)
$gui_greeter && system_args+=(--greeter)

if $dry_run; then
	printf 'would install official packages (%d): %s\n' "${#official[@]}" "${official[*]}"
	((${#aur[@]})) && printf 'would install AUR packages (%d): %s\n' "${#aur[@]}" "${aur[*]}"
	HOME="${HOME}" "$repo_root/scripts/deploy.sh" --all --dry-run
	facts_preview="$(mktemp "${TMPDIR:-/tmp}/vivac-facts.XXXXXX")"
	"$repo_root/scripts/hardware-facts.sh" --dry-run >"$facts_preview"
	FACTS_FILE="$facts_preview" "$repo_root/scripts/render-config.sh" --dry-run
	rm -f -- "$facts_preview"
	if $system_profile; then
		"$repo_root/scripts/apply-system.sh" --dry-run "${system_args[@]}"
	fi
	exit 0
fi

if ! $no_install; then
	pacman_args=(-S --needed)
	$noninteractive && pacman_args+=(--noconfirm)
	sudo pacman "${pacman_args[@]}" -- "${official[@]}"
	if ((${#aur[@]})); then
		# One place owns the decision to compile from the AUR, and it neither
		# needs nor installs a helper: every name is built from its own recipe
		# against the pacman that is on this machine.
		aur_args=()
		$noninteractive && aur_args+=(--noconfirm)
		"$repo_root/scripts/aur-install.sh" "${aur_args[@]}" -- "${aur[@]}"
	fi
fi

"$repo_root/scripts/deploy.sh" --all
# The machine-specific fragments are rendered after Stow so that the escape
# gate sees the final directory layout, and before check.sh so a render
# failure stops the bootstrap here rather than surfacing as a broken session.
"$repo_root/scripts/hardware-facts.sh" --emit
"$repo_root/scripts/render-config.sh" --deploy
"$repo_root/scripts/check.sh"
if $system_profile; then
	"$repo_root/scripts/apply-system.sh" "${system_args[@]}"
fi
