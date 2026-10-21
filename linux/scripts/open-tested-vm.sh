#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
run="${VM_WORKDIR:-$repo_root/.vm-test}/run"
pidfile="$run/qemu.pid"

if [[ "${1:-}" == --stop ]]; then
	if [[ -f "$pidfile" ]] && kill -0 "$(<"$pidfile")" 2>/dev/null; then
		kill "$(<"$pidfile")"
		printf '%s\n' 'Tested VM stopped'
	else
		printf '%s\n' 'Tested VM is not running'
	fi
	exit 0
fi
[[ $# -eq 0 ]] || {
	printf 'Usage: %s [--stop]\n' "$0" >&2
	exit 2
}

for file in system.qcow2 seed.iso repository.iso id_ed25519; do
	[[ -f "$run/$file" ]] || {
		printf 'Missing tested VM artifact: %s; run scripts/test-vm.sh --keep first\n' "$file" >&2
		exit 1
	}
done
# Refresh the guest's repository copy so the opened VM runs the current tree,
# not the tree that was present when the overlay was accepted.
# shellcheck source=lib/repository-iso.sh
source "$repo_root/lib/repository-iso.sh"
repository_iso "$repo_root" "$run"
bash "$repo_root/scripts/vm-desktop.sh"
bash "$repo_root/scripts/vm-keyboard.sh"
if [[ -f "$pidfile" ]] && kill -0 "$(<"$pidfile")" 2>/dev/null; then
	printf '%s\n' 'Tested VM is already running'
	exit 0
fi

host_address="$(printf '%d.%d.%d.%d' 127 0 0 1)"
console_keymap="${VM_CONSOLE_KEYMAP:-es}"
[[ "$console_keymap" =~ ^[A-Za-z0-9_-]+$ ]] || {
	printf 'Invalid console keymap name: %s\n' "$console_keymap" >&2
	exit 2
}
port="${VM_SSH_PORT:-$(python -c 'import socket; s=socket.socket(); s.bind(("localhost", 0)); print(s.getsockname()[1]); s.close()')}"
memory="${VM_MEMORY_MB:-8192}"
cpus="${VM_CPUS:-4}"
rm -f -- "$pidfile" "$run/qga.sock"

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
	-display gtk,full-screen=on -device virtio-vga -device qemu-xhci -device usb-tablet -daemonize -pidfile "$pidfile" \
	-serial "file:$run/interactive-serial.log"

ssh_opts=(-i "$run/id_ed25519" -p "$port" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5)
ready=false
for _ in {1..90}; do
	if ssh "${ssh_opts[@]}" "vivac@$host_address" true >/dev/null 2>&1; then ready=true; break; fi
	sleep 2
done
$ready || {
	printf '%s\n' 'Interactive VM did not become reachable' >&2
	exit 1
}

# Validated keymap is intentionally expanded client-side.
# shellcheck disable=SC2029
ssh "${ssh_opts[@]}" "vivac@$host_address" "LC_ALL=C localectl list-keymaps | grep -Fxq -- '$console_keymap'"
# The validated keymap is intentionally expanded client-side.
# shellcheck disable=SC2029
ssh "${ssh_opts[@]}" "vivac@$host_address" "CONSOLE_KEYMAP='$console_keymap' bash -s" <<'GUEST'
set -Eeuo pipefail
sudo mkdir -p /mnt/vivac
mountpoint -q /mnt/vivac || sudo mount -L VIVAC -o ro /mnt/vivac
# The desktop this script deployed the last time round is running, and stow
# left ~/.config/hypr pointing into the tree that is about to be replaced.
# Hyprland writes a default configuration back the moment its own disappears,
# so it refilled the directory while the removal was still walking it and the
# removal failed on a directory that was never empty -- leaving the guest
# running Hyprland's defaults rather than this project's. The session is asked
# to stop first; the reboot at the end of this script brings it back on the
# tree that replaces it.
sudo systemctl stop greetd.service 2>/dev/null || true
for _ in $(seq 15); do
  pgrep -x Hyprland >/dev/null || break
  sleep 1
done
# Extract into an empty directory, never over the previous one: tar restores
# what the disc carries but removes nothing, so a file deleted in the tree
# survived in the guest -- and the gates, which check the tree rather than the
# disc, then failed over an asset that no longer exists here.
rm -rf -- "$HOME/vivac"
mkdir -p "$HOME/vivac"
tar -xzf /mnt/vivac/repository.tar.gz -C "$HOME/vivac"
cd "$HOME/vivac"
# A stopped VM can leave a stale pacman lock behind; only clear it when no pacman runs.
if [ -e /var/lib/pacman/db.lck ] && ! pgrep -x pacman >/dev/null; then
  sudo rm -f /var/lib/pacman/db.lck
fi
# The console keymap is a setting; its one writer is apply-system.sh --keymap.
mkdir -p "$HOME/.config/vivac"
if ! grep -q '^keymap=' "$HOME/.config/vivac/settings" 2>/dev/null; then
  printf 'keymap=%s\n' "$CONSOLE_KEYMAP" >>"$HOME/.config/vivac/settings"
fi
./scripts/bootstrap.sh --noconfirm --desktop-login --vm
./scripts/apply-system.sh --desktop-login --vm --keymap
GUEST
# Enabling greetd starts a graphical session for the same user this script logs
# in as. For a moment after that, a fresh SSH login for that user is closed from
# the other side while logind brings the session up, and the very next command
# here is what walks into it. Waited out with the same bounded loop the boot
# uses, never retried blindly: a guest that has really gone away still fails.
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

printf 'Interactive tested VM is running; the desktop logs in by itself. Details: %s\n' "$run/console-login.txt"
printf 'Stop it with: %s --stop\n' "$repo_root/scripts/open-tested-vm.sh"
