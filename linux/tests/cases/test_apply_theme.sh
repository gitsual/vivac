#!/usr/bin/env bash
set -Eeuo pipefail

# Picking a theme has to change the room.
#
# The palette-dependent stylesheets are committed renders of the DEFAULT
# palette, symlinked into place by Stow. That makes choosing another theme a
# trap: the setting changes, the files on disk do not, and the desktop looks
# exactly as it did. So the overlay is asserted here in both directions — that
# a chosen palette really lands in every stylesheet, and that going back to the
# default restores the Stow symlink byte for byte rather than leaving a stale
# copy of somebody else's colours behind.

repo_root="${REPO_ROOT:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)}"
apply="$repo_root/scripts/apply-theme.sh"
facts="$repo_root/tests/golden/vm-virtio/hardware-facts"

fail() {
	printf '%s\n' "$1" >&2
	exit 1
}
[[ -x "$apply" ]] || fail 'scripts/apply-theme.sh is missing or not executable'
command -v stow >/dev/null || {
	printf 'apply-theme: skipped, stow is not installed\n'
	exit 0
}

sandbox="$(mktemp -d "${TMPDIR:-/tmp}/vivac-theme.XXXXXX")"
trap 'rm -rf -- "$sandbox"' EXIT
mkdir -p -- "$sandbox/.config"

# Every package that carries a palette-dependent template, laid out the way a
# real session lays it out.
# A directory under templates/ is a Stow package when dotfiles/ has its twin.
# The others render somewhere else entirely -- system/ into /etc, wallpaper/
# and brand/ into generated artefacts -- and naming them one by one here meant
# that adding a third such directory broke this test instead of being ignored
# by it.
mapfile -t packages < <(find "$repo_root/templates" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' |
	while IFS= read -r name; do
		[[ -d "$repo_root/dotfiles/$name" ]] && printf '%s\n' "$name"
	done | LC_ALL=C sort)
stow --dir="$repo_root/dotfiles" --target="$sandbox" --no-folding "${packages[@]}"

run() {
	HOME="$sandbox" XDG_CONFIG_HOME="$sandbox/.config" XDG_STATE_HOME="$sandbox/.state" \
		FACTS_FILE="$facts" FACTS_OVERRIDE="$sandbox/absent" \
		SETTINGS_FILE="$sandbox/.config/vivac/settings" \
		"$apply" "$@"
}

# The paths the overlay owns, and what they pointed at before anyone touched
# them. Restoring has to reproduce this map exactly.
declare -A before=()
while IFS= read -r template; do
	rest="${template#"$repo_root/templates/"}"
	rest="${rest#*/}"
	[[ "$rest" == .* ]] || continue
	target="$sandbox/${rest%.in}"
	[[ -L "$target" ]] || fail "$rest is not stowed as a symlink; the test cannot tell restoration from luck"
	before["$target"]="$(readlink -- "$target")"
done < <(find "$repo_root/templates" -type f -name '*.in' | LC_ALL=C sort)
((${#before[@]} >= 5)) || fail 'almost nothing in this desktop depends on the palette; the test is not testing'

# A name that is not in the catalogue is refused by name, before anything on
# disk moves.
run --theme not-a-theme --no-reload >/dev/null 2>&1 && fail 'an unknown theme was accepted'
for target in "${!before[@]}"; do
	[[ -L "$target" ]] || fail "a refused theme still replaced $target"
done

# Applying a real one: every palette-dependent file becomes a real file, and
# holds a colour from the palette that was asked for rather than the default's.
run --theme carmen --no-reload >/dev/null
# Told apart by their BACKGROUND, not their accent: an accent is the canonical
# hex of an aesthetic in data/aesthetics.tsv, so two themes rooted in the same
# aesthetic share one on purpose and would make this assertion pass by accident.
background="$(sed -nE 's/^COLOR_BG=(.*)$/\1/p' "$repo_root/data/themes/carmen.conf")"
default_background="$(sed -nE 's/^COLOR_BG=(.*)$/\1/p' "$repo_root/data/theme.conf")"
[[ -n "$background" && "$background" != "$default_background" ]] || fail 'the fixture theme is indistinguishable from the default'
carried=0
for target in "${!before[@]}"; do
	[[ -L "$target" ]] && fail "$target is still a symlink: the chosen palette never reached it"
	grep -qiF "$background" "$target" && carried=$((carried + 1))
done
((carried >= 3)) || fail "the chosen background reached only $carried files"

# Switching again must not accumulate: the previous overlay is undone first, so
# no file is left holding the palette before last.
run --theme metropolis --no-reload >/dev/null
for target in "${!before[@]}"; do
	grep -qiF "$background" "$target" && fail "$target still carries the previous theme's background"
done

# And back to the default: every symlink returns, pointing exactly where it
# pointed, and the overlay record is gone rather than merely emptied.
run --theme bad-romance --no-reload >/dev/null
for target in "${!before[@]}"; do
	[[ -L "$target" ]] || fail "$target did not go back to being a Stow symlink"
	[[ "$(readlink -- "$target")" == "${before[$target]}" ]] ||
		fail "$target was restored to the wrong place"
done
[[ -e "$sandbox/.state/vivac/theme-overlay" ]] &&
	fail 'the default still records an overlay it does not have'

# Nothing outside the home directory is ever written: the greeter's stylesheet
# lives in /etc and belongs to apply-system.sh, which asks for root first.
grep -Fq 'etc/greetd' "$sandbox/.state/vivac/theme-overlay" 2>/dev/null &&
	fail 'the overlay reaches outside the home directory'

printf 'apply-theme: %d palette-dependent files overlaid and restored exactly\n' "${#before[@]}"

# --------------------------------------------------------------- the swap
#
# Everything above proves the overlay lands and is restored. These pin HOW it
# is written, because both of the ways it used to be written were invisible to
# a test that only looks at the result.

# The config must never stop existing, not even between two syscalls. It used
# to: the restore did `rm -f` then `ln -s`, and a reload landing in that gap
# made Hyprland write its own stub config over the path -- a session with 6
# binds instead of 55, which draws normally and answers no key. The stub then
# made the `ln -s` fail with EEXIST, killing the script under `set -e` and
# leaving the overlay half undone.
# Removing a target with nothing to restore is fine; removing it in order to
# put something back in its place is the bug. Only the second is flagged.
awk '/rm -f -- "\$target"/ { window = 2; next }
     window && (/ln -s -- "\$link" "\$target"/ || /mv -- "\$scratch" "\$target"/) { found = 1 }
     window { window-- }
     END { exit(found ? 0 : 1) }' "$apply" &&
	fail 'apply-theme.sh unlinks a target before recreating it; rename over it instead'
grep -Fq 'mv -T --' "$apply" ||
	fail 'apply-theme.sh no longer swaps files with an atomic rename'

# The scratch file has to be a sibling of its target. `mktemp` with no argument
# lands in $TMPDIR, and /tmp is tmpfs while $HOME is not, so the mv crossed a
# filesystem and became a byte-by-byte copy -- a window holding a half-written
# config for anything that reloads.
# shellcheck disable=SC2016  # $TMPDIR names the variable, it is not expanded
grep -Eq 'mktemp\)"' "$apply" &&
	fail 'apply-theme.sh renders into $TMPDIR; the mv there is a copy, not a rename'

# The wallpaper is half of what choosing a theme is FOR, and it was dead from
# the first commit: apply-theme.sh gated it on the script being executable
# while committing that script 644, so the block never ran anywhere. Both call
# sites invoke it through `bash`, so the bit is not what the guard should ask
# about -- but the bit is also the odd one out among its siblings, so pin both.
wallpaper='dotfiles/hypr/.config/hypr/scripts/wallpaper.sh'
[[ -x "$repo_root/$wallpaper" ]] ||
	fail "$wallpaper is not executable; every sibling script in the repo is"
if git -C "$repo_root" rev-parse --git-dir >/dev/null 2>&1; then
	mode="$(git -C "$repo_root" ls-files -s -- "$wallpaper" | cut -d' ' -f1)"
	[[ "$mode" == 100755 ]] ||
		fail "$wallpaper is committed $mode; a lost execute bit used to disable the wallpaper silently"
fi
# shellcheck disable=SC2016  # the pattern is literal shell source to search for
grep -Fq '[[ -x "$HOME/.config/hypr/scripts/wallpaper.sh" ]]' "$apply" &&
	fail 'apply-theme.sh gates the wallpaper on a bit it never uses; test -f'

# Previewing fires one wallpaper.sh per keypress. Unserialised, the desktop
# ended up wearing whichever instance finished last rather than the theme the
# user stopped on. The lock alone is not enough: the setting has to be read
# after it is held, so queued instances converge on what is current now.
grep -Fq 'flock 9' "$repo_root/$wallpaper" ||
	fail 'wallpaper.sh does not serialise the swap; concurrent previews race'
lock_line="$(grep -n 'flock 9' "$repo_root/$wallpaper" | head -1 | cut -d: -f1)"
# shellcheck disable=SC2016  # the pattern is literal shell source to search for
theme_line="$(grep -n '^\[\[ -f "\$settings" \]\]' "$repo_root/$wallpaper" | head -1 | cut -d: -f1)"
((lock_line < theme_line)) ||
	fail 'wallpaper.sh reads the theme before taking the lock; queued instances will apply a stale one'

# A reload talks to another process, and a wedged one never answers. Previews
# run synchronously from the wizard, so an unbounded call there stops the
# keyboard loop for the life of the session -- a frozen desktop reached by a
# second road. Anything that waits on another process has to be bounded.
grep -Eq '^[[:space:]]*(hyprctl|dunstctl) ' "$apply" &&
	fail 'apply-theme.sh waits on another process with no timeout'

# The terminal is part of the palette, and an open one must not keep the
# previous theme's ground until it is closed. kitty re-reads its config on
# SIGUSR1; that is the signal kitty's own reload_conf_in_all_kitties sends.
grep -Fq 'pkill -SIGUSR1 -x kitty' "$apply" ||
	fail 'open terminals keep the previous theme until they are relaunched'
kitty_template="$repo_root/templates/kitty/.config/kitty/kitty.conf.in"
for token in TERMINAL_FG TERMINAL_BG; do
	grep -Fq "@$token" "$kitty_template" ||
		fail "the terminal does not take $token from the palette"
	while IFS= read -r palette; do
		grep -Eq "^$token=" "$palette" ||
			fail "$(basename "$palette") names no $token, so its terminal borrows another theme's"
	done < <(find "$repo_root/data/themes" -type f -name '*.conf'; printf '%s\n' "$repo_root/data/theme.conf")
done

printf 'apply-theme: swap is atomic, wallpaper reachable, reloads bounded, terminal themed\n'

# Deploying must not undress the desktop. A non-default theme lives as an
# overlay written OVER the stowed symlinks, and --restow points every one of
# them back at the committed default render: the settings file went on saying
# cosmos while the terminal came back bad-romance, which is the one
# mismatch nobody looks for because the setting is right.
# shellcheck disable=SC2016  # the pattern is literal shell source to search for
grep -Fq 'apply-theme.sh" --theme "$theme"' "$repo_root/scripts/deploy.sh" ||
	fail 'deploying leaves the chosen theme off the desktop'
deploy_stow="$(grep -n 'restow' "$repo_root/scripts/deploy.sh" | head -1 | cut -d: -f1)"
deploy_theme="$(grep -n 'apply-theme.sh" --theme' "$repo_root/scripts/deploy.sh" | head -1 | cut -d: -f1)"
((deploy_stow < deploy_theme)) ||
	fail 'deploy reapplies the theme before it restows, so restowing wins'

