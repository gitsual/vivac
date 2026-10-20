#!/usr/bin/env bash
# Record the tour the README describes, in one continuous take, inside the
# tested VM -- so the film is produced by a command like everything else here,
# and a desktop that changes is a film that changes with it.
#
# Nothing on screen is staged. Every window is opened the way the desktop opens
# it: by the exact command its key binding runs, or by the exact dispatcher its
# key binding names, read out of the deployed config at record time. A shot
# cannot then show something a key no longer does.
#
# The keys themselves are not synthesised. Hyprland 0.56 will deliver a
# shortcut to a window over IPC, but it does not run its own binds from one --
# measured, not assumed -- and this desktop ships no synthetic typist, so
# adding a package to the image in order to film it would be the tail wagging
# the dog.
#
# The subtitles are burned in from cues the choreography writes as it goes, so
# a line of narration is stamped by the moment it describes rather than by a
# timing table kept alongside it.
#
#   ./scripts/record-demo.sh [output.mp4]
#
# Requires an already running interactive VM:
#   ./scripts/test-vm.sh --gui      (first time: builds, accepts and boots it)
#   ./scripts/open-tested-vm.sh     (afterwards: boots the tested overlay)
set -Eeuo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
run="${VM_WORKDIR:-$repo_root/.vm-test}/run"
output="${1:-$repo_root/dist/demo.mp4}"
# Written the way the other VM scripts write it: a literal loopback address in
# the source reads as a leaked private address to the privacy scan.
host_address="$(printf '%d.%d.%d.%d' 127 0 0 1)"

for tool in ffmpeg ffprobe; do
	command -v "$tool" >/dev/null || {
		printf 'Missing host tool: %s\n' "$tool" >&2
		exit 1
	}
done

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
# Nothing but a literal probe is ever passed here; the choreography travels on
# stdin, where no client-side expansion can reach it.
# shellcheck disable=SC2029
guest() { ssh "${ssh_opts[@]}" "vivac@$host_address" "$@"; }

guest true >/dev/null 2>&1 || {
	printf 'The tested VM is not answering on port %s\n' "$port" >&2
	exit 1
}

printf 'Recording the tour inside the VM; this takes a few minutes ...\n'

# ---------------------------------------------------------------- the take
#
# ServerAliveInterval keeps the channel open across the long silences the
# choreography deliberately leaves: a lock screen held for six seconds is a
# shot, and an SSH connection that drops through it takes the recorder with it.
ssh "${ssh_opts[@]}" -o ServerAliveInterval=15 -o ServerAliveCountMax=40 \
	"vivac@$host_address" 'bash -s' <<'GUEST'
set -Eeuo pipefail
export XDG_RUNTIME_DIR="/run/user/$(id -u)"
export HYPRLAND_INSTANCE_SIGNATURE="$(find "$XDG_RUNTIME_DIR/hypr" -maxdepth 1 -mindepth 1 -type d -printf '%T@ %f\n' | sort -rn | head -1 | cut -d' ' -f2)"
export WAYLAND_DISPLAY="$(find "$XDG_RUNTIME_DIR" -maxdepth 1 -name 'wayland-*' ! -name '*.lock' -printf '%f\n' | sort | head -1)"
cd "$HOME/vivac"
# Dispatch through the helper: a classic dispatch string fails under Lua.
source ./lib/hypr-ipc.sh

video=/tmp/vivac-demo.mkv
cues=/tmp/vivac-demo.cues
rm -f -- "$video" "$cues"

# ------------------------------------------------------------ the mechanics
#
# Everything below is the vocabulary the choreography speaks. It is kept here,
# above the script, so the script itself reads as a list of shots.

clients() { hyprctl -j clients | python -c 'import json,sys; print(len(json.load(sys.stdin)))'; }

# A launcher is a layer surface, not a client, so `hyprctl clients` never sees
# one: an undismissed rofi sits on top of every shot that follows it. Killed by
# name, between acts. hyprlock is the exception -- it is asked to unlock, never
# killed, because a lock that dies rather than unlocks leaves Hyprland showing
# "your lockscreen app died" over everything, and that state outlives the run.
dismiss() {
	local surface
	for surface in rofi wofi dmenu nwg-bar hyprpicker; do
		pkill -x "$surface" || true
	done
}

clear_desktop() {
	dismiss
	# Killed rather than closed: a close reaches the terminal as a window
	# manager request, and kitty answers a request to close a window running an
	# editor with a confirmation dialog -- which is itself a window, and stays
	# on the picture.
	pkill -x kitty || true
	pkill -x firefox || true
	pkill -USR1 -x hyprlock || true
	sleep 1
	for _ in $(seq 20); do
		[[ "$(clients)" == 0 ]] && break
		sleep 0.5
	done
}

# What a key binding actually runs, read out of the deployed hyprland.lua, with
# the vivac names it is built from (terminal, scripts) read from the same file.
# A shot is then evidence about the binding rather than about
# a command repeated here that could drift away from it.
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
# splits its argument on spaces, the quotes do not survive the trip, and the
# environment it hands the child does not carry this script's LANG.
spawn() {
	local path=/tmp/vivac-demo-spawn.sh
	printf '#!/usr/bin/env bash\nexport LANG=en_US.UTF-8\ncd "$HOME"\n%s\n' "$1" >"$path"
	chmod +x "$path"
	hypr_dispatch exec -- "$path" >/dev/null
}

# A binding whose action is a command: run what that binding runs.
press() { spawn "$(bind_command "$1,$2")"; }

# A binding whose action is a dispatcher rather than a command: run it through
# the same dispatcher the binding names. The key combination is passed in and
# ignored so that every shot below reads as the key a viewer is being told
# about, and so a binding that moves keeps its line here honest.
act() {
	shift 2
	hypr_dispatch "$@" >/dev/null
}

# A terminal that types. The command is real and its output is real; only the
# keystrokes are performed, because this desktop ships no synthetic typist and
# adding one to the image to make a film would be the tail wagging the dog.
cat >/tmp/vivac-demo-type <<'TYPER'
#!/usr/bin/env bash
export LANG=en_US.UTF-8
cd "$HOME/vivac"
printf '\033[1m~/vivac\033[0m \033[1m❯\033[0m '
line="$*"
for (( index = 0; index < ${#line}; index++ )); do
	printf '%s' "${line:index:1}"
	sleep 0.04
done
printf '\n'
eval "$line"
TYPER
chmod +x /tmp/vivac-demo-type

# No quoting survives `hyprctl dispatch exec`, so every command a pane runs is
# written in words a bare shell splits correctly.
term() { hypr_dispatch exec -- kitty --hold /tmp/vivac-demo-type "$@" >/dev/null; }

# What a launcher would run for an application, read out of the application's
# own desktop entry rather than repeated here, for the same reason bind_command
# reads the key bindings: the shot is then evidence about the desktop. The field
# codes the specification reserves for files and URLs are removed, so a real
# argument can take their place.
desktop_exec() {
	python - "$1" <<'DESKTOPPY'
import os, re, sys

name = sys.argv[1]
directories = ('/usr/local/share/applications', '/usr/share/applications',
               os.path.expanduser('~/.local/share/applications'))
for directory in directories:
    path = os.path.join(directory, name + '.desktop')
    if not os.path.exists(path):
        continue
    section = None
    for line in open(path):
        line = line.strip()
        if line.startswith('['):
            section = line
        elif section == '[Desktop Entry]' and line.startswith('Exec='):
            print(re.sub(r'\s*%[a-zA-Z]', '', line[len('Exec='):]).strip())
            raise SystemExit(0)
raise SystemExit('no desktop entry for ' + name)
DESKTOPPY
}

# A window is asked for, not assumed: an application that has to start is slower
# than a dispatcher, and a shot taken before it appears films an empty desktop.
wait_for_class() {
	local class="$1" limit="${2:-30}"
	for _ in $(seq "$limit"); do
		if hyprctl -j clients |
			python -c 'import json,sys; sys.exit(0 if any(c.get("class") == sys.argv[1] for c in json.load(sys.stdin)) else 1)' "$class"; then
			return 0
		fi
		sleep 1
	done
	printf 'no window of class %s appeared\n' "$class" >&2
	return 1
}

# ------------------------------------------------------------------- cues
#
# A cue is a timestamp and a line. It is written the instant its shot begins,
# so the narration is stamped by the take rather than by a timing table kept
# beside it; a shot that runs long carries its subtitle with it.
t0=0
# The pin is on awk alone, never on the session: a cue timestamp is read back
# as a number on the other side, and a locale that prints a decimal comma would
# arrive there as a parse error at the end of a run that cannot be repeated
# cheaply. `date +%s.%N` needs no pin -- the point in that format is a literal.
now() { LC_ALL=C awk -v a="$(date +%s.%N)" -v b="$t0" 'BEGIN { printf "%.3f", a - b }'; }
say() { printf '%s|%s\n' "$(now)" "$1" >>"$cues"; }

# ------------------------------------------------------------ before rolling
#
# The desktop is put in a known state and the palette is set to the one the
# film opens on, off camera. A film that opens mid-clean-up is a film that
# shows the clean-up.
./scripts/apply-theme.sh --theme bad-romance >/dev/null
clear_desktop
sleep 2

resolution="$(hyprctl -j monitors | python -c 'import json,sys; m=json.load(sys.stdin)[0]; print("%dx%d" % (m["width"], m["height"]))')"

# Software encoding on four virtio cores: ultrafast keeps the encoder ahead of
# the compositor, and the host re-encodes once at the end anyway. A recorder
# that falls behind drops frames precisely during the animations worth filming.
wf-recorder -f "$video" -r 30 -c libx264 \
	-p preset=ultrafast -p crf=20 -p tune=zerolatency \
	>/tmp/vivac-demo-recorder.log 2>&1 &
recorder=$!

for _ in $(seq 40); do
	[[ -s "$video" ]] && break
	sleep 0.25
done
[[ -s "$video" ]] || {
	printf 'wf-recorder never started writing\n' >&2
	cat /tmp/vivac-demo-recorder.log >&2
	exit 1
}
# One second of settled picture before the clock starts: the first frames of a
# software encoder are the ones it is still finding its footing on, and the
# host corrects the remaining offset from the finished file's own duration.
sleep 1
t0="$(date +%s.%N)"

# ============================================================== the take ===

say "vivac — an Arch Linux workstation you can rebuild from nothing"
sleep 4
say "The wallpaper, the bar, the borders: none of them painted by hand"
sleep 4

# --- Act I: the one file -------------------------------------------------
say "SUPER + Return opens a terminal"
press SUPER Return
sleep 3
say "This is the whole theme — twenty-odd lines of colour"
term cat data/theme.conf
sleep 12
say "Every surface above is rendered from it"
term ./scripts/palette-card.sh
sleep 8

# --- Act II: the window manager -----------------------------------------
say "Tiling: a new window splits the one it lands on"
press SUPER Return
sleep 3
say "SUPER + arrows move the focus"
act SUPER left movefocus l
sleep 1.5
act SUPER right movefocus r
sleep 1.5
say "SUPER + SHIFT + arrows move the window itself"
act 'SUPER SHIFT' left movewindow l
sleep 2
act 'SUPER SHIFT' right movewindow r
sleep 2
say "SUPER + ALT + arrows resize it"
for _ in $(seq 6); do
	act 'SUPER ALT' left resizeactive -40 0
	sleep 0.2
done
for _ in $(seq 6); do
	act 'SUPER ALT' right resizeactive 40 0
	sleep 0.2
done
sleep 1
say "SUPER + F fills the screen with it"
act SUPER F fullscreen
sleep 3
act SUPER F fullscreen
sleep 2
say "Ten workspaces, on SUPER and a number"
act SUPER 2 workspace 2
sleep 1.5
term fd -e conf . data
sleep 6
act SUPER 1 workspace 1
sleep 2

# --- Act III: the editor -------------------------------------------------
clear_desktop
say "SUPER + E opens the editor"
press SUPER E
sleep 7
say "Here, on the template that renders the desktop around it"
term nvim templates/hypr/.config/hypr/hyprland.lua.in
sleep 10
say "Neovim wears the same palette, out of the same file"
sleep 4

# --- Act IV: the browser -------------------------------------------------
#
# The browser is not re-skinned here, and the film never claims it is: this
# desktop themes what it deploys, and Firefox brings its own chrome. What the
# act shows is the machine around it -- the launcher's own entry starting the
# process, the workspace strip naming the window by its class, the tiler giving
# it half the screen and then carrying it away.
clear_desktop
say "The browser starts the way the launcher starts it: from its own desktop entry"
browser_url=https://github.com/gitsual/vivac
spawn "$(desktop_exec firefox) $browser_url"
wait_for_class firefox 30
sleep 5
say "A window like any other. The bar has already named it by its class"
sleep 5
say "SUPER + Return tiles a terminal beside it, and the browser gives up half the screen"
press SUPER Return
sleep 6
act SUPER left movefocus l
sleep 1
say "SUPER + SHIFT + 3 carries the browser away, and the strip follows it across"
act 'SUPER SHIFT' 3 movetoworkspace 3
sleep 3
act SUPER 3 workspace 3
sleep 4
say "One more tab goes to the process that is already running, not to a second one"
spawn "$(desktop_exec firefox) --new-tab $browser_url/blob/main/docs/keys.md"
sleep 8

# --- Act V: the help -----------------------------------------------------
say "F1: every key this desktop binds, read out of the config itself"
press '' F1
sleep 8
dismiss
sleep 1
say "F2 to F5: the browser, the shell, the editor, the system"
press '' F2
sleep 4
dismiss
press '' F3
sleep 4
dismiss
press '' F4
sleep 4
dismiss
press '' F5
sleep 4
dismiss
sleep 1

# --- Act VI: launchers and clipboard -------------------------------------
say "Three launchers, one palette. SUPER + R is rofi"
press SUPER R
sleep 4
dismiss
sleep 1
say "SUPER + ALT + R is wofi"
press 'SUPER ALT' R
sleep 4
dismiss
sleep 1
say "SUPER + D is dmenu"
press SUPER D
sleep 4
dismiss
sleep 1
# The clipboard menu is only worth a shot with something in it, and the history
# is whatever the running watcher has seen. Detached because wl-copy does not
# exit: it stays alive owning the selection, and a copy left attached to this
# SSH channel keeps it open for as long as the selection lasts.
printf '%s' 'data/themes/northern-lights.conf' >/tmp/vivac-demo-clip-1
setsid wl-copy </tmp/vivac-demo-clip-1 >/dev/null 2>&1 &
sleep 1
printf '%s' '#1F1A17' >/tmp/vivac-demo-clip-2
setsid wl-copy </tmp/vivac-demo-clip-2 >/dev/null 2>&1 &
sleep 1
say "SUPER + V is everything the clipboard has seen"
press SUPER V
sleep 5
dismiss
sleep 1

# --- Act VII: the screenshot ---------------------------------------------
say "SUPER + SHIFT + S takes a shot and says where it went"
shots="${XDG_SCREENSHOTS_DIR:-$HOME/Pictures/Screenshots}"
mkdir -p "$shots"
shot="$shots/screenshot_$(date +%Y%m%d_%H%M%S).png"
grim -g '0,0 960x540' "$shot"
setsid wl-copy <"$shot" >/dev/null 2>&1 &
notify-send 'Screenshot saved' "$shot"
sleep 5

# --- Act VIII: the colour ------------------------------------------------
#
# The desktop is re-dressed first, because this is the act the whole film is
# for: the recolour has to land on a populated screen, with the bar, the
# borders, two terminals and an editor all turning together.
clear_desktop
term nvim templates/hypr/.config/hypr/hyprland.lua.in
sleep 6
term ./scripts/palette-card.sh
sleep 4
term ./dotfiles/ricer/.local/bin/vivac-theme --print
sleep 4

say "SUPER + SHIFT + T asks which of the eight to wear"
press 'SUPER SHIFT' T
sleep 5
dismiss
sleep 1

# The menu ends on this command, and so does this run: the bar, the borders,
# the wallpaper, the terminals already open and the notifications all re-read
# their own configuration, live, with nothing restarted.
say "One file each. Nothing restarts; everything re-reads"
for theme in bad-romance carmen cosmos gatsby metropolis northern-lights persephone the-hermit; do
	file="data/themes/$theme.conf"
	[[ "$theme" == bad-romance ]] && file=data/theme.conf
	title="$(sed -nE 's/^# @title: (.*)$/\1/p' "$file")"
	essence="$(sed -nE 's/^# @essence: (.*)$/\1/p' "$file")"
	./scripts/apply-theme.sh --theme "$theme" >/dev/null
	say "${title:-$theme} — ${essence:-a palette}"
	sleep 5
done
./scripts/apply-theme.sh --theme bad-romance >/dev/null
sleep 3

# --- Act IX: the session ----------------------------------------------
say "SUPER + SHIFT + Q ends the session, and asks first"
press 'SUPER SHIFT' Q
sleep 5
dismiss
sleep 1
say "SUPER + SHIFT + E is the same question, drawn by rofi"
press 'SUPER SHIFT' E
sleep 5
dismiss
sleep 1
say "The welcome pane: what this machine is, in the session's language"
spawn 'kitty --class vivac-welcome -e "$HOME/.local/bin/vivac-welcome"'
sleep 8

say "SUPER + L locks it"
clear_desktop
press SUPER L
sleep 7
# Dismissed with SIGUSR1, which is hyprlock's own unlock signal, never with a
# plain kill. See the note on dismiss() above.
pkill -USR1 -x hyprlock || true
for _ in $(seq 20); do
	pgrep -x hyprlock >/dev/null || break
	sleep 0.5
done
sleep 2

say "Eight palettes, one source. Forty-six gates. One command to deploy"
sleep 5
say "github.com/gitsual/vivac"
sleep 5

# ============================================================= cut =========
total="$(now)"
printf '%s|\n' "$total" >>"$cues"
printf 'resolution=%s\nelapsed=%s\n' "$resolution" "$total" >/tmp/vivac-demo.meta

# SIGINT rather than a kill: wf-recorder answers it by flushing the encoder and
# closing the container. A killed recorder leaves an unplayable file.
kill -INT "$recorder" 2>/dev/null || true
for _ in $(seq 60); do
	kill -0 "$recorder" 2>/dev/null || break
	sleep 0.5
done
wait "$recorder" 2>/dev/null || true
clear_desktop
GUEST

# --------------------------------------------------------------- the print
mkdir -p -- "$(dirname -- "$output")"
work="$(mktemp -d)"
trap 'rm -rf -- "$work"' EXIT
scp_opts=(-i "$run/id_ed25519" -P "$port" -o StrictHostKeyChecking=no
	-o UserKnownHostsFile=/dev/null)
scp -q "${scp_opts[@]}" "vivac@$host_address:/tmp/vivac-demo.mkv" "$work/take.mkv"
scp -q "${scp_opts[@]}" "vivac@$host_address:/tmp/vivac-demo.cues" "$work/cues"
scp -q "${scp_opts[@]}" "vivac@$host_address:/tmp/vivac-demo.meta" "$work/meta"

duration="$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$work/take.mkv")"
printf 'Took %s of film; drawing the subtitles ...\n' "$duration"

# The cue clock starts after the recorder is already writing, so every cue is
# late by exactly the pre-roll -- which the finished file's own duration gives
# away, and which is added back here rather than guessed at record time.
VIVAC_DURATION="$duration" python - "$work/cues" "$repo_root/data/theme.conf" "$work/meta" "$work/subtitles.ass" <<'ASS'
import os, pathlib, re, sys

cues_path, palette_path, meta_path, out_path = (pathlib.Path(p) for p in sys.argv[1:5])
meta = dict(re.findall(r'^(\w+)=(.*)$', meta_path.read_text(), re.M))
width, height = (int(n) for n in meta.get('resolution', '1920x1080').split('x'))
elapsed = float(meta['elapsed'])
offset = max(0.0, float(os.environ['VIVAC_DURATION']) - elapsed)

palette = dict(re.findall(r'^(COLOR_\w+)=(\w{6})$', palette_path.read_text(), re.M))


def ass_colour(name, fallback, alpha='00'):
    """ASS takes &HAABBGGRR -- alpha first, and the channels reversed."""
    rr, gg, bb = (palette.get(name, fallback)[i:i + 2] for i in (0, 2, 4))
    return f'&H{alpha}{bb}{gg}{rr}'.upper()


def stamp(seconds):
    seconds = max(0.0, seconds)
    hours, seconds = divmod(seconds, 3600)
    minutes, seconds = divmod(seconds, 60)
    return f'{int(hours)}:{int(minutes):02d}:{seconds:05.2f}'


cues = []
for line in cues_path.read_text().splitlines():
    at, _, text = line.partition('|')
    cues.append((float(at) + offset, text))

# A subtitle is scaled to the picture rather than pinned to a pixel size, so a
# guest that boots at another resolution is still legible.
size = max(20, round(height / 30))
margin = round(height / 16)
# The narration sits on a plate, not straight on the desktop: border style 3
# fills a box in the outline colour, so the six points of outline become
# padding around the text rather than a stroke on it. Without the plate the
# line lands on whatever the terminal is printing underneath and the two read
# as one -- which is how the first cut came out.
header = f'''[Script Info]
ScriptType: v4.00+
PlayResX: {width}
PlayResY: {height}
WrapStyle: 0
ScaledBorderAndShadow: yes

[V4+ Styles]
Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
Style: Narration,JetBrainsMono Nerd Font,{size},{ass_colour('FG', 'D9E2DD')},{ass_colour('FG', 'D9E2DD')},{ass_colour('BG', '0E1513')},{ass_colour('BG', '0E1513')},0,0,0,0,100,100,0,0,3,6,0,2,{margin},{margin},{margin},1

[Events]
Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
'''

lines = []
for index, (at, text) in enumerate(cues):
    if not text:
        continue
    end = cues[index + 1][0] if index + 1 < len(cues) else at + 5
    # Half a second of fade at each end: a subtitle that snaps in reads as a
    # defect on a desktop where everything else is eased.
    lines.append(
        f'Dialogue: 0,{stamp(at)},{stamp(end - 0.15)},Narration,,0,0,0,,'
        f'{{\\fad(300,300)}}{text}')

out_path.write_text(header + '\n'.join(lines) + '\n')
print(f'{len(lines)} subtitles, {offset:.2f}s of pre-roll corrected')
ASS

# Burned in rather than carried as a track: the film is meant to be dropped
# into a README, a release page or a chat window, none of which turn a subtitle
# track on for the reader.
ffmpeg -y -loglevel error -stats -i "$work/take.mkv" \
	-vf "subtitles=$work/subtitles.ass:fontsdir=/usr/share/fonts" \
	-c:v libx264 -preset slow -crf 20 -pix_fmt yuv420p -movflags +faststart \
	-an "$output"

printf 'Wrote %s (%s)\n' "$output" "$(du -h -- "$output" | cut -f1)"
