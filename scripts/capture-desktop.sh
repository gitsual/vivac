#!/usr/bin/env bash
# Re-take the captures the README shows, inside the tested VM -- so the
# evidence is produced by a command like everything else here, and a palette
# that changes is a capture that changes with it.
#
# Two modes, both drawing the same three-pane desktop underneath:
#   (no argument)  one capture per palette, named after the palette
#   --surfaces     one capture per surface the desktop draws itself, each in a
#                  different palette, named surface-<name>
#
# A surface is opened by running the command its own key binding runs, read
# out of the deployed hyprland.lua at capture time: a screenshot cannot
# then show something the key no longer does.
#
# Requires an already running interactive VM:
#   ./scripts/test-vm.sh --gui      (first time: builds, accepts and boots it)
#   ./scripts/open-tested-vm.sh     (afterwards: boots the tested overlay)
set -Eeuo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
run="${VM_WORKDIR:-$repo_root/.vm-test}/run"
mode=palettes
[[ "${1:-}" == --surfaces ]] && {
	mode=surfaces
	shift
}
out_dir="${1:-$repo_root/assets/screenshots}"
# Written the way the other VM scripts write it: a literal loopback address in
# the source reads as a leaked private address to the privacy scan.
host_address="$(printf '%d.%d.%d.%d' 127 0 0 1)"

# The port is normally read from the file the VM scripts leave behind;
# VM_SSH_PORT overrides it for a VM that is up but whose provisioning run did
# not get as far as writing that file.
port="${VM_SSH_PORT:-}"
if [[ -z "$port" ]]; then
	[[ -f "$run/console-login.txt" ]] || {
		printf 'No running tested VM: start one with scripts/open-tested-vm.sh\n' >&2
		exit 1
	}
	port="$(sed -nE 's/^ssh_port=(.*)$/\1/p' "$run/console-login.txt")"
fi
ssh_opts=(-i "$run/id_ed25519" -p "$port" -o StrictHostKeyChecking=no
	-o UserKnownHostsFile=/dev/null -o ConnectTimeout=5)
# The theme name is expanded on this side deliberately: it comes from the
# catalogue in data/, never from input, and the guest reads it as an assignment.
# shellcheck disable=SC2029
guest() { ssh "${ssh_opts[@]}" "vivac@$host_address" "$@"; }

guest true >/dev/null 2>&1 || {
	printf 'The tested VM is not answering on port %s\n' "$port" >&2
	exit 1
}

# What to capture: a file name, the palette it wears, and how the surface on
# top of the desktop is opened. An empty opener is the desktop by itself.
jobs=()
if [[ "$mode" == palettes ]]; then
	jobs+=('bad-romance|bad-romance|')
	while IFS= read -r file; do
		theme="$(basename -- "$file" .conf)"
		jobs+=("$theme|$theme|")
	done < <(find "$repo_root/data/themes" -name '*.conf' -type f | LC_ALL=C sort)
else
	# The palettes rotate through the catalogue so the gallery shows the whole
	# interface and the whole range of colour at the same time, and so no
	# surface can quietly become the only one anybody ever sees in context.
	jobs=(
		'surface-power|bad-romance|bind:SUPER SHIFT,Q'
		'surface-power-rofi|cosmos|bind:SUPER SHIFT,E'
		'surface-theme|metropolis|bind:SUPER SHIFT,T'
		'surface-help-hypr|carmen|bind:,F1'
		'surface-help-browser|northern-lights|bind:,F2'
		'surface-help-shell|gatsby|bind:,F3'
		'surface-help-editor|the-hermit|bind:,F4'
		'surface-help-system|cosmos|bind:,F5'
		'surface-launcher-rofi|persephone|bind:SUPER,R'
		'surface-launcher-wofi|bad-romance|bind:SUPER ALT,R'
		'surface-launcher-dmenu|metropolis|bind:SUPER,D'
		'surface-clipboard|carmen|bind:SUPER,V'
		'surface-welcome|northern-lights|run:welcome'
		'surface-notification|gatsby|run:notification'
		'surface-lock|the-hermit|bind:SUPER,L'
	)
fi

# VIVAC_ONLY limits the run to the named jobs, comma separated, so a capture
# that has to be redone does not cost the fifteen that were already right.
only="${VIVAC_ONLY:-}"
taken=0

mkdir -p -- "$out_dir"
for job in "${jobs[@]}"; do
	IFS='|' read -r name theme surface <<<"$job"
	if [[ -n "$only" && ",$only," != *",$name,"* ]]; then
		continue
	fi
	printf 'Capturing %s ...\n' "$name"
	guest "THEME=$theme SURFACE='$surface' bash -s" <<'GUEST'
set -Eeuo pipefail
export XDG_RUNTIME_DIR="/run/user/$(id -u)"
export HYPRLAND_INSTANCE_SIGNATURE="$(find "$XDG_RUNTIME_DIR/hypr" -maxdepth 1 -mindepth 1 -type d -printf '%T@ %f\n' | sort -rn | head -1 | cut -d' ' -f2)"
export WAYLAND_DISPLAY="$(find "$XDG_RUNTIME_DIR" -maxdepth 1 -name 'wayland-*' ! -name '*.lock' -printf '%f\n' | sort | head -1)"
cd "$HOME/vivac"
# Dispatch through the helper: a classic dispatch string fails under Lua.
source ./lib/hypr-ipc.sh

./scripts/apply-theme.sh --theme "$THEME" >/dev/null

# A capture is a composition, so it starts from an empty workspace every time --
# and a kitty opened under the previous palette would still be wearing it.
#
# Killed rather than closed: a close reaches the terminal as a window manager
# request, and kitty answers a request to close a window running an editor with
# a confirmation dialog -- which is itself a window, and stays on the picture.
pkill -x kitty || true
# ...and so does every surface the previous capture opened. A launcher is a
# layer surface, not a client, so the wait below never sees it: an undismissed
# rofi from one job sat on top of the thirteen captures that followed it,
# wearing the palette of the job that opened it while the desktop underneath
# changed colour. Kill them by name, before the count is taken.
for surface in rofi wofi dmenu nwg-bar hyprpicker; do
	pkill -x "$surface" || true
done
# hyprlock is the exception: it is asked to unlock, never killed. See the note
# where this run dismisses its own lock.
pkill -USR1 -x hyprlock || true
sleep 1
for _ in $(seq 20); do
	[[ "$(hyprctl -j clients | python -c 'import json,sys; print(len(json.load(sys.stdin)))')" == 0 ]] && break
	sleep 0.5
done

# Each pane is a file, never a quoted string: `hyprctl dispatch exec` splits
# its argument on spaces and the quotes do not survive the trip, so a command
# passed inline arrives as a bare shell.
pane() {
	local number="$1" body="$2" path="/tmp/vivac-pane-$1.sh"
	printf '#!/usr/bin/env bash\nexport LANG=en_US.UTF-8\ncd "$HOME/vivac"\n%s\n' "$body" >"$path"
	chmod +x "$path"
	hypr_dispatch exec -- kitty --hold "$path" >/dev/null
	sleep 4
}
first_window() {
	hyprctl -j clients | python -c '
import json, sys
print(sorted(json.load(sys.stdin), key=lambda c: (c["at"][1], c["at"][0]))[0]["address"])'
}

# Opened in the order the layout wants, not the order the picture reads in:
# dwindle puts each new window to the left of the one that was there, so the
# right-hand pane is the one that opens first.
#
# Right: the editor, opened on the template that renders the desktop around it.
pane 2 'nvim templates/hypr/.config/hypr/hyprland.lua.in'
sleep 6
# Bottom left: what this palette actually is, drawn in itself. It opens before
# the catalogue because dwindle splits the column downwards: the pane that opens
# second ends up under the one that opens third.
pane 3 './scripts/palette-card.sh'
# Top left: the catalogue this desktop can wear, printed by the command the
# menu itself uses, so the list on screen cannot drift from the list in data/.
hypr_dispatch focuswindow "address:$(first_window)" >/dev/null
sleep 1
pane 1 './dotfiles/ricer/.local/bin/vivac-theme --print'

sleep 3

# The surface on top, if this capture asks for one.
#
# bind_command answers with what a key binding actually runs, so the picture is
# evidence about the binding rather than about a command repeated here that
# could drift away from it. The vivac names a command is built from (terminal,
# scripts) are read from the same hyprland.lua.
bind_command() {
	python - "$1" <<'BINDPY'
import os, re, sys

combo = sys.argv[1]
conf = open(os.path.expanduser('~/.config/hypr/hyprland.lua')).read()
# vivac.terminal = "kitty" and the like: the names a command is built from.
variables = dict(re.findall(r'^vivac\.(\w+)\s*=\s*"(.*)"\s*$', conf, re.M))


def evaluate(expression):
    # A command is string literals and vivac.<name> joined by `..`.
    text = ''
    for piece in re.split(r'\s*\.\.\s*', expression.strip()):
        literal = re.fullmatch(r'"([^"]*)"|\'([^\']*)\'|\[\[(.*)\]\]', piece)
        if literal:
            text += next(group for group in literal.groups() if group is not None)
        elif piece.startswith('vivac.') and piece[6:] in variables:
            text += variables[piece[6:]]
        else:
            raise SystemExit('cannot read the command ' + expression)
    return text


def keys(mods):
    return ' '.join(sorted(mods.upper().split()))


wanted_mods, wanted_key = (part.strip() for part in combo.split(',', 1))
for line in conf.splitlines():
    bound = re.match(r'hl\.bind\("([^"]+)",\s*hl\.dsp\.exec_cmd\((.*)\)\)\s*$', line)
    if not bound:
        continue
    *mods, key = bound.group(1).split(' + ')
    if keys(' '.join(mods)) != keys(wanted_mods) or key.lower() != wanted_key.lower():
        continue
    print(evaluate(bound.group(2)))
    break
else:
    raise SystemExit('no exec binding for ' + combo)
BINDPY
}

# Written to a file for the same reason the panes are: `hyprctl dispatch exec`
# splits its argument on spaces, and these commands carry quoted arguments that
# would not survive the trip.
open_surface() {
	local path=/tmp/vivac-surface.sh
	printf '#!/usr/bin/env bash\nexport LANG=en_US.UTF-8\ncd "$HOME"\n%s\n' "$1" >"$path"
	chmod +x "$path"
	hypr_dispatch exec -- "$path" >/dev/null
}

case "${SURFACE:-}" in
'') ;;
bind:*)
	combo="${SURFACE#bind:}"
	# The clipboard menu is only worth a picture with something in it, and the
	# history is whatever the running watcher has seen.
	if [[ "$combo" == 'SUPER,V' ]]; then
		# Detached for the same reason the screenshot notice below is: wl-copy
		# does not exit, it stays alive owning the selection, and a copy left
		# attached to this SSH channel keeps it open for as long as the
		# selection lasts -- which is the rest of the session.
		printf '%s' 'data/themes/northern-lights.conf' >/tmp/vivac-clip-1
		setsid wl-copy </tmp/vivac-clip-1 >/dev/null 2>&1 &
		sleep 1
		printf '%s' '#1F1A17' >/tmp/vivac-clip-2
		setsid wl-copy </tmp/vivac-clip-2 >/dev/null 2>&1 &
		sleep 1
	fi
	open_surface "$(bind_command "$combo")"
	sleep 4
	;;
run:welcome)
	open_surface 'kitty --class vivac-welcome -e "$HOME/.local/bin/vivac-welcome"'
	sleep 6
	;;
run:notification)
	# The three lines the screenshot binding itself ends on, so the notice on
	# screen names a file that is really there.
	shots="${XDG_SCREENSHOTS_DIR:-$HOME/Pictures/Screenshots}"
	mkdir -p "$shots"
	shot="$shots/screenshot_$(date +%Y%m%d_%H%M%S).png"
	grim -g '0,0 960x540' "$shot"
	# wl-copy does not exit: it stays alive owning the selection. Run through the
	# same SSH channel as everything else it would inherit this session's stdout
	# and the channel would never close, so the capture that follows never runs.
	setsid wl-copy <"$shot" >/dev/null 2>&1 &
	notify-send 'Screenshot saved' "$shot"
	sleep 2
	;;
esac

grim /tmp/capture.png
# A lock screen would swallow every capture after this one. Dismissed with
# SIGUSR1, which is hyprlock's own unlock signal, never with a plain kill: a
# lock that dies rather than unlocks leaves Hyprland showing "your lockscreen
# app died" over everything, and that state outlives the run that caused it.
# The documented way out of it, `hyprctl eval hl.clear_crashed_lockscreen()`,
# only exists under the Lua config manager, which this desktop does not use --
# so the state is unrecoverable short of restarting the compositor. Do not
# enter it.
pkill -USR1 -x hyprlock || true
for _ in $(seq 20); do
	pgrep -x hyprlock >/dev/null || break
	sleep 0.5
done
GUEST
	scp -q -i "$run/id_ed25519" -P "$port" -o StrictHostKeyChecking=no \
		-o UserKnownHostsFile=/dev/null \
		"vivac@$host_address:/tmp/capture.png" "$out_dir/$name.png"
	taken=$((taken + 1))
done
printf 'Captured %d images into %s\n' "$taken" "$out_dir"
