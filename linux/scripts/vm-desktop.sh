#!/usr/bin/env bash
# Session-only host placement for the graphical test VM.
# Never rewrites the host configuration; a Hyprland reload clears it.
#
# Picks an empty host workspace, sends every QEMU window there and switches to
# it. QEMU itself runs full-screen (see the -display option in the VM scripts):
# a compositor-side fullscreen would be undone by the window resize QEMU
# performs when the guest changes resolution, and the GTK menu bar would eat
# part of the monitor.
set -Eeuo pipefail
command -v hyprctl >/dev/null || exit 0
[[ -n "${HYPRLAND_INSTANCE_SIGNATURE:-}" ]] || exit 0

workspace="${VM_HOST_WORKSPACE:-$(hyprctl -j workspaces | python -c '
import json, sys
used = {w["id"] for w in json.load(sys.stdin) if w["windows"]}
print(next(i for i in range(1, 11) if i not in used))
')}"
[[ "$workspace" =~ ^[0-9]+$ ]] || {
	printf 'Invalid host workspace: %s\n' "$workspace" >&2
	exit 2
}

if [[ "$(hyprctl eval 'return true' 2>&1)" == ok ]]; then
	# The rule handle lives in the config Lua state, so a second run updates the
	# existing rule instead of stacking another one; a reload clears both.
	hyprctl eval "
if _G.vivac_vm_rule then _G.vivac_vm_rule:set_enabled(false) end
_G.vivac_vm_rule = hl.window_rule({ name = 'vivac-vm-window', match = { class = '^(qemu.*)$' }, workspace = '$workspace' })
hl.dispatch(hl.dsp.focus({ workspace = $workspace }))
" >/dev/null
else
	hyprctl --batch "\
keyword windowrule workspace $workspace, match:class ^(qemu.*)$; \
dispatch workspace $workspace" >/dev/null
fi
printf 'QEMU windows open on host workspace %s.\n' "$workspace"
