#!/usr/bin/env bash
set -Eeuo pipefail

# gpu-setup.sh installs nothing without --apply, refuses a family the facts do
# not see with exit 3, lists the catalogue with its verification status, and
# restores the Hyprland fragment from the newest backup. A fake sudo and pacman
# on PATH turn any attempt to install into a failure.

repo_root="${REPO_ROOT:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)}"
sandbox="$(mktemp -d "${TMPDIR:-/tmp}/vivac-gpu-setup.XXXXXX")"
trap 'rm -rf -- "$sandbox"' EXIT

fail() {
	printf '%s\n' "$1" >&2
	exit 1
}
mkdir -p -- "$sandbox/bin" "$sandbox/h"
for tool in sudo pacman; do
	printf '#!/usr/bin/env bash\nprintf "%s must not run in a dry run\\n" >&2\nexit 99\n' "$tool" >"$sandbox/bin/$tool"
	chmod +x "$sandbox/bin/$tool"
done
run() {
	PATH="$sandbox/bin:$PATH" HOME="$sandbox/h" XDG_CONFIG_HOME="$sandbox/h/.config" \
		XDG_STATE_HOME="$sandbox/h/.local/state" FACTS_OVERRIDE="$sandbox/none" VIVAC_LANG=en \
		bash "$repo_root/scripts/gpu-setup.sh" "$@"
}
golden() { printf '%s' "$repo_root/tests/golden/$1/hardware-facts"; }

# --- default is a dry run: the stack is printed, nothing runs -------------------------------
out="$(FACTS_FILE="$(golden laptop-amd-hybrid)" run)" || fail "hybrid dry run failed: $out"
[[ "$out" == *'GPU families: amd_amdgpu nvidia_open'* ]] || fail "hybrid: families missing: $out"
[[ "$out" == *nvidia-prime* && "$out" == *linux-zen-headers* ]] || fail "hybrid: PRIME or headers missing: $out"
[[ "$out" == *'prime-run'* ]] || fail "hybrid: no PRIME warning: $out"
[[ "$out" == *'nothing installed'* ]] || fail "hybrid: not a dry run: $out"

# --- the AUR is listed, never installed ------------------------------------------------------------
facts="$sandbox/kepler"
sed 's/^gpu_devices=.*/gpu_devices=10de:1180/' "$(golden desktop-nvidia)" >"$facts"
out="$(FACTS_FILE="$facts" run)" || fail "kepler dry run failed: $out"
[[ "$out" == *'From the AUR, not installed here: nvidia-470xx-dkms nvidia-470xx-utils'* ]] || fail "kepler: AUR packages not separated: $out"

# --- Secure Boot with DKMS is warned about, on the same line the owner reads -----------------
sed 's/^secure_boot=.*/secure_boot=enabled/' "$(golden desktop-nvidia)" >"$sandbox/sb"
out="$(FACTS_FILE="$sandbox/sb" run)" || fail "secure boot dry run failed: $out"
[[ "$out" == *'Secure Boot is enabled'* ]] || fail "secure boot: no warning: $out"

# --- --gpu: a family the facts do not see is refused with exit 3 -----------------------------------
status=0
out="$(FACTS_FILE="$(golden desktop-nvidia)" run --gpu intel_i915 2>&1)" || status=$?
((status == 3)) || fail "mismatch: expected exit 3, got $status: $out"
[[ "$out" == *'not intel_i915'* ]] || fail "mismatch: message does not name the family: $out"
status=0
FACTS_FILE="$(golden desktop-nvidia)" run --gpu no_such_family >/dev/null 2>&1 || status=$?
((status == 2)) || fail "unknown family: expected exit 2, got $status"
out="$(FACTS_FILE="$(golden desktop-nvidia)" run --gpu generic)" || fail 'generic must always be accepted'
[[ "$out" == *'GPU families: generic'* && "$out" != *nvidia* ]] || fail "generic: NVIDIA leaked in: $out"
out="$(FACTS_FILE="$(golden laptop-amd-hybrid)" run --gpu amd_amdgpu)" || fail 'narrowing a hybrid to a seen family must work'
[[ "$out" != *nvidia-prime* && "$out" != *nvidia-open-dkms* ]] || fail "narrowed hybrid: NVIDIA stack still present: $out"

# --- --apply reaches pacman through sudo and fails here, proving the dry run never did ---------
status=0
FACTS_FILE="$(golden laptop-intel)" run --apply >/dev/null 2>&1 || status=$?
((status == 99)) || fail "apply: expected the fake sudo to be reached (99), got $status"

# --- --list names every family with its verification status -------------------------------------------
out="$(run --list)" || fail '--list failed'
for family in nvidia_open nvidia_proprietary nvidia_legacy_470 intel_xe intel_i915 amd_amdgpu virtio generic; do
	grep -q "^$family " <<<"$out" || fail "--list: $family missing"
done
grep -q "^nvidia_open .*observed on the author's workstation" <<<"$out" || fail '--list: nvidia_open status wrong'
grep -q '^virtio .*VM gate' <<<"$out" || fail '--list: virtio status wrong'
grep -q '^intel_i915 .*untested on hardware' <<<"$out" || fail '--list: intel_i915 status wrong'

# --- --restore-config puts back the newest backup of the fragment, and only that ----------------
# Content is compared byte for byte: a trailing newline or a NUL must not be normalised away.
backups="$sandbox/h/.local/state/vivac/backups"
generated="$sandbox/h/.config/hypr/generated"
mkdir -p -- "$backups/20260101T000000Z/.config/hypr/generated" "$backups/20260102T000000Z/.config/hypr/generated" "$generated"
printf 'old lua\n' >"$backups/20260101T000000Z/.config/hypr/generated/hardware.lua"
printf 'newer lua\0no newline' >"$backups/20260102T000000Z/.config/hypr/generated/hardware.lua"
printf 'current lua\n' >"$generated/hardware.lua"
out="$(run --restore-config --dry-run)" || fail 'restore dry run failed'
[[ "$out" == would\ restore* && "$(<"$generated/hardware.lua")" == 'current lua' ]] || fail "restore dry run touched a fragment: $out"
out="$(run --restore-config)" || fail 'restore failed'
[[ "$out" == *'Not undone here: installed packages'* ]] || fail "restore does not say what it leaves alone: $out"
cmp -s "$generated/hardware.lua" "$backups/20260102T000000Z/.config/hypr/generated/hardware.lua" || fail 'restore did not put back hardware.lua byte for byte from the newest backup'
[[ -z "$(find "$generated" -name '*.conf')" ]] || fail 'restore wrote a hyprlang fragment'
# What was replaced is kept under a new stamp, so a restore can be undone.
kept="$(printf '%s\n' "$backups"/*/.config/hypr/generated/hardware.lua | wc -l)"
((kept == 3)) || fail "restore did not keep the replaced hardware.lua ($kept copies)"
status=0
rm -rf -- "$backups"
run --restore-config >/dev/null 2>&1 || status=$?
((status == 1)) || fail "restore with no backup: expected exit 1, got $status"

# --- the help never promises a rollback: what it does is restore one file ---------------------------
run --help | grep -qi rollback && fail 'help mentions rollback'

printf 'gpu setup: dry run by default, exit 3 on a family the facts do not see, list, restore\n'
