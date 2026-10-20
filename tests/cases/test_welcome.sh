#!/usr/bin/env bash
set -Eeuo pipefail

# The first-run wizard is the one program in the repository that a stranger
# meets before they know anything, so the parts of it that can be checked
# without a compositor are checked here: that it runs once and then stops, that
# every choice it offers is a choice the settings file will accept, and that
# the answers it writes are readable by the loader that has to read them.

repo_root="${REPO_ROOT:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)}"
wizard="$repo_root/dotfiles/welcome/.local/bin/vivac-welcome"
hypr="$repo_root/templates/hypr/.config/hypr/hyprland.lua.in"
# shellcheck source=lib/kv.sh
source "$repo_root/lib/kv.sh"
# shellcheck source=lib/settings.sh
source "$repo_root/lib/settings.sh"

fail() {
	printf '%s\n' "$1" >&2
	exit 1
}
[[ -x "$wizard" ]] || fail 'the wizard is missing or not executable'

sandbox="$(mktemp -d "${TMPDIR:-/tmp}/vivac-welcome.XXXXXX")"
trap 'rm -rf -- "$sandbox"' EXIT

# Once, and then never again without being asked. A wizard that reappears every
# login is not a welcome, it is an obstacle.
state="$sandbox/state/vivac"
mkdir -p -- "$state"
printf 'welcome completed\n' >"$state/welcome-done"
output="$(HOME="$sandbox" XDG_STATE_HOME="$sandbox/state" VIVAC_REPO="$repo_root" \
	"$wizard" --first-run 2>&1)" || fail "--first-run failed with a marker present: $output"
[[ -z "$output" ]] || fail "--first-run spoke when it should have stayed silent: $output"

# The language is asked first and applied before anything else is drawn: every
# screen after it comes out of the table it selects, so asking later would mean
# running most of the tour in a language the reader may not have.
grep -Fq 'step_language >/dev/null' "$wizard" || fail 'the wizard never asks which language to speak'
sed -n '/^step_language()/,/^}/p' "$wizard" | grep -Fq 'setting_write locale' ||
	fail 'the language step changes nothing the system will read'
sed -n '/^step_language()/,/^}/p' "$wizard" | grep -Fq 'setting_write language' ||
	fail 'the chosen language never reaches the language setting, so it cannot be shared'
sed -n '/^step_language()/,/^}/p' "$wizard" | grep -Fq 'i18n_load' ||
	fail 'the wizard keeps speaking the old language after the answer'
language_line="$(grep -n 'step_language >/dev/null' "$wizard" | head -1 | cut -d: -f1)"
layout_line="$(grep -n 'step_layout >/dev/null' "$wizard" | head -1 | cut -d: -f1)"
((language_line < layout_line)) || fail 'the wizard asks the language after it has already spoken'
while IFS= read -r locale; do
	settings_valid locale "$locale" || fail "the wizard offers locale=$locale, which settings refuse"
done < <(sed -nE 's/^declare -A locales=\((.*)\)$/\1/p' "$wizard" | tr ' ' '\n' | sed -E 's/^\[[a-z]+\]=//' | grep .)

# Every keyboard it offers has to survive the settings validator, on both axes
# it writes. An entry that cannot be saved is a dead end dressed as a choice.
mapfile -t offered < <(sed -nE 's/^layouts=\((.*)\)$/\1/p' "$wizard" | tr ' ' '\n' | grep .)
((${#offered[@]} >= 4)) || fail 'the wizard offers almost no keyboards'
for layout in "${offered[@]}"; do
	settings_valid xkb_layout "$layout" || fail "the wizard offers xkb_layout=$layout, which settings refuse"
	settings_valid keymap "$layout" || fail "the wizard offers keymap=$layout, which settings refuse"
	grep -q "^	\[$layout\]=" "$wizard" || fail "the keyboard $layout is offered with no label to read"
done

# The theme list is read from the catalogue, never copied into the wizard: a
# second list is a second thing to forget to update.
grep -qE '^themes=\(bad-romance\)$' "$wizard" ||
	fail 'the wizard seeds its theme list with something other than the default alone'
grep -Fq 'data/themes' "$wizard" || fail 'the wizard does not read the catalogue'

# What it writes has to be what the loader reads, including when the key was
# already there: the second answer replaces the first rather than joining it.
settings_file="$sandbox/.config/vivac/settings"
mkdir -p -- "$(dirname -- "$settings_file")"
mkdir -p -- "$sandbox/shared"
printf 'theme=bad-romance\nxkb_layout=us\nshared_settings=%s\n' "$sandbox/shared/settings" >"$settings_file"
printf 'mod=lwin\n' >"$sandbox/shared/settings"
HOME="$sandbox" XDG_CONFIG_HOME="$sandbox/.config" VIVAC_REPO="$repo_root" \
	bash -c 'source "$2/lib/kv.sh"; source "$2/lib/settings.sh"; source "$0"; settings_file="$1"; setting_write xkb_layout fr; setting_write theme metropolis; setting_write language en' \
	<(sed -n '/^setting_write()/,/^}/p' "$wizard") "$settings_file" "$repo_root" ||
	fail 'setting_write failed on an existing file'
(($(grep -c '^xkb_layout=' "$settings_file") == 1)) || fail 'setting_write duplicated a key'
[[ "$(cat "$sandbox/shared/settings")" == $'mod=lwin\ntheme=metropolis\nlanguage=en' ]] ||
	fail "the wizard's answers did not reach the shared file as the other OS expects: $(tr '\n' ' ' <"$sandbox/shared/settings")"
settings_load "$settings_file" || fail 'the loader cannot read what the wizard wrote'
[[ "${SETTINGS[xkb_layout]}" == fr ]] || fail "the loader read xkb_layout=${SETTINGS[xkb_layout]}, not fr"
[[ "${SETTINGS[theme]}" == metropolis ]] || fail "the loader read theme=${SETTINGS[theme]}, not metropolis"

# Started exactly once by the session, with the flag that makes it a no-op the
# second time, and floated so it is not tiled behind the bar on first sight.
(($(grep -c 'vivac-welcome --first-run' "$hypr") == 1)) ||
	fail 'the session does not start the wizard exactly once'
grep -Fq 'match = { class = "^(vivac-welcome)$" }, float = true' "$hypr" ||
	fail 'the wizard would be tiled like an ordinary window'
grep -Fq 'welcome' "$repo_root/scripts/deploy.sh" || fail 'the wizard is never deployed'

# The background is part of the theme, not a constant: the session's wallpaper
# script reads the same setting, and draws the image when the chosen theme has
# none yet. Only the default ships as a committed PNG.
paper="$repo_root/dotfiles/hypr/.config/hypr/scripts/wallpaper.sh"
grep -Fq 'vivac/settings' "$paper" || fail 'the wallpaper ignores the chosen theme'
grep -Fq 'make-wallpaper.sh' "$paper" || fail 'a theme without a committed image would have no wallpaper'
grep -Fq 'bad-romance.png' "$paper" || fail 'the wallpaper has no fallback when nothing can be drawn'

# ...and the fallback must stay a fallback. The wallpaper is the ONLY themed
# file drawn at run time rather than committed, so the base profile has to
# install something that can turn an SVG into the PNG swaybg is handed. It did
# not, and the symptom was the worst kind: every other themed file changed
# colour and the largest thing on screen did not.
declare -A provides=(
	[rsvg-convert]=librsvg [magick]=imagemagick
	[convert]=imagemagick [inkscape]=inkscape
)
rasterizers=0
for binary in "${!provides[@]}"; do
	grep -Fq "$binary" "$repo_root/scripts/make-wallpaper.sh" || continue
	grep -Fxq "${provides[$binary]}" "$repo_root/packages/pacman.txt" && rasterizers=$((rasterizers + 1))
done
((rasterizers > 0)) ||
	fail 'no package in the base profile can rasterize a wallpaper, so every theme would show the default'

# And the published image draws them all up front: the wizard asks someone to
# judge a theme by looking at it, which does not work while the desktop sits
# bare rasterizing 4K.
grep -Fq 'make-wallpaper.sh' "$repo_root/scripts/seal-vm-image.sh" ||
	fail 'the sealed image ships no drawn wallpapers, so the first preview of each theme stalls'
# Choosing a theme has to change the room, not a line in a file. The wizard
# does not know how to do that and must not learn: it delegates to the one
# script that applies a palette everywhere, so there is a single answer to
# "what does picking a theme actually do".
grep -Fq 'apply-theme.sh --theme' "$wizard" ||
	fail 'the theme preview does not apply the theme, so choosing one shows nothing'
# Replacing the running wallpaper is wallpaper.sh's job, not apply-theme.sh's:
# it happens holding the lock that serialises concurrent previews, and doing it
# from out here raced that lock. Follow the delegation rather than pinning the
# kill to a file -- this assertion used to grep apply-theme.sh and passed for
# months while the call it guarded never ran even once.
grep -Fq 'scripts/wallpaper.sh' "$repo_root/scripts/apply-theme.sh" ||
	fail 'applying a theme never reaches the wallpaper script'
grep -Fq 'pkill -x swaybg' "$repo_root/dotfiles/hypr/.config/hypr/scripts/wallpaper.sh" ||
	fail 'applying a theme cannot replace the running wallpaper'

# Applying a palette everywhere was measured at 529-989 ms in the VM. Running
# it once per keypress means holding an arrow down queues one full application
# per key repeat, and the list answers nothing until the queue drains -- a
# frozen desktop reached through the wizard rather than through the script.
# The preview must therefore wait for the selection to stand still, which in a
# read loop is a bounded read that falls through to the preview on timeout.
# shellcheck disable=SC2016  # the patterns are literal shell source to search for
grep -Eq 'read -rsn1 -t "\$settle"' "$wizard" ||
	fail 'the wizard previews on every keypress; hold an arrow and the list stops answering'
# ...and the drawing must not be behind that wait: the list itself has to be on
# screen before the timer starts, or the debounce just moves the freeze.
# shellcheck disable=SC2016  # idem
draw_line="$(grep -n 'footer "\$hint"' "$wizard" | head -1 | cut -d: -f1)"
# shellcheck disable=SC2016  # idem
settle_line="$(grep -n 'read -rsn1 -t "\$settle"' "$wizard" | head -1 | cut -d: -f1)"
((draw_line < settle_line)) ||
	fail 'the wizard waits before it draws, so the debounce hides the selection instead of the delay'

# A preview that fails silently is worse than one that fails loudly: the room
# stays exactly as it was, which looks identical to a theme that happens to
# resemble the previous one. Keep the run and say where it is.
sed -n '/^theme_preview()/,/^}/p' "$wizard" | grep -Fq '|| true' &&
	fail 'the theme preview swallows apply-theme failures without a trace'
sed -n '/^theme_preview()/,/^}/p' "$wizard" | grep -Fq 'preview_note=' ||
	fail 'the theme preview reports nothing when it cannot dress the desktop'
sed -n '/^footer()/,/^}/p' "$wizard" | grep -Fq 'preview_note' ||
	fail 'the preview failure is recorded but never shown to the person choosing'

# Not one line of it is in the wizard any more. It used to hold its own
# Spanish, so a session set to English met a Spanish tour -- the first program a
# stranger sees, in a language they may not have.
grep -Fq 'i18n_load' "$wizard" || fail 'the wizard does not read the translation tables'
grep -nE "(centre|footer|frame|wait_for|note) +'[^']*[áéíóúñ¿¡]" "$wizard" &&
	fail 'the wizard still says something in Spanish of its own'

# The key with the Windows logo on it is what the tour must call it. "SUPER" is
# what the documentation calls it and what nobody can find on their keyboard,
# and a first tour that opens with a name the hardware does not use has already
# lost its reader. The name is now a translation like any other, so it is the
# tables that are asked.
for table in "$repo_root"/i18n/*.conf; do
	language="$(basename -- "$table" .conf)"
	grep -qE '^welcome\.[a-z.]+=.*[^{]SUPER' "$table" &&
		fail "the $language tour names a key that is not written on the keyboard"
	grep -q '^welcome.super=' "$table" || fail "the $language tour has no name for the modifier key"
done

# Every step is a step the reader can be told apart from the others, and the
# counter it prints is the number of steps there actually are: a tour that says
# "paso 4 de 9" and stops at six is worse than one that counts nothing.
declared="$(sed -nE 's/^tour_total=([0-9]+)$/\1/p' "$wizard")"
tour="$(sed -n '/^step_tour()/,/^}/p' "$wizard")"
actual="$(grep -cE "^$(printf '\t')(wait_for|note) " <<<"$tour")"
[[ "$declared" == "$actual" ]] ||
	fail "the tour announces $declared steps and takes $actual"

# Each detector is a function this file defines, never a string handed to eval:
# the tour runs whatever it is given, on every tick, in the user's session.
while IFS= read -r predicate; do
	grep -qE "^$predicate\(\) \{" "$wizard" ||
		fail "the tour waits on $predicate, which is not a function it defines"
done < <(sed -nE "s/^$(printf '\t\t')[0-9]+ ([a-z_]+).*/\1/p" <<<"$tour" | LC_ALL=C sort -u)

# The things the user asked to be taught, and the things a desktop is useless
# without: closing a window, carrying one to another desktop, the panels and
# the key that dismisses them, the bar, the volume, and the package manager in
# both directions. A tour that only opens things teaches half a system.
# Matched against the Spanish table, where the modifier is the {1} the wizard
# fills in, so the literals below are text and not a shell expansion waiting to
# happen. Every language is checked for the key; only one is checked for the
# words, because the words are what a translator is free to rewrite.
for taught in '{1} + Q' '{1} + Shift + 3' 'Escape para cerrar' 'pacman -S chromium' \
	'pacman -Rns chromium' 'dirección IP' 'volumen'; do
	grep -Fq "$taught" "$repo_root/i18n/es.conf" || fail "the tour never teaches: $taught"
done

# And the detectors are RUN, not grepped for.
#
# Two of them were broken in ways no pattern match could have shown. hyprctl
# pretty-prints its JSON, so a regex written as if `"workspace": {"id": 3}`
# were one line matched nothing — the step that carries a window to another
# desktop could never succeed. And rofi on Wayland draws a layer-shell
# surface, so the help pane never appears in `hyprctl clients` at all, whatever
# is grepped for. Both failed silently, waiting out their timeout and then
# behaving exactly as if the user had skipped the step.
stub="$sandbox/bin"
mkdir -p -- "$stub"
cat >"$stub/hyprctl" <<'STUB'
#!/usr/bin/env bash
case "$1" in
clients) cat "$HYPR_CLIENTS" ;;
activeworkspace) printf '{
    "id": %s,
    "name": "%s"
}
' "$HYPR_ACTIVE" "$HYPR_ACTIVE" ;;
esac
STUB
cat >"$stub/pgrep" <<'STUB'
#!/usr/bin/env bash
[[ "${ROFI_RUNNING:-no}" == yes ]] && { printf '4242
'; exit 0; }
exit 1
STUB
chmod +x -- "$stub/hyprctl" "$stub/pgrep"

# Exactly the shape hyprctl emits: one key per line, the workspace object
# opened on its own line.
client() {
	printf '    {
        "address": "0x%s",
        "class": "kitty",
        "title": "t",
        "workspace": {
            "id": %s,
            "name": "%s"
        }
    }' "$1" "$2" "$2"
}
{
	printf '[
'
	client aaa 1
	printf ',
'
	client bbb 3
	printf '
]
'
} >"$sandbox/clients-split.json"
{
	printf '[
'
	client aaa 1
	printf '
]
'
} >"$sandbox/clients-together.json"

detectors="$sandbox/detectors.sh"
sed -n '/^clients_flat()/,/^step_tour()/p' "$wizard" | sed '$d' >"$detectors"
grep -q '^help_pane_open()' "$detectors" || fail 'the detectors could not be extracted from the wizard'

# probe EXPECT ACTIVE CLIENTS ROFI PREDICATE [ARG...]
probe() {
	local expect="$1" active="$2" clients="$3" rofi="$4"
	shift 4
	local got=yes
	PATH="$stub:$PATH" HYPR_ACTIVE="$active" HYPR_CLIENTS="$clients" ROFI_RUNNING="$rofi" 		bash -c 'source "$1"; shift; "$@"' _ "$detectors" "$@" >/dev/null 2>&1 || got=no
	[[ "$got" == "$expect" ]] || fail "$* on workspace $active said $got, expected $expect"
}

split="$sandbox/clients-split.json"
together="$sandbox/clients-together.json"
probe yes 1 "$split" no more_windows_than 1
probe no 1 "$split" no more_windows_than 2
probe yes 1 "$split" no fewer_windows_than 3
probe no 1 "$split" no left_first_workspace
probe yes 2 "$split" no left_first_workspace
# The one the pretty-printing broke: a client sits on 3 while we watch 1.
probe yes 1 "$split" no window_moved_away
probe no 1 "$together" no window_moved_away
# The one the layer-shell broke: rofi is a process, never a client.
probe yes 1 "$together" yes help_pane_open
probe no 1 "$together" no help_pane_open
probe yes 1 "$together" no help_pane_closed

printf 'welcome: silent once taken, %d keyboards the settings accept, %s tour steps that detect themselves\n' \
	"${#offered[@]}" "$declared"
