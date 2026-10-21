#!/usr/bin/env bash
set -Eeuo pipefail

# Boot the published image the way it is meant to be met: a window, a greeter,
# the published credentials. This exists because the flags matter and the ones
# that look most modern are the ones that break.
#
# In particular the GTK display is used WITHOUT OpenGL. With `gl=on` QEMU hands
# the guest's cursor to the host through the GL path, which uploads it with the
# framebuffer's Y convention and draws it upside down — a second, inverted
# pointer riding on top of the real one. Nothing in the guest causes it and
# nothing in the guest can fix it; the compositor already asks for software
# cursors on virtual machines. The cure is to not take that path.
#
#   --image PATH   default dist/vivac.qcow2
#   --memory MB    default 4096
#   --cpus N       default 4
#   --persist      write to the image instead of a throwaway overlay
#   --gl           opt back into OpenGL, inverted cursor and all
#
# Without --persist every change is discarded at shutdown, so the image can be
# explored and broken as often as you like.

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
image="$repo_root/dist/vivac.qcow2"
memory=4096
cpus=4
persist=false
gl=false

while (($#)); do
	case "$1" in
	--image)
		image="${2:?--image needs a path}"
		shift
		;;
	--memory)
		memory="${2:?--memory needs a number}"
		shift
		;;
	--cpus)
		cpus="${2:?--cpus needs a number}"
		shift
		;;
	--persist) persist=true ;;
	--gl) gl=true ;;
	-h | --help)
		sed -n '4,22p' "${BASH_SOURCE[0]}" | sed 's/^# \?//'
		exit 0
		;;
	*)
		printf 'Unknown option: %s\n' "$1" >&2
		exit 2
		;;
	esac
	shift
done

command -v qemu-system-x86_64 >/dev/null || {
	printf 'Missing host dependency: qemu-system-x86_64\n' >&2
	exit 1
}
[[ -f "$image" ]] || {
	printf 'No image at %s; run scripts/build-vm-image.sh first\n' "$image" >&2
	exit 1
}
format="$(qemu-img info --output=json "$image" | python -c 'import json,sys; print(json.load(sys.stdin)["format"])')"

# Quoted one by one: several of these values contain commas, and an unquoted
# comma inside an array literal reads as a typo to every linter and to every
# reader after them.
args=(
	-enable-kvm
	-machine 'q35,accel=kvm'
	-cpu host
	-smp "$cpus"
	-m "$memory"
	-drive "if=virtio,format=$format,file=$image"
	-netdev 'user,id=net0'
	-device 'virtio-net-pci,netdev=net0'
)
$persist || args+=(-snapshot)
if $gl; then
	args+=(-device virtio-vga-gl -display 'gtk,gl=on')
else
	args+=(-device virtio-vga -display 'gtk,gl=off')
fi

printf 'Booting %s — log in as user / user (root is root / toor).\n' "$(basename -- "$image")"
$persist || printf 'Every change is discarded on shutdown; pass --persist to keep them.\n'
exec qemu-system-x86_64 "${args[@]}"
