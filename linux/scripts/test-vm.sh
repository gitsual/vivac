#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
work_root="${VM_WORKDIR:-$repo_root/.vm-test}"
cache="$work_root/cache"
run="$work_root/run"
image_url="${ARCH_VM_IMAGE_URL:-https://geo.mirror.pkgbuild.com/images/latest/Arch-Linux-x86_64-cloudimg.qcow2}"
keep=false
gui=false
console_keymap="${VM_CONSOLE_KEYMAP:-es}"
[[ "$console_keymap" =~ ^[A-Za-z0-9_-]+$ ]] || {
	printf 'Invalid console keymap name: %s\n' "$console_keymap" >&2
	exit 2
}

usage() {
	cat <<'USAGE'
Usage: scripts/test-vm.sh [--keep] [--gui]

Build and test the current repository in an official Arch cloud-image VM.
  --keep  Preserve the overlay, logs and seed media after the test
  --gui   Open a QEMU window and keep the tested VM running for manual use

Overrides: VM_WORKDIR, ARCH_VM_IMAGE_URL, VM_MEMORY_MB, VM_CPUS, VM_SSH_PORT,
VM_CONSOLE_KEYMAP (defaults to es).
No host packages, services, firewall rules or user configuration are changed.
USAGE
}

while (($#)); do
	case "$1" in
	--keep) keep=true ;;
	--gui) gui=true; keep=true ;;
	-h | --help) usage; exit 0 ;;
	*) printf 'Unknown option: %s\n' "$1" >&2; exit 2 ;;
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

mkdir -p -- "$cache" "$work_root"
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

ssh-keygen -q -t ed25519 -N '' -f "$run/id_ed25519"
public_key="$(<"$run/id_ed25519.pub")"
cat >"$run/meta-data" <<'META'
instance-id: vivac-vm
local-hostname: vivac
META
cat >"$run/user-data" <<USERDATA
#cloud-config
users:
  - name: vivac
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
qemu-img create -q -f qcow2 -F qcow2 -b "$base" "$run/system.qcow2" 32G

port="${VM_SSH_PORT:-}"
host_address="$(printf '%d.%d.%d.%d' 127 0 0 1)"
if [[ -z "$port" ]]; then
	port="$(python -c 'import socket; s=socket.socket(); s.bind(("localhost", 0)); print(s.getsockname()[1]); s.close()')"
fi
memory="${VM_MEMORY_MB:-8192}"
cpus="${VM_CPUS:-4}"
# The guest always carries the virtio GPU, headless or not: the catalogue's
# virtio row is "verified in the VM gate" only if the gate actually runs on
# it (QEMU's default Bochs VGA resolves to the generic Mesa row).
display_args=(-display none -device virtio-vga)
$gui && display_args=(-display "gtk,full-screen=on" -device virtio-vga -device qemu-xhci -device usb-tablet)

$gui && bash "$repo_root/scripts/vm-desktop.sh"
qemu-system-x86_64 \
	-enable-kvm -machine q35,accel=kvm -cpu host \
	-smp "$cpus" -m "$memory" \
	-drive "if=virtio,format=qcow2,file=$run/system.qcow2" \
	-drive "media=cdrom,readonly=on,file=$run/seed.iso" \
	-drive "media=cdrom,readonly=on,file=$run/repository.iso" \
	-netdev "user,id=net0,hostfwd=tcp:$host_address:$port-:22" \
	-device virtio-net-pci,netdev=net0 \
	-device virtio-serial-pci -chardev spicevmc,id=vdagent,name=vdagent \
	-device virtserialport,chardev=vdagent,name=com.redhat.spice.0 \
	-chardev "socket,path=$run/qga.sock,server=on,wait=off,id=qga0" \
	-device virtserialport,chardev=qga0,name=org.qemu.guest_agent.0 \
	"${display_args[@]}" -daemonize -pidfile "$run/qemu.pid" \
	-serial "file:$run/serial.log"

stop_vm() {
	if [[ -f "$run/qemu.pid" ]]; then
		pid="$(<"$run/qemu.pid")"
		kill "$pid" 2>/dev/null || true
	fi
}
cleanup() {
	status=$?
	if ! $gui; then stop_vm; fi
	if ((status == 0)) && ! $keep; then rm -rf -- "$run"; fi
	if ((status != 0)); then
		printf 'VM test failed; evidence kept in %s\n' "$run" >&2
	fi
}
trap cleanup EXIT

ssh_opts=(-i "$run/id_ed25519" -p "$port" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5)
ready=false
for _ in {1..90}; do
	if ssh "${ssh_opts[@]}" "vivac@$host_address" true >/dev/null 2>&1; then ready=true; break; fi
	sleep 2
done
$ready || {
	printf '%s\n' 'VM did not become reachable over SSH' >&2
	exit 1
}

# The validated keymap is intentionally expanded client-side.
# shellcheck disable=SC2029
if ! ssh "${ssh_opts[@]}" "vivac@$host_address" "CONSOLE_KEYMAP='$console_keymap' bash -s" >"$run/guest-test.log" 2>&1 <"$repo_root/tests/guest-acceptance.sh"; then
	python - "$run/guest-test.log" <<'PY'
import sys
from pathlib import Path
lines = Path(sys.argv[1]).read_text(errors="replace").splitlines()
print("\n".join(lines[-120:]), file=sys.stderr)
PY
	exit 1
fi

grep -Fq 'VM_ACCEPTANCE: PASS' "$run/guest-test.log"
printf 'Arch VM acceptance: passed (KVM, %s MiB, %s vCPU, SSH port %s)\n' "$memory" "$cpus" "$port"

if $gui; then
	# The console keymap was written by apply-system.sh --keymap during the
	# acceptance run, from the settings file seeded above.
	ssh "${ssh_opts[@]}" "vivac@$host_address" 'cd "$HOME/vivac" && ./scripts/apply-system.sh --desktop-login --vm'
	# Enabling greetd starts a graphical session for the same user this script
	# logs in as. For a moment after that, a fresh SSH login for that user is
	# closed from the other side while logind brings the session up, and the
	# very next command here is what walks into it. Waited out with the same
	# bounded loop the boot uses, never retried blindly: a guest that has
	# really gone away still fails the run.
	settled=false
	for _ in {1..30}; do
		if ssh "${ssh_opts[@]}" "vivac@$host_address" true >/dev/null 2>&1; then
			settled=true
			break
		fi
		sleep 2
	done
	$settled || {
		printf 'The guest stopped answering after the desktop login was enabled\n' >&2
		exit 1
	}
	# Validated keymap is intentionally expanded client-side.
	# shellcheck disable=SC2029
	ssh "${ssh_opts[@]}" "vivac@$host_address" "grep -Fxq -- 'KEYMAP=$console_keymap' /etc/vconsole.conf"
	printf 'ssh_port=%s\nconsole_keymap=%s\n' "$port" "$console_keymap" >"$run/console-login.txt"
	ssh "${ssh_opts[@]}" "vivac@$host_address" 'sudo systemctl reboot' || true
	bash "$repo_root/scripts/vm-keyboard.sh"
	printf 'Interactive VM kept running; the desktop logs in by itself. Details: %s\n' "$run/console-login.txt"
	printf 'SSH: ssh -i %s -p %s vivac@%s\n' "$run/id_ed25519" "$port" "$host_address"
elif $keep; then
	printf 'VM artifacts kept at %s\n' "$run"
fi
