#!/usr/bin/env bash
# Install the GPU driver stack this machine needs, from the catalogue.
#
# The families come from the hardware facts (gpu_families), so the choice is
# the detector's, not the user's guess. --gpu FAMILY exists for the case the
# detector is wrong; it is accepted only when the family is one the facts
# also see, or the Mesa-only fallback, and refused with exit 3 otherwise: a
# driver for a card that is not there is not a preference, it is a broken
# boot.
#
# Nothing is installed without --apply. The default is a dry run that prints
# the stack, the kernel headers it needs and every warning, so the owner can
# read it before a single package moves.
set -Eeuo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
# shellcheck source=lib/kv.sh
source "$repo_root/lib/kv.sh"
# shellcheck source=lib/facts.sh
source "$repo_root/lib/facts.sh"
# shellcheck source=lib/gpu.sh
source "$repo_root/lib/gpu.sh"
# shellcheck source=lib/i18n.sh
source "$repo_root/lib/i18n.sh"

facts_file="${FACTS_FILE:-${XDG_STATE_HOME:-$HOME/.local/state}/vivac/hardware-facts}"
facts_override="${FACTS_OVERRIDE:-${XDG_CONFIG_HOME:-$HOME/.config}/vivac/hardware-facts.override}"
backup_root="${XDG_STATE_HOME:-$HOME/.local/state}/vivac/backups"
# The hyprlang and Lua fragments ship side by side until the hyprlang one goes.
fragments=("${XDG_CONFIG_HOME:-$HOME/.config}/hypr/generated/hardware.lua" "${XDG_CONFIG_HOME:-$HOME/.config}/hypr/generated/hardware.conf")

language="${VIVAC_LANG:-${LANG:-en}}"
language="${language%%[._@]*}"
i18n_load "$language" "${I18N_DIR:-$repo_root/i18n}" 2>/dev/null || i18n_load en "${I18N_DIR:-$repo_root/i18n}"

usage() {
	cat <<'USAGE'
Usage: scripts/gpu-setup.sh [--dry-run | --apply] [--gpu FAMILY]
       scripts/gpu-setup.sh --list
       scripts/gpu-setup.sh --restore-config [--dry-run]

  --dry-run         print the stack, headers and warnings; install nothing (default)
  --apply           install the stack with pacman and re-render the Hyprland fragment
  --gpu FAMILY      use FAMILY instead of the detected one; refused (exit 3) unless
                    the facts also see that family, or FAMILY is generic
  --list            print every catalogue family and how it was verified
  --restore-config  put back the previous ~/.config/hypr/generated/hardware.lua
                    and hardware.conf from their newest backups (each current
                    one is backed up first); packages are left alone

Facts come from scripts/hardware-facts.sh --emit (override: FACTS_FILE,
FACTS_OVERRIDE). Packages from the AUR are listed, never installed here.
USAGE
}

mode=stack
dry=true
dry_asked=false
requested=''
while (($#)); do
	case "$1" in
	--dry-run) dry=true; dry_asked=true ;;
	--apply) dry=false ;;
	--list) mode=list ;;
	--restore-config) mode=restore ;;
	--gpu)
		[[ $# -ge 2 ]] || {
			printf '--gpu needs a family name\n' >&2
			exit 2
		}
		requested="$2"
		shift
		;;
	-h | --help)
		usage
		exit 0
		;;
	*)
		printf 'Unknown option: %s\n' "$1" >&2
		exit 2
		;;
	esac
	shift
done
gpu_load_catalogue "$repo_root/data/gpu-catalogue.tsv"

if [[ "$mode" == list ]]; then
	for id in "${GPU_IDS[@]}"; do
		case "${GPU_VERIFIED["$id"]}" in
		-) status='recommendation, untested on hardware' ;;
		vm) status='verified in the VM gate' ;;
		*) status="observed on the author's ${GPU_VERIFIED["$id"]}" ;;
		esac
		printf '%-20s %-52s %s\n' "$id" "$(i18n_get "${GPU_LABEL["$id"]}")" "$status"
	done
	exit 0
fi

if [[ "$mode" == restore ]]; then
	# Each fragment comes back from its own newest backup. Restoring acts unless
	# --dry-run is asked for: it moves files, and the file each one replaces is
	# kept under a new backup stamp, so nothing is lost.
	restored=0
	for fragment in "${fragments[@]}"; do
		relative="${fragment#"$HOME"/}"
		newest=''
		for stamp in "$backup_root"/*/; do
			[[ -f "$stamp$relative" ]] && newest="$stamp$relative"
		done
		[[ -n "$newest" ]] || continue
		restored=$((restored + 1))
		if $dry_asked; then
			printf 'would restore %s from %s\n' "$fragment" "$newest"
			continue
		fi
		if [[ -e "$fragment" ]]; then
			keep="$backup_root/$(date -u +%Y%m%dT%H%M%SZ)/$relative"
			mkdir -p -- "$(dirname -- "$keep")"
			cp -a -- "$fragment" "$keep"
		fi
		mkdir -p -- "$(dirname -- "$fragment")"
		cp -a -- "$newest" "$fragment"
		printf 'restored %s from %s\n' "$fragment" "$newest"
	done
	((restored)) || {
		printf 'gpu-setup: no backup of %s under %s\n' "${fragments[*]}" "$backup_root" >&2
		exit 1
	}
	$dry_asked && exit 0
	printf 'Not undone here: installed packages (pacman -Rns), the initramfs (mkinitcpio -P) and kernel parameters.\n'
	exit 0
fi

declare -A facts=()
facts_load facts "$facts_file" "$facts_override" || {
	printf 'gpu-setup: no hardware facts at %s; run scripts/hardware-facts.sh --emit first\n' "$facts_file" >&2
	exit 1
}
detected="$(gpu_stack_families facts)"

if [[ -n "$requested" ]]; then
	[[ -v GPU_MANIFEST["$requested"] ]] || {
		printf 'gpu-setup: unknown family %s; see --list\n' "$requested" >&2
		exit 2
	}
	if [[ "$requested" != generic && " $detected " != *" $requested "* ]]; then
		printf 'gpu-setup: the facts see [%s], not %s. Installing a driver for a GPU that is not there is refused; fix %s or pass a family the facts see.\n' \
			"$detected" "$requested" "$facts_override" >&2
		exit 3
	fi
	# Narrow the facts to the devices of the requested family. PRIME needs
	# both GPUs, so a hybrid narrowed to one family is no longer hybrid.
	kept=''
	for device in ${facts[gpu_devices]:-}; do
		[[ "$(gpu_family_for_device "$device")" == "$requested" ]] && kept+="$device "
	done
	facts[gpu_devices]="${kept% }"
	facts[gpu_hybrid]=no
	families="$requested"
else
	families="$detected"
fi

mapfile -t packages < <(gpu_stack_packages facts "$repo_root")
warnings="$(gpu_stack_warnings facts "$repo_root")"
aur=()
repo=()
for package in "${packages[@]}"; do
	if [[ "$package" == nvidia-470xx-* ]]; then aur+=("$package"); else repo+=("$package"); fi
done

printf 'GPU families: %s\n' "$families"
printf 'Packages (%d): %s\n' "${#repo[@]}" "${repo[*]}"
((${#aur[@]})) && printf 'From the AUR, not installed here: %s\n' "${aur[*]}"
[[ -n "$warnings" ]] && printf 'Warning: %s\n' "$warnings"

if $dry; then
	printf 'Dry run: nothing installed. Re-run with --apply.\n'
	exit 0
fi

sudo pacman -S --needed --noconfirm -- "${repo[@]}"
"$repo_root/scripts/render-config.sh" --deploy
printf 'Installed. Reboot so the new kernel modules load.\n'
