#!/usr/bin/env bash
set -Eeuo pipefail

# Build a standalone, publishable VM image from the current tree.
#
# The image is sealed only from a guest that passed tests/guest-acceptance.sh,
# the same acceptance scripts/test-vm.sh runs: an image nobody could verify is
# exactly the kind of claim this repository refuses to make.
#
# What leaves this script is a flat qcow2. scripts/test-vm.sh leaves a qcow2
# overlay with a backing file, which is useless on any other machine.

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
work_root="${VM_WORKDIR:-$repo_root/.vm-image}"
cache="${VM_IMAGE_CACHE:-$repo_root/.vm-test/cache}"
run="$work_root/run"
output_dir="$repo_root/dist"
image_url="${ARCH_VM_IMAGE_URL:-https://geo.mirror.pkgbuild.com/images/latest/Arch-Linux-x86_64-cloudimg.qcow2}"
disk_size="${VM_IMAGE_DISK:-20G}"
keep=false

# The published image is neutral, not this author's desk: the acceptance seeds
# three deliberately distinguishable axes (es/es/fr) to prove each has its own
# writer, and the seal replaces them with defaults a stranger would expect.
image_locale="${VM_IMAGE_LOCALE:-en_US.UTF-8}"
image_keymap="${VM_IMAGE_KEYMAP:-us}"
image_layout="${VM_IMAGE_LAYOUT:-us}"

usage() {
	cat <<'USAGE'
Usage: scripts/build-vm-image.sh [--keep] [--output DIR]

Provision, accept and seal a standalone qcow2 from the current tree.
  --keep        Preserve the build overlay and logs
  --output DIR  Write the artifact here (default: dist/)

Overrides: VM_WORKDIR, VM_IMAGE_CACHE, ARCH_VM_IMAGE_URL, VM_MEMORY_MB,
VM_CPUS, VM_SSH_PORT, VM_IMAGE_DISK, VM_IMAGE_LOCALE, VM_IMAGE_KEYMAP,
VM_IMAGE_LAYOUT.
No host packages, services, firewall rules or user configuration are changed.
USAGE
}

while (($#)); do
	case "$1" in
	--keep) keep=true ;;
	--output)
		[[ $# -ge 2 ]] || {
			printf '%s\n' '--output needs a directory' >&2
			exit 2
		}
		output_dir="$2"
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

for command_name in qemu-system-x86_64 qemu-img xorriso curl ssh ssh-keygen sha256sum tar; do
	command -v "$command_name" >/dev/null || {
		printf 'Missing host dependency: %s\n' "$command_name" >&2
		exit 1
	}
done
[[ -r /dev/kvm && -w /dev/kvm ]] || {
	printf '%s\n' '/dev/kvm is not usable by the current user' >&2
	exit 1
}
for name in image_locale image_keymap image_layout; do
	[[ "${!name}" =~ ^[A-Za-z0-9_.@-]+$ ]] || {
		printf 'Invalid %s: %s\n' "$name" "${!name}" >&2
		exit 2
	}
done

mkdir -p -- "$cache" "$output_dir"
rm -rf -- "$run"
mkdir -p -- "$run"

base="$cache/Arch-Linux-x86_64-cloudimg.qcow2"
checksum="$cache/Arch-Linux-x86_64-cloudimg.qcow2.SHA256"
if [[ ! -f "$base" ]]; then
	printf '%s\n' 'Downloading official Arch cloud image...'
	curl -fL --retry 3 --output "$base.part" "$image_url"
	mv -- "$base.part" "$base"
fi
curl -fL --retry 3 --output "$checksum" "$image_url.SHA256"
expected="$(cut -d' ' -f1 <"$checksum")"
actual="$(sha256sum "$base" | cut -d' ' -f1)"
[[ "$actual" == "$expected" ]] || {
	printf '%s\n' 'Arch cloud image checksum mismatch' >&2
	exit 1
}

# The account a stranger logs into. It is named for what it is, because the
# credentials are a convention (user:user, root:toor) rather than a secret, and
# a demo image whose username has to be looked up is a worse demo.
image_user='user'

# The build key never reaches the artifact: the seal removes it before the
# guest powers off, and a test asserts the removal on the flattened image.
ssh-keygen -q -t ed25519 -N '' -f "$run/id_ed25519"
public_key="$(<"$run/id_ed25519.pub")"
cat >"$run/meta-data" <<'META'
instance-id: vivac-image
local-hostname: vivac
META
cat >"$run/user-data" <<USERDATA
#cloud-config
users:
  - name: $image_user
    groups: [wheel]
    shell: /bin/bash
    sudo: ALL=(ALL) NOPASSWD:ALL
    ssh_authorized_keys:
      - $public_key
ssh_pwauth: false
runcmd:
  - systemctl enable --now sshd.service
USERDATA
xorriso -as mkisofs -quiet -output "$run/seed.iso" -volid cidata -joliet -rock "$run/user-data" "$run/meta-data"

# shellcheck source=lib/repository-iso.sh
source "$repo_root/lib/repository-iso.sh"
repository_iso "$repo_root" "$run"
qemu-img create -q -f qcow2 -F qcow2 -b "$base" "$run/build.qcow2" "$disk_size"

port="${VM_SSH_PORT:-}"
host_address="$(printf '%d.%d.%d.%d' 127 0 0 1)"
if [[ -z "$port" ]]; then
	port="$(python -c 'import socket; s=socket.socket(); s.bind(("localhost", 0)); print(s.getsockname()[1]); s.close()')"
fi
memory="${VM_MEMORY_MB:-8192}"
cpus="${VM_CPUS:-4}"

# discard=unmap so the seal's fstrim actually punches holes: without it every
# block a removed package ever touched stays allocated and ships compressed.
qemu-system-x86_64 \
	-enable-kvm -machine q35,accel=kvm -cpu host \
	-smp "$cpus" -m "$memory" \
	-drive "if=virtio,format=qcow2,discard=unmap,file=$run/build.qcow2" \
	-drive "media=cdrom,readonly=on,file=$run/seed.iso" \
	-drive "media=cdrom,readonly=on,file=$run/repository.iso" \
	-netdev "user,id=net0,hostfwd=tcp:$host_address:$port-:22" \
	-device virtio-net-pci,netdev=net0 \
	-device virtio-vga -display none \
	-daemonize -pidfile "$run/qemu.pid" \
	-serial "file:$run/serial.log"

qemu_pid="$(<"$run/qemu.pid")"
cleanup() {
	status=$?
	kill "$qemu_pid" 2>/dev/null || true
	if ((status == 0)) && ! $keep; then rm -rf -- "$run"; fi
	if ((status != 0)); then
		printf 'Image build failed; evidence kept in %s\n' "$run" >&2
	fi
}
trap cleanup EXIT

ssh_opts=(-i "$run/id_ed25519" -p "$port" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5)
ready=false
for _ in {1..90}; do
	if ssh "${ssh_opts[@]}" "$image_user@$host_address" true >/dev/null 2>&1; then
		ready=true
		break
	fi
	sleep 2
done
$ready || {
	printf '%s\n' 'Build VM did not become reachable over SSH' >&2
	exit 1
}

printf '%s\n' 'Provisioning and accepting the guest...'
# The keymap the acceptance seeds is a test value, distinguishable from the
# other two axes; the seal below replaces all three.
# shellcheck disable=SC2029
ssh "${ssh_opts[@]}" "$image_user@$host_address" "CONSOLE_KEYMAP='es' bash -s" \
	>"$run/guest-accept.log" 2>&1 <"$repo_root/tests/guest-acceptance.sh" || {
	tail -n 60 "$run/guest-accept.log" >&2
	printf '%s\n' 'Guest acceptance failed; nothing was sealed' >&2
	exit 1
}
grep -Fq 'VM_ACCEPTANCE: PASS' "$run/guest-accept.log"
printf '%s\n' 'Guest acceptance: passed'

printf '%s\n' 'Sealing...'
# shellcheck disable=SC2029
ssh "${ssh_opts[@]}" "$image_user@$host_address" \
	"IMAGE_LOCALE='$image_locale' IMAGE_KEYMAP='$image_keymap' IMAGE_LAYOUT='$image_layout' IMAGE_USER='$image_user' bash -s" \
	>"$run/guest-seal.log" 2>&1 <"$repo_root/scripts/seal-vm-image.sh" || {
	tail -n 60 "$run/guest-seal.log" >&2
	printf '%s\n' 'Seal failed; the overlay is not publishable' >&2
	exit 1
}
grep -Fq 'IMAGE_SEAL: DONE' "$run/guest-seal.log"

ssh "${ssh_opts[@]}" "$image_user@$host_address" 'sudo systemctl poweroff' >/dev/null 2>&1 || true
for _ in {1..60}; do
	kill -0 "$qemu_pid" 2>/dev/null || break
	sleep 2
done
kill -0 "$qemu_pid" 2>/dev/null && {
	printf '%s\n' 'Guest did not power off cleanly' >&2
	exit 1
}

artifact="$output_dir/vivac.qcow2"
printf '%s\n' 'Flattening the overlay into a standalone image...'
qemu-img convert -O qcow2 -c "$run/build.qcow2" "$artifact.part"
mv -- "$artifact.part" "$artifact"
qemu-img check -q "$artifact"

size_bytes="$(stat -c %s "$artifact")"
printf 'Image built: %s (%s)\n' "$artifact" "$(numfmt --to=iec --suffix=B "$size_bytes")"
