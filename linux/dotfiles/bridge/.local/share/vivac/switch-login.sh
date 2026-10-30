# Sourced from the login profile (~/.bash_profile): after a switch from
# Windows, the automatic sign-in on tty1 goes straight on into the desktop,
# once. Any other sign-in goes on as before.
# shellcheck shell=bash
vivac_handover="${VIVAC_SWITCH_HANDOVER:-/run/vivac/handover-$(id -un)}"
if [[ -z "${WAYLAND_DISPLAY:-}" && "${VIVAC_TTY:-$(tty 2>/dev/null)}" == /dev/tty1 && -O "$vivac_handover/desktop-once" ]] &&
	rm -f -- "$vivac_handover/desktop-once" && command -v start-hyprland >/dev/null; then
	unset vivac_handover
	exec start-hyprland
fi
unset vivac_handover
