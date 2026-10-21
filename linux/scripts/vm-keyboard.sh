#!/usr/bin/env bash
# Session-only host bindings for driving the graphical test VM.
# Never rewrites the host configuration; a Hyprland reload clears it.
#
# One key toggles keyboard ownership. Outside the submap the host owns its
# shortcuts as usual; inside it, every key except the toggle reaches QEMU.
# Ctrl+Alt+Fn is handled by the compositor before any user bind on both sides,
# so the toggle must live outside that range and the guest console must be
# switched from inside the guest (chvt), never with Ctrl+Alt+Fn.
set -Eeuo pipefail
command -v hyprctl >/dev/null || exit 0
[[ -n "${HYPRLAND_INSTANCE_SIGNATURE:-}" ]] || exit 0

submap="vivac-vm"
toggle_key="${VM_TOGGLE_KEY:-Home}"
[[ "$toggle_key" =~ ^[A-Za-z0-9_]+$ ]] || {
	printf 'Invalid toggle key name: %s\n' "$toggle_key" >&2
	exit 2
}
notify() {
	command -v notify-send >/dev/null || return 0
	notify-send -a "$submap" -t 2500 "$@"
}
case "${1:-}" in
--entered)
	notify "Guest keyboard" "Keys go to the VM. Ctrl+Alt+$toggle_key returns to the host."
	exit 0
	;;
--left)
	notify "Host keyboard" "Host shortcuts restored."
	exit 0
	;;
esac

# Idempotent: a second run must not stack duplicate bindings.
if hyprctl -j binds | python -c '
import json, sys
submap, key = sys.argv[1:3]
binds = json.load(sys.stdin)
sys.exit(0 if any(b["submap"] == submap and b["key"] == key for b in binds) else 1)
' "$submap" "$toggle_key"; then
	printf 'VM keyboard toggle already active: Ctrl+Alt+%s\n' "$toggle_key"
	exit 0
fi

self="$(realpath "${BASH_SOURCE[0]}")"
if [[ "$(hyprctl eval 'return true' 2>&1)" == ok ]]; then
	hyprctl eval "
local key = 'CTRL + ALT + $toggle_key'
hl.bind(key, hl.dsp.submap('$submap'))
hl.bind(key, hl.dsp.exec_cmd('$self --entered'))
hl.define_submap('$submap', function()
  hl.bind(key, hl.dsp.submap('reset'))
  hl.bind(key, hl.dsp.exec_cmd('$self --left'))
end)
" >/dev/null
else
	hyprctl --batch "\
keyword bind CTRL ALT, $toggle_key, submap, $submap; \
keyword bind CTRL ALT, $toggle_key, exec, $self --entered; \
keyword submap $submap; \
keyword bind CTRL ALT, $toggle_key, submap, reset; \
keyword bind CTRL ALT, $toggle_key, exec, $self --left; \
keyword submap reset" >/dev/null
fi
printf 'Focus QEMU, then Ctrl+Alt+%s toggles between host and guest keyboard.\n' "$toggle_key"
printf '%s\n' 'Ctrl+Alt+Fn always belongs to the host; switch guest consoles with chvt.'
