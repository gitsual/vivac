#!/usr/bin/env bash
set -Eeuo pipefail

# Every place that used to call `hyprctl dispatch` goes through lib/hypr-ipc.sh:
# help-pane, the waybar workspace scroll, hypridle, both power menus, and the two
# capture scripts. A classic dispatch string fails under a Lua compositor, so a
# direct call left behind is a feature that dies silently on the Lua port.

repo_root="${REPO_ROOT:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)}"
stub_bin="$repo_root/tests/data/hypr-ipc/bin"
sandbox="$(mktemp -d "${TMPDIR:-/tmp}/vivac-hyprcallers.XXXXXX")"
trap 'rm -rf -- "$sandbox"' EXIT

fail() {
	printf '%s\n' "$1" >&2
	exit 1
}

# --- static: no direct dispatch, no exec_raw -------------------------------------------------------------------
# Comment lines may talk about `hyprctl dispatch exec`; code may not run it.
direct="$(cd "$repo_root" && grep -rInE 'hyprctl[[:space:]]+dispatch' lib scripts dotfiles render templates data |
	grep -v '^lib/hypr-ipc\.sh:' | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#' || true)"
[[ -z "$direct" ]] || fail "direct 'hyprctl dispatch' left in the sources:
$direct"
raw="$(cd "$repo_root" && grep -rIn 'exec_raw' lib scripts dotfiles data | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#' || true)"
[[ -z "$raw" ]] || fail "hl.dsp.exec_raw is used:
$raw"
# The two capture scripts run their choreography in the guest, from the checkout.
for script in capture-desktop record-demo; do
	grep -Fq 'source ./lib/hypr-ipc.sh' "$repo_root/scripts/$script.sh" || fail "$script.sh does not source the helper in the guest"
	grep -q 'hypr_dispatch' "$repo_root/scripts/$script.sh" || fail "$script.sh never dispatches"
done

# --- the wrapper the waybar and hypridle call ----------------------------------------------------------------------
wrapper="$repo_root/dotfiles/hypr/.config/hypr/scripts/dispatch.sh"
[[ -x "$wrapper" ]] || fail 'dotfiles/hypr/.config/hypr/scripts/dispatch.sh is missing or not executable'
export HYPR_STUB_DIR="$sandbox/stub"
mkdir -p "$HYPR_STUB_DIR" "$sandbox/stowed/.config/hypr/scripts"
unset HYPRLAND_INSTANCE_SIGNATURE VIVAC_HYPR_IPC_MODE
# Run the way Stow installs it: through a symlink, far from the checkout.
ln -s "$wrapper" "$sandbox/stowed/.config/hypr/scripts/dispatch.sh"
: >"$HYPR_STUB_DIR/calls"
PATH="$stub_bin:$PATH" VIVAC_HYPR_IPC_MODE=lua "$sandbox/stowed/.config/hypr/scripts/dispatch.sh" workspace e-1 || fail 'dispatch.sh failed through a symlink'
[[ "$(<"$HYPR_STUB_DIR/last_dispatch")" == 'hl.dsp.focus({ workspace = "e-1" })' ]] || fail 'dispatch.sh did not translate in Lua mode'
PATH="$stub_bin:$PATH" VIVAC_HYPR_IPC_MODE=classic "$wrapper" dpms off || fail 'dispatch.sh failed in classic mode'
[[ "$(<"$HYPR_STUB_DIR/last_dispatch")" == 'dpms off' ]] || fail 'dispatch.sh did not pass the classic call through'
rc=0
PATH="$stub_bin:$PATH" VIVAC_HYPR_IPC_MODE=lua "$wrapper" frobnicate 2>/dev/null || rc=$?
((rc == 2)) || fail 'dispatch.sh swallowed the rc 2 of an unknown dispatcher'

# --- the call sites, by content -------------------------------------------------------------------------------------
grep -Fq 'hypr/scripts/dispatch.sh workspace e-1' "$repo_root/render/waybar/config.in" || fail 'waybar scroll-up does not use the wrapper'
grep -Fq 'hypr/scripts/dispatch.sh workspace e+1' "$repo_root/render/waybar/config.in" || fail 'waybar scroll-down does not use the wrapper'
idle="$repo_root/dotfiles/hypr/.config/hypr/hypridle.conf"
[[ "$(grep -c 'hypr/scripts/dispatch.sh dpms on' "$idle")" == 2 ]] || fail 'hypridle: both dpms on calls must use the wrapper'
[[ "$(grep -c 'hypr/scripts/dispatch.sh dpms off' "$idle")" == 1 ]] || fail 'hypridle: the dpms off call must use the wrapper'
grep -Fq 'hypr/scripts/dispatch.sh' "$repo_root/dotfiles/rofi/.config/rofi/power/powermenu.sh" || fail 'the rofi power menu logs out directly'

# --- log out from both power menus when $HOME contains a space ---------------------------------------------------
# nwg-bar runs the "exec" string with exec.Command(strings.Split(cmd, " ")...):
# no shell, so no $HOME, no quotes, and a space in a path splits it in two; a "="
# starts an environment assignment and a "%" truncates the command
# (github.com/nwg-piotr/nwg-bar, tools.go launch()). The test replays exactly that.
spaced="$sandbox/with space"
mkdir -p "$spaced/.config/hypr/scripts" "$spaced/.local/bin" "$sandbox/run"
ln -s "$wrapper" "$spaced/.config/hypr/scripts/dispatch.sh"
logged_out() { [[ -f "$HYPR_STUB_DIR/last_dispatch" && "$(<"$HYPR_STUB_DIR/last_dispatch")" == 'hl.dsp.exit()' ]]; }

: >"$HYPR_STUB_DIR/calls"
rm -f -- "$HYPR_STUB_DIR/last_dispatch"
bar="$(VIVAC_REPO="$repo_root" HOME="$spaced" XDG_RUNTIME_DIR="$sandbox/run" "$repo_root/dotfiles/ricer/.local/bin/vivac-power" --lang en --print)"
logout_exec="$(python3 -c '
import json, sys
print([b["exec"] for b in json.loads(sys.stdin.read())][2])' <<<"$bar")"
[[ "$logout_exec" != *=* && "$logout_exec" != *%* && "$logout_exec" != *'$'* ]] || fail "the logout exec string is not safe for nwg-bar: $logout_exec"
IFS=' ' read -r -a nwg_argv <<<"$logout_exec"
[[ "${nwg_argv[0]}" == /* && -x "${nwg_argv[0]}" ]] || fail "nwg-bar would not find an executable in: $logout_exec"
PATH="$stub_bin:$PATH" VIVAC_HYPR_IPC_MODE=lua HOME="$spaced" "${nwg_argv[@]}" || fail 'the graphical logout failed with a space in HOME'
logged_out || fail 'the graphical logout did not dispatch exit with a space in HOME'

: >"$HYPR_STUB_DIR/calls"
rm -f -- "$HYPR_STUB_DIR/last_dispatch"
printf '#!/usr/bin/env bash\nprintf "%%s\\n" /nonexistent-icons\n' >"$spaced/.local/bin/vivac-power"
chmod +x "$spaced/.local/bin/vivac-power"
printf '#!/usr/bin/env bash\ncat >/dev/null\nprintf "2\\n"\n' >"$sandbox/bin-rofi-index"
mkdir -p "$sandbox/rofibin"
mv -- "$sandbox/bin-rofi-index" "$sandbox/rofibin/rofi"
chmod +x "$sandbox/rofibin/rofi"
PATH="$sandbox/rofibin:$stub_bin:$PATH" VIVAC_HYPR_IPC_MODE=lua VIVAC_REPO="$repo_root" HOME="$spaced" LANG=en_US.UTF-8 \
	bash "$repo_root/dotfiles/rofi/.config/rofi/power/powermenu.sh" || fail 'the rofi logout failed with a space in HOME'
logged_out || fail 'the rofi logout did not dispatch exit with a space in HOME'

# --- help-pane: activating a row dispatches in the session language of the compositor -------------------------
mkdir -p "$sandbox/bin"
cat >"$sandbox/bin/rofi" <<'ROFI'
#!/usr/bin/env bash
cat >/dev/null
printf '%s  chosen\n' "${PANE_PICK:?}"
ROFI
chmod +x "$sandbox/bin/rofi"
activate() { # activate MODE PICK
	: >"$HYPR_STUB_DIR/calls"
	rm -f -- "$HYPR_STUB_DIR/last_dispatch"
	PANE_PICK="$2" PATH="$sandbox/bin:$stub_bin:$PATH" VIVAC_HYPR_IPC_MODE="$1" HYPRLAND_INSTANCE_SIGNATURE='' \
		HELP_REPO_ROOT="$repo_root" bash "$repo_root/dotfiles/hypr/.config/hypr/scripts/help-pane.sh" --pane hypr --lang en ||
		fail "help-pane failed picking $2 in $1 mode"
}
activate lua SUPER+Q
[[ "$(<"$HYPR_STUB_DIR/last_dispatch")" == 'hl.dsp.window.close()' ]] || fail "dispatch row in Lua mode: $(<"$HYPR_STUB_DIR/calls")"
activate lua SUPER+bracketright
[[ "$(<"$HYPR_STUB_DIR/last_dispatch")" == 'hl.dsp.focus({ workspace = "e+1" })' ]] || fail 'workspace row in Lua mode'
activate lua SUPER+Return
grep -q '^dispatch hl.dsp.exec_cmd' "$HYPR_STUB_DIR/calls" || fail "exec row in Lua mode: $(<"$HYPR_STUB_DIR/calls")"
activate classic SUPER+Q
[[ "$(<"$HYPR_STUB_DIR/last_dispatch")" == killactive ]] || fail 'dispatch row in classic mode changed'
activate classic SUPER+Return
grep -q '^dispatch exec -- ' "$HYPR_STUB_DIR/calls" || fail "exec row in classic mode: $(<"$HYPR_STUB_DIR/calls")"

printf 'hypr callers: no direct dispatch, wrapper works from a symlink, help-pane/waybar/hypridle/power menus routed\n'
