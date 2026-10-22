#!/usr/bin/env bash
set -Eeuo pipefail

# Graphics, kernel and display detectors against sandbox trees. The binary
# inputs these detectors parse — an EDID, an efivar — are materialised here at
# test time from hex, because the repository's own gates refuse committed
# binaries, and rightly so: a real EDID carries a monitor's serial.

repo_root="${REPO_ROOT:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)}"
for detector in graphics kernels display; do
	# shellcheck source=/dev/null
	source "$repo_root/lib/detect/$detector.sh"
done

sandbox="$(mktemp -d "${TMPDIR:-/tmp}/vivac-graphics.XXXXXX")"
trap 'rm -rf -- "$sandbox"' EXIT

fail() {
	printf '%s\n' "$1" >&2
	exit 1
}
expect() {
	[[ "$2" == "$3" ]] || fail "$1: expected '$2', got '$3'"
}
tree() {
	local root="$sandbox/$1"
	mkdir -p -- "$root/sys/class/drm"
	printf '%s' "$root"
}
# efivar VALUE FILE — 4 attribute bytes then the value byte.
efivar() { printf '\x06\x00\x00\x00%b' "\\x0$1" >"$2"; }
# edid WIDTH_CM FILE — a 128-byte block with only the physical size set.
edid() {
	local width_cm="$1" file="$2"
	head -c 128 /dev/zero >"$file"
	printf '%b' "\\x$(printf '%02x' "$width_cm")" | dd of="$file" bs=1 seek=21 conv=notrunc status=none
}

# --- desktop: one NVIDIA card, one kernel, one 1080p monitor ----------------
d="$(tree desktop)"
printf '%s\n' '2b:00.0 "0300" "10de" "2504" -ra1 -p00 "1462" "3903"' \
	'00:1f.3 "0403" "1022" "1457" -r00 -p00 "1462" "a0cc"' >"$d/lspci.txt"
printf '%s\n' linux linux-headers linux-api-headers linux-firmware >"$d/pacman-Qq.txt"
mkdir -p -- "$d/sys/firmware/efi/efivars" "$d/sys/class/drm/card1-HDMI-A-1" "$d/sys/class/drm/card1-DP-1"
efivar 0 "$d/sys/firmware/efi/efivars/SecureBoot-global"
printf 'connected\n' >"$d/sys/class/drm/card1-HDMI-A-1/status"
printf 'disconnected\n' >"$d/sys/class/drm/card1-DP-1/status"
printf '1920x1080\n' >"$d/sys/class/drm/card1-HDMI-A-1/modes"
edid 48 "$d/sys/class/drm/card1-HDMI-A-1/edid"

expect 'desktop/devices' '10de:2504' "$(SYSROOT="$d" detect_gpu_devices)"
expect 'desktop/vendors' 'nvidia' "$(SYSROOT="$d" detect_gpu_vendors)"
expect 'desktop/hybrid' 'no' "$(SYSROOT="$d" detect_gpu_hybrid)"
expect 'desktop/kernels' 'linux' "$(SYSROOT="$d" detect_kernels)"
expect 'desktop/dkms' 'no' "$(SYSROOT="$d" detect_needs_dkms)"
expect 'desktop/secure-boot' 'disabled' "$(SYSROOT="$d" detect_secure_boot)"
expect 'desktop/monitors' '1' "$(SYSROOT="$d" detect_monitor_count)"
expect 'desktop/scale' '1' "$(SYSROOT="$d" detect_max_scale)"

# --- hybrid laptop: Intel + NVIDIA, two kernels incl. zen, HiDPI, SB on -----
h="$(tree hybrid)"
printf '%s\n' '00:02.0 "0300" "8086" "a7a0" -r04 -p00 "17aa" "22e0"' \
	'01:00.0 "0302" "10de" "28e0" -ra1 -p00 "17aa" "22e0"' >"$h/lspci.txt"
printf '%s\n' linux linux-zen linux-zen-headers >"$h/pacman-Qq.txt"
mkdir -p -- "$h/sys/firmware/efi/efivars" "$h/sys/class/drm/card1-eDP-1" "$h/sys/class/drm/card1-DP-2"
efivar 1 "$h/sys/firmware/efi/efivars/SecureBoot-global"
printf 'connected\n' >"$h/sys/class/drm/card1-eDP-1/status"
printf 'connected\n' >"$h/sys/class/drm/card1-DP-2/status"
printf '2880x1800\n' >"$h/sys/class/drm/card1-eDP-1/modes"
edid 30 "$h/sys/class/drm/card1-eDP-1/edid" # 2880 px / 30 cm ≈ 244 dpi
printf '2560x1440\n' >"$h/sys/class/drm/card1-DP-2/modes"
edid 60 "$h/sys/class/drm/card1-DP-2/edid" # ≈ 108 dpi

expect 'hybrid/devices' '10de:28e0 8086:a7a0' "$(SYSROOT="$h" detect_gpu_devices)"
expect 'hybrid/vendors' 'intel nvidia' "$(SYSROOT="$h" detect_gpu_vendors)"
expect 'hybrid/hybrid' 'yes' "$(SYSROOT="$h" detect_gpu_hybrid)"
expect 'hybrid/kernels' 'linux linux-zen' "$(SYSROOT="$h" detect_kernels)"
expect 'hybrid/dkms' 'yes' "$(SYSROOT="$h" detect_needs_dkms)"
expect 'hybrid/secure-boot' 'enabled' "$(SYSROOT="$h" detect_secure_boot)"
expect 'hybrid/monitors' '2' "$(SYSROOT="$h" detect_monitor_count)"
expect 'hybrid/scale-is-the-max' '2' "$(SYSROOT="$h" detect_max_scale)"

# --- two cards of one vendor is not hybrid ----------------------------------
t="$(tree twin)"
printf '%s\n' '01:00.0 "0300" "1002" "744c" -rc8 -p00 "1002" "0e3b"' \
	'02:00.0 "0300" "1002" "744c" -rc8 -p00 "1002" "0e3b"' >"$t/lspci.txt"
expect 'twin/vendors' 'amd' "$(SYSROOT="$t" detect_gpu_vendors)"
expect 'twin/hybrid' 'no' "$(SYSROOT="$t" detect_gpu_hybrid)"

# --- VM with virtio, legacy BIOS, no EDID: everything degrades safely -------
v="$(tree vm)"
printf '%s\n' '00:01.0 "0300" "1af4" "1050" -r01 -p00 "1af4" "1100"' >"$v/lspci.txt"
printf '%s\n' linux linux-lts >"$v/pacman-Qq.txt"
mkdir -p -- "$v/sys/class/drm/card0-Virtual-1"
printf 'connected\n' >"$v/sys/class/drm/card0-Virtual-1/status"
printf '1920x1080\n' >"$v/sys/class/drm/card0-Virtual-1/modes"

expect 'vm/vendors' 'virtio' "$(SYSROOT="$v" detect_gpu_vendors)"
expect 'vm/dkms-two-prebuilt-kernels' 'no' "$(SYSROOT="$v" detect_needs_dkms)"
expect 'vm/no-efi-is-disabled' 'disabled' "$(SYSROOT="$v" detect_secure_boot)"
expect 'vm/no-edid-is-scale-1' '1' "$(SYSROOT="$v" detect_max_scale)"

# --- unknown vendor is generic, EFI without the var is unknown --------------
u="$(tree unknown)"
printf '%s\n' '03:00.0 "0380" "1ee1" "0001" -r00 -p00 "1ee1" "0001"' >"$u/lspci.txt"
mkdir -p -- "$u/sys/firmware/efi"
expect 'unknown/vendor-is-generic' 'generic' "$(SYSROOT="$u" detect_gpu_vendors)"
expect 'unknown/efi-without-var' 'unknown' "$(SYSROOT="$u" detect_secure_boot)"

# --- empty tree: no lspci dump, no packages, no drm ------------------------
e="$(tree empty)"
expect 'empty/devices' '' "$(SYSROOT="$e" detect_gpu_devices)"
expect 'empty/kernels' '' "$(SYSROOT="$e" detect_kernels)"
expect 'empty/monitors' '0' "$(SYSROOT="$e" detect_monitor_count)"

# --- EDID width 0 ("unknown") must not divide by zero -----------------------
z="$(tree zero)"
mkdir -p -- "$z/sys/class/drm/card0-eDP-1"
printf 'connected\n' >"$z/sys/class/drm/card0-eDP-1/status"
printf '3840x2160\n' >"$z/sys/class/drm/card0-eDP-1/modes"
edid 0 "$z/sys/class/drm/card0-eDP-1/edid"
expect 'zero/edid-width-0' '1' "$(SYSROOT="$z" detect_max_scale)"

# --- isolation: a fixture root never sees this host's GPU -------------------
expect 'isolation/no-lspci-dump-means-no-gpu' '' "$(SYSROOT="$e" detect_gpu_vendors)"

# --- the live host answers in-domain -----------------------------------------
for probe in detect_gpu_hybrid detect_needs_dkms; do
	[[ "$(SYSROOT='' "$probe")" =~ ^(yes|no)$ ]] || fail "live host: $probe out of domain"
done
[[ "$(SYSROOT='' detect_secure_boot)" =~ ^(enabled|disabled|unknown)$ ]] || fail 'live host: secure_boot out of domain'
[[ "$(SYSROOT='' detect_max_scale)" =~ ^(1|1\.5|2)$ ]] || fail 'live host: max_scale out of domain'

printf 'graphics: 7 trees, hybrid/twin/virtio/generic, HiDPI from EDID, secure boot 3 states\n'
