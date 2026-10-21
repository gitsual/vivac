#!/usr/bin/env bash
set -Eeuo pipefail

# scripts/deploy-host.sh on a synthetic host (a sandbox HOME, a stub Hyprland):
# the protect list, verify-before-live, the backups, the refusals and the rollback.

repo_root="${REPO_ROOT:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)}"
deploy="$repo_root/scripts/deploy-host.sh"
sandbox="$(mktemp -d "${TMPDIR:-/tmp}/vivac-host.XXXXXX")"
trap 'chmod -R u+w "$sandbox" 2>/dev/null; rm -rf -- "$sandbox"' EXIT
fail() {
	printf '%s\n' "$1" >&2
	exit 1
}

tok() { sed -nE "s/^$2=(.*)$/\1/p" "$1"; }
bg="$(tok "$repo_root/data/theme.conf" COLOR_BG)" cbg="$(tok "$repo_root/data/themes/carmen.conf" COLOR_BG)"

# A host with a configuration of its own: files the deploy must keep, files it replaces, files it recolours.
make_host() {
	local h="$1"
	mkdir -p -- "$h/.config/hypr/scripts" "$h/.config/hypr/generated" "$h/.config/waybar/scripts" "$h/.config/kitty" \
		"$h/.config/nvim" "$h/.config/vivac" "$h/.local/state/vivac"
	printf 'owner shell\n' >"$h/.bashrc"
	printf -- '-- owner main config\n' >"$h/.config/hypr/hyprland.lua"
	printf -- 'hl.bind("SUPER + A", hl.dsp.exec_cmd("owner"))\n-- no trailing newline' >"$h/.config/hypr/local.lua"
	printf 'owner paper\n' >"$h/.config/hypr/hyprpaper.conf"
	printf '#!/bin/sh\nowner shot\n' >"$h/.config/hypr/scripts/screenshot.sh"
	chmod +x "$h/.config/hypr/scripts/screenshot.sh"
	for name in hardware input monitors; do printf 'old hyprlang %s\n' "$name" >"$h/.config/hypr/generated/$name.conf"; done
	printf 'a Lua fragment from an earlier render\n' >"$h/.config/hypr/generated/input.lua"
	printf '{ "owner": "bar" }\n' >"$h/.config/waybar/config"
	printf '#!/bin/sh\nowner refresh\n' >"$h/.config/waybar/scripts/ws-refresh.sh"
	chmod +x "$h/.config/waybar/scripts/ws-refresh.sh"
	printf 'window#waybar { background: #%s; margin: 3px; }\n' "$bg" >"$h/.config/waybar/style.css"
	printf 'owner nvim\n' >"$h/.config/nvim/init.lua"
	printf 'theme=carmen\n' >"$h/.config/vivac/settings"
	cp -- "$repo_root/tests/golden/desktop-nvidia/hardware-facts" "$h/.local/state/vivac/hardware-facts"
}
# Everything under the host except the backups themselves: type, mode, link target, content.
snap() {
	(
		cd "$1"
		find . -path ./.local/state/vivac/backups -prune -o -printf '%p %y %m %l\n' | LC_ALL=C sort
		find . -path ./.local/state/vivac/backups -prune -o -type f -exec sha256sum {} + | LC_ALL=C sort -k2
	)
}
# A stub Hyprland: logs what it was asked and what local.lua it saw; STUB_EXIT picks the verdict.
cat >"$sandbox/hyprland" <<'STUB'
#!/usr/bin/env bash
dir="$(dirname -- "${*: -1}")"
printf 'call %s | local=%s\n' "$*" "$(head -n 1 "$dir/local.lua" 2>/dev/null)" >>"$STUB_LOG"
[[ "${STUB_EXIT:-0}" == 0 ]] || { printf 'stub: refusing this config\n'; exit 1; }
STUB
chmod +x "$sandbox/hyprland"
export STUB_LOG="$sandbox/log"
# A stub pacman: -T prints the packages named in STUB_MISSING and exits 127 if any, like the real one.
cat >"$sandbox/pacman" <<'STUB'
#!/usr/bin/env bash
[[ "$1" == -T ]] || exit 2
[[ -z "${STUB_MISSING:-}" ]] && exit 0
printf '%s\n' $STUB_MISSING
exit 127
STUB
chmod +x "$sandbox/pacman"
export PACMAN_BIN="$sandbox/pacman"
# run HOME [args] — the deploy against one host.
run() {
	local h="$1"
	shift
	HOME="$h" XDG_STATE_HOME="$h/.local/state" XDG_CONFIG_HOME="$h/.config" "$deploy" "$@"
}
refuses() { # refuses HOME PATTERN [args] — fails, says why, changes nothing
	local h="$1" pattern="$2" before out
	shift 2
	before="$(snap "$h")"
	out="$(run "$h" "$@" 2>&1)" && fail "the deploy went ahead: $pattern"
	grep -q -- "$pattern" <<<"$out" || fail "no explanation matching '$pattern': $out"
	[[ "$(snap "$h")" == "$before" ]] || fail "a refused deploy ($pattern) changed the host"
}

# --- refusals leave the host byte-identical -----------------------------------------------------------------
host="$sandbox/refuse"
make_host "$host"
: >"$STUB_LOG"
HYPRLAND_BIN="$sandbox/missing-hyprland" refuses "$host" 'not installed'
# A runtime dependency that is not installed (socat feeds the workspace strip, swaybg
# draws the wallpaper) leaves a desktop that looks deployed and silently is not.
HYPRLAND_BIN="$sandbox/hyprland" STUB_MISSING='socat swaybg' refuses "$host" 'pacman -S --needed socat swaybg'
HYPRLAND_BIN="$sandbox/hyprland" STUB_EXIT=1 refuses "$host" 'stub: refusing this config'
grep -q 'call --verify-config -c .*/hypr/hyprland.lua | local=hl.bind("SUPER + A"' "$STUB_LOG" || fail "the verifier did not see the host's local.lua: $(<"$STUB_LOG")"
grep -q "$host" <(grep '^call' "$STUB_LOG") && fail 'the verifier was pointed at the live config, not a staged one'
rm -- "$host/.config/hypr/local.lua"
HYPRLAND_BIN="$sandbox/hyprland" refuses "$host" 'no .*local.lua'
printf -- '-- mine\n' >"$host/.config/hypr/local.lua"
mkdir -p -- "$host/.local/state/vivac/backups"
chmod 500 "$host/.local/state/vivac/backups"
HYPRLAND_BIN="$sandbox/hyprland" refuses "$host" 'not writable'
chmod 700 "$host/.local/state/vivac/backups"

# --- the dry run reports and changes nothing --------------------------------------------------------------------
before="$(snap "$host")"
out="$(HYPRLAND_BIN="$sandbox/hyprland" run "$host" --dry-run)" || fail "dry run failed: $out"
[[ "$(snap "$host")" == "$before" ]] || fail 'the dry run changed the host'
for expected in 'would skip-protect .*/.bashrc' 'would skip-protect .*/ws-refresh.sh' 'would back up .*/hyprland.lua' \
	'would back up and remove .*/generated/hardware[.]conf' 'would recolour .*/waybar/style.css (carmen)' 'would back up and write .*/generated/input.lua' 'would write .*/generated/hardware.lua'; do
	grep -q -- "$expected" <<<"$out" || fail "the dry run did not report '$expected': $out"
done

# --- a deploy, with and without --all -----------------------------------------------------------------------
for flag in '' --all; do
	host="$sandbox/live$flag"
	make_host "$host"
	cp -a -- "$host" "$sandbox/pre$flag"
	before="$(snap "$host")"
	out="$(HYPRLAND_BIN="$sandbox/hyprland" run "$host" $flag)" || fail "deploy $flag failed: $out"
	root="$(sed -n 's/^backup: //p' <<<"$out" | tail -n 1)"
	[[ -d "$root" && -f "$root/MANIFEST" ]] || fail "no backup root printed: $out"
	grep -q -- "--rollback $root" <<<"$out" || fail 'the rollback command was not printed'
	for f in .bashrc .config/hypr/hyprpaper.conf .config/hypr/scripts/screenshot.sh .config/hypr/local.lua \
		.config/waybar/config .config/waybar/scripts/ws-refresh.sh; do
		{ [[ -f "$host/$f" && ! -L "$host/$f" ]] && cmp -s "$sandbox/pre$flag/$f" "$host/$f"; } || fail "$f was touched ($flag)"
		[[ ! -e "$root/$f" ]] || fail "$f was backed up although it is protected ($flag)"
	done
	[[ "$(stat -c %a "$host/.config/hypr/scripts/screenshot.sh")" == 755 ]] || fail 'a protected script lost its mode'
	[[ "$(readlink -f -- "$host/.config/hypr/hyprland.lua")" == "$repo_root/dotfiles/hypr/.config/hypr/hyprland.lua" ]] || fail 'hyprland.lua was not deployed'
	cmp -s "$sandbox/pre$flag/.config/hypr/hyprland.lua" "$root/.config/hypr/hyprland.lua" || fail "the owner's hyprland.lua is not in the backup"
	cmp -s "$sandbox/pre$flag/.config/nvim/init.lua" "$root/.config/nvim/init.lua" || fail 'the replaced nvim init.lua was not backed up'
	for name in hardware input monitors; do
		[[ -f "$host/.config/hypr/generated/$name.lua" && ! -e "$host/.config/hypr/generated/$name.conf" ]] || fail "$name: the Lua fragment is missing or the orphan stayed"
		cmp -s "$sandbox/pre$flag/.config/hypr/generated/$name.conf" "$root/.config/hypr/generated/$name.conf" || fail "the orphaned $name.conf was not backed up"
	done
	cmp -s "$sandbox/pre$flag/.config/hypr/generated/input.lua" "$root/.config/hypr/generated/input.lua" || fail 'the replaced Lua fragment was not backed up'
	# The owner's layouts are recoloured, not replaced.
	[[ -f "$host/.config/waybar/style.css" && ! -L "$host/.config/waybar/style.css" ]] || fail 'waybar/style.css was replaced'
	{ grep -qi "$cbg" "$host/.config/waybar/style.css" && grep -q 'margin: 3px' "$host/.config/waybar/style.css"; } || fail 'the colour overlay did not recolour the owner file in place'
	cmp -s "$sandbox/pre$flag/.config/waybar/style.css" "$root/.config/waybar/style.css" || fail 'the owner style.css original is not in the backup'
	# The session finds the checkout through the config, not through ~/vivac.
	[[ "$(<"$host/.config/vivac/repo")" == "$repo_root" ]] || fail 'the checkout location was not written'
	env_line="$(HOME="$host" XDG_CONFIG_HOME="$host/.config" XDG_STATE_HOME="$sandbox/nvim-state" XDG_CACHE_HOME="$sandbox/nvim-cache" XDG_DATA_HOME="$sandbox/nvim-data" nvim -l "$repo_root/tests/lua/hl_stub.lua" "$host/.config/hypr/hyprland.lua" | grep '^env VIVAC_REPO=')"
	[[ "$env_line" == "env VIVAC_REPO=$repo_root" ]] || fail "the deployed config would not export VIVAC_REPO: $env_line"

	# --- rollback: one command, the exact pre-deploy state --------------------------------------------------
	out="$(HYPRLAND_BIN="$sandbox/hyprland" run "$host" --rollback "$root")" || fail "rollback failed: $out"
	if [[ "$(snap "$host")" != "$before" ]]; then
		diff <(printf '%s\n' "$before") <(snap "$host") | head -n 20 >&2
		fail "the rollback did not restore the pre-deploy state ($flag)"
	fi
done
# --- helpers for the cases below -----------------------------------------------------------------------------
hl() { HYPRLAND_BIN="$sandbox/hyprland" run "$@"; }
backup_of() { sed -n 's/^backup: //p' <<<"$1" | tail -n 1; }
backups_in() { find "$1/.local/state/vivac/backups" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l; }

# --- deploy twice, then a bare rollback: the first deploy's backup, not an empty second ---------------------
host="$sandbox/twice"
make_host "$host"
before="$(snap "$host")"
out="$(hl "$host")" || fail "first deploy failed: $out"
first="$(backup_of "$out")"
out="$(hl "$host")" || fail "second deploy failed: $out"
[[ "$(backups_in "$host")" == 1 ]] || fail "a deploy that changed nothing kept a backup: $(find "$host/.local/state/vivac/backups" -mindepth 1 -maxdepth 1)"
grep -qi 'nothing' <<<"$out" || fail "the no-op deploy did not say it changed nothing: $out"
out="$(hl "$host" --rollback)" || fail "bare rollback failed: $out"
grep -qF -- "$first" <<<"$out" || fail "the bare rollback did not name the backup it used: $out"
[[ "$(snap "$host")" == "$before" ]] || fail 'deploy, deploy, bare rollback did not restore the pre-deploy host'
# A second deploy that did change something is the newest with content; a rolled-back backup is not picked again.
out="$(hl "$host")" || fail "re-deploy failed: $out"
orphan=hardware
printf 'old hyprlang again\n' >"$host/.config/hypr/generated/$orphan.conf"
mid="$(snap "$host")"
out="$(hl "$host")" || fail "deploy over a new orphan failed: $out"
second="$(backup_of "$out")"
[[ "$(backups_in "$host")" == 3 ]] || fail 'the changing deploy did not keep its own backup'
out="$(hl "$host" --rollback)" || fail "rollback of the second deploy failed: $out"
grep -qF -- "$second" <<<"$out" || fail 'bare rollback did not pick the newest backup with content'
[[ "$(snap "$host")" == "$mid" ]] || fail 'rolling back the second deploy did not return to the state before it'
out="$(hl "$host" --rollback)" || fail "second bare rollback failed: $out"
grep -qF -- "$second" <<<"$out" && fail 'a backup that was already rolled back was picked again'

# --- a MANIFEST is not trusted: nothing outside the host is deleted -------------------------------------------
host="$sandbox/tamper"
make_host "$host"
out="$(hl "$host")" || fail "tamper fixture: deploy failed: $out"
root="$(backup_of "$out")"
cp -- "$root/MANIFEST" "$sandbox/MANIFEST.good"
after="$(snap "$host")"
mkdir -p -- "$sandbox/victim" "$sandbox/victim-dir"
printf 'keep\n' >"$sandbox/victim/file" && printf 'keep\n' >"$sandbox/outside"
for line in "newtree	$sandbox/victim" "created	../outside" "created	$sandbox/outside" "newdir	$sandbox/victim-dir" "newdir	../../$sandbox/victim-dir" "overlaystate	../../x" "frobnicate	x"; do
	cp -- "$sandbox/MANIFEST.good" "$root/MANIFEST"
	printf '%s\n' "$line" >>"$root/MANIFEST"
	rc=0
	out="$(hl "$host" --rollback "$root" 2>&1)" || rc=$?
	((rc != 0)) || fail "a tampered MANIFEST was obeyed: $line"
	grep -qi 'refus' <<<"$out" || fail "no explanation for the tampered line '$line': $out"
	{ [[ -f "$sandbox/victim/file" && -f "$sandbox/outside" && -d "$sandbox/victim-dir" ]]; } || fail "a tampered MANIFEST deleted something outside the host: $line"
	[[ "$(snap "$host")" == "$after" ]] || fail "a refused rollback changed the host: $line"
done
cp -- "$sandbox/MANIFEST.good" "$root/MANIFEST"
# A backup that does not live under the state directory is refused unless forced.
cp -a -- "$root" "$sandbox/elsewhere"
out="$(hl "$host" --rollback "$sandbox/elsewhere" 2>&1)" && fail 'a backup outside the backups directory was accepted'
grep -qi 'refus' <<<"$out" || fail "no explanation for the foreign backup root: $out"
[[ "$(snap "$host")" == "$after" ]] || fail 'the refused foreign backup changed the host'
hl "$host" --rollback "$sandbox/elsewhere" --force >/dev/null || fail '--force did not let a foreign backup root through'
[[ "$(snap "$host")" != "$after" ]] || fail '--force rolled back nothing'

# --- the theme comes through the settings reader, not through sed --------------------------------------------
host="$sandbox/badtheme"
make_host "$host"
printf 'theme=../../x\n' >"$host/.config/vivac/settings"
HYPRLAND_BIN="$sandbox/hyprland" refuses "$host" 'theme'
host="$sandbox/crlf"
make_host "$host"
printf 'theme=carmen\r\n' >"$host/.config/vivac/settings"
out="$(hl "$host")" || fail "a CRLF settings file broke the deploy: $out"
grep -qi "$cbg" "$host/.config/waybar/style.css" || fail 'a CRLF theme line was not understood'

# --- the colour overlay state is rolled back with the files ---------------------------------------------------
host="$sandbox/overlaystate"
make_host "$host"
printf 'theme=carmen\n' >"$host/.config/vivac/settings"
overlay_tool() { XDG_STATE_HOME="$host/.local/state" "$repo_root/scripts/colour-overlay.sh" --apply "$1" --config-dir "$host/.config" >"$sandbox/ov.out" 2>&1; }
overlay_tool carmen || fail 'overlay fixture failed'
printf 'theme=gatsby\n' >"$host/.config/vivac/settings"
before="$(snap "$host")"
out="$(hl "$host")" || fail "deploy over an existing overlay state failed: $out"
root="$(backup_of "$out")"
hl "$host" --rollback "$root" >/dev/null || fail 'rollback over an overlay state failed'
[[ "$(snap "$host")" == "$before" ]] || fail 'rollback did not restore the colour overlay state'
overlay_tool gatsby || fail 'overlay after rollback failed'
grep -q 'skipped (edited)' "$sandbox/ov.out" && fail "after a rollback the overlay thinks the owner edited the file: $(<"$sandbox/ov.out")"
grep -qi "$(tok "$repo_root/data/themes/gatsby.conf" COLOR_BG)" "$host/.config/waybar/style.css" || fail 'the overlay no longer applies after a rollback'

# --- a deploy that dies half way puts the host back by itself -----------------------------------------------------
host="$sandbox/halfway"
make_host "$host"
before="$(snap "$host")"
mkdir -p -- "$sandbox/failbin"
# The simulation (the pre-flight) passes; the real run is what fails, after the backups moved files.
# shellcheck disable=SC2016  # the shim body is literal
printf '#!/bin/sh\nfor a in "$@"; do [ "$a" = --simulate ] && exec %s "$@"; done\necho "stow: simulated failure" >&2\nexit 1\n' "$(command -v stow)" >"$sandbox/failbin/stow"
chmod +x "$sandbox/failbin/stow"
rc=0
out="$(PATH="$sandbox/failbin:$PATH" hl "$host" 2>&1)" || rc=$?
((rc != 0)) || fail 'a failing stow did not fail the deploy'
grep -q 'stow: simulated failure' <<<"$out" || fail "the failure is not shown: $out"
grep -q 'rolled back automatically' <<<"$out" || fail "no word that the run rolled itself back: $out"
[[ "$(snap "$host")" == "$before" ]] || fail 'the failed deploy did not leave the host byte for byte as it was'
[[ -f "$host/.config/hypr/hyprland.lua" && ! -L "$host/.config/hypr/hyprland.lua" ]] || fail "the owner's hyprland.lua did not come back"
root="$(sed -n 's/^backup: //p' <<<"$out" | tail -n 1)"
[[ -z "$root" || -e "$root/ROLLED-BACK" ]] || fail 'the rolled-back backup is not marked, a bare --rollback would redo it'
hl "$host" --rollback >/dev/null 2>&1 && fail 'a bare --rollback found something to undo after the automatic one'
[[ "$(snap "$host")" == "$before" ]] || fail 'the bare --rollback after an automatic one changed the host'

# --- a signal, or a kill -9, mid-stow --------------------------------------------------------------------------
# Shims for the REAL stow only (the pre-flight simulation passes): "term" sleeps so the test can signal the
# deploy while stow runs; "kill9" SIGKILLs deploy-host itself, so no trap can run.
mkdir -p -- "$sandbox/slowbin" "$sandbox/killbin"
# shellcheck disable=SC2016  # the shim bodies are literal
{
	printf '#!/bin/sh\nfor a in "$@"; do [ "$a" = --simulate ] && exec %s "$@"; done\n' "$(command -v stow)"
	printf 'echo $$ >"$SHIM_DIR/stow.pid"\ntouch "$SHIM_DIR/started"\nexec sleep 60\n'
} >"$sandbox/slowbin/stow"
# shellcheck disable=SC2016
{
	printf '#!/bin/sh\nfor a in "$@"; do [ "$a" = --simulate ] && exec %s "$@"; done\n' "$(command -v stow)"
	printf 'p=$PPID\nwhile [ "$p" -gt 1 ]; do\n'
	printf '  case "$(tr "\\0" " " </proc/$p/cmdline)" in *deploy-host.sh*) kill -9 "$p"; break ;; esac\n'
	printf '  p=$(cut -d" " -f4 /proc/$p/stat)\ndone\nexit 1\n'
} >"$sandbox/killbin/stow"
chmod +x "$sandbox/slowbin/stow" "$sandbox/killbin/stow"

# INT is not in the list: a job started with & by a non-interactive shell (this test) has SIGINT ignored.
for sig in TERM HUP; do
	host="$sandbox/sig$sig"
	make_host "$host"
	before="$(snap "$host")"
	mkdir -p -- "$sandbox/shim$sig"
	SHIM_DIR="$sandbox/shim$sig" PATH="$sandbox/slowbin:$PATH" HYPRLAND_BIN="$sandbox/hyprland" HOME="$host" \
		XDG_STATE_HOME="$host/.local/state" XDG_CONFIG_HOME="$host/.config" "$deploy" >"$sandbox/sig.out" 2>&1 &
	pid=$!
	for _ in $(seq 100); do [[ -e "$sandbox/shim$sig/started" ]] && break; sleep 0.1; done
	[[ -e "$sandbox/shim$sig/started" ]] || fail "$sig: stow never started: $(<"$sandbox/sig.out")"
	[[ "$(snap "$host")" != "$before" ]] || fail "$sig: the deploy had not changed anything yet, the test proves nothing"
	kill -"$sig" "$pid"
	rc=0
	wait "$pid" || rc=$?
	((rc != 0)) || fail "$sig: the deploy reported success after the signal"
	grep -q 'rolled back automatically' "$sandbox/sig.out" || fail "$sig: no word that the run rolled itself back: $(<"$sandbox/sig.out")"
	grep -q '^backup: ' "$sandbox/sig.out" && fail "$sig: the success summary was printed"
	[[ "$(snap "$host")" == "$before" ]] || fail "$sig: the host is not byte for byte as it was"
	! kill -0 "$(<"$sandbox/shim$sig/stow.pid")" 2>/dev/null || fail "$sig: the stow child outlived the deploy"
done

host="$sandbox/kill9"
make_host "$host"
before="$(snap "$host")"
PATH="$sandbox/killbin:$PATH" hl "$host" >"$sandbox/k9.out" 2>&1 || true
sleep 1
[[ "$(snap "$host")" != "$before" ]] || fail 'kill -9: the deploy had not changed anything, the test proves nothing'
root="$(find "$host/.local/state/vivac/backups" -mindepth 1 -maxdepth 1 -type d | head -n 1)"
[[ -s "$root/MANIFEST" ]] || fail 'kill -9 left a backup without a MANIFEST'
hl "$host" --rollback "$root" >/dev/null || fail 'rollback after a kill -9 failed'
[[ "$(snap "$host")" == "$before" ]] || fail 'rollback after a kill -9 is not byte for byte'

# --- the owner's hyprland.lua is a symlink into their own dotfiles --------------------------------------------------
host="$sandbox/linked"
make_host "$host"
mkdir -p -- "$sandbox/owner-dotfiles"
printf -- '-- owner dotfiles main config\n' >"$sandbox/owner-dotfiles/hyprland.lua"
rm -- "$host/.config/hypr/hyprland.lua"
ln -s "$sandbox/owner-dotfiles/hyprland.lua" "$host/.config/hypr/hyprland.lua"
before="$(snap "$host")"
out="$(hl "$host")" || fail "deploy over a symlinked hyprland.lua failed: $out"
[[ "$(readlink -f -- "$host/.config/hypr/hyprland.lua")" == "$repo_root/dotfiles/hypr/.config/hypr/hyprland.lua" ]] || fail 'the symlinked hyprland.lua was not replaced'
[[ "$(<"$sandbox/owner-dotfiles/hyprland.lua")" == '-- owner dotfiles main config' ]] || fail "the owner's dotfiles file was written through the link"
hl "$host" --rollback "$(backup_of "$out")" >/dev/null || fail 'rollback over a symlinked hyprland.lua failed'
[[ "$(snap "$host")" == "$before" ]] || fail 'the symlink (and its target) did not come back'

# --- --without: an excluded package is neither stowed nor backed up ------------------------------------------
host="$sandbox/without"
make_host "$host"
mkdir -p -- "$host/.config/nvim/.git"
printf 'ref: refs/heads/main\n' >"$host/.config/nvim/.git/HEAD"
nvim_before="$(cd "$host/.config/nvim" && find . -printf '%p %y %m %l\n' | LC_ALL=C sort; find . -type f -exec sha256sum {} + | LC_ALL=C sort -k2)"
out="$(hl "$host" --dry-run --without nvim)" || fail "dry run with --without failed: $out"
grep -q 'skipped: nvim (--without)' <<<"$out" || fail "the dry run does not say nvim was skipped: $out"
grep -q '/nvim/' <<<"$out" && fail "the dry run still mentions nvim files: $out"
out="$(hl "$host" --without nvim)" || fail "deploy --without nvim failed: $out"
grep -q 'skipped: nvim (--without)' <<<"$out" || fail "the summary does not say nvim was skipped: $out"
[[ "$(cd "$host/.config/nvim" && find . -printf '%p %y %m %l\n' | LC_ALL=C sort; find . -type f -exec sha256sum {} + | LC_ALL=C sort -k2)" == "$nvim_before" ]] || fail '--without nvim touched ~/.config/nvim'
[[ ! -e "$(backup_of "$out")/.config/nvim" ]] || fail '--without nvim backed up nvim'
[[ "$(readlink -f -- "$host/.config/hypr/hyprland.lua")" == "$repo_root/dotfiles/hypr/.config/hypr/hyprland.lua" ]] || fail '--without nvim did not deploy hypr'
hl "$host" --rollback "$(backup_of "$out")" >/dev/null || fail 'rollback after --without failed'
host="$sandbox/without-refused"
make_host "$host"
for args in '--without hypr' '--without bogus' '--without' '--without hypr --without nvim'; do
	before="$(snap "$host")"
	# shellcheck disable=SC2086  # the words are the point
	if out="$(hl "$host" $args 2>&1)"; then fail "the deploy went ahead with: $args"; fi
	[[ "$(snap "$host")" == "$before" ]] || fail "'$args' changed the host"
done
out="$(hl "$host" --without hypr 2>&1 || true)"
grep -q 'point of this deploy' <<<"$out" || fail "--without hypr gave no clear reason: $out"
hl "$host" --without bogus >/dev/null 2>&1 && fail 'unknown package accepted'
unknown_status=0
hl "$host" --without bogus >/dev/null 2>&1 || unknown_status=$?
[[ "$unknown_status" -eq 2 ]] || fail "an unknown package exits $unknown_status, not 2"

# --- Stow is simulated before anything moves: a conflict a backup cannot resolve aborts untouched -----------
# A FILE where the package needs a directory: no backup of a package file clears that.
host="$sandbox/preflight"
make_host "$host"
printf 'not a directory\n' >"$host/.config/nwg-bar"
before="$(snap "$host")"
for flag in --dry-run ''; do
	rc=0
	# shellcheck disable=SC2086  # the flag is optional
	out="$(hl "$host" $flag 2>&1)" || rc=$?
	((rc != 0)) || fail "the deploy ($flag) went ahead over a conflict stow would abort on: $out"
	grep -q 'nwg-bar' <<<"$out" || fail "the conflict list does not name .config/nwg-bar ($flag): $out"
	grep -q 'nothing was changed' <<<"$out" || fail "no 'nothing was changed' ($flag): $out"
	[[ "$(snap "$host")" == "$before" ]] || fail "the pre-flight ($flag) let the host change"
	[[ -f "$host/.config/hypr/hyprland.lua" && ! -L "$host/.config/hypr/hyprland.lua" ]] || fail "hyprland.lua was moved ($flag)"
done
[[ "$(backups_in "$host")" -eq 0 ]] || fail 'the refused deploy left a backup directory'
# Files that a backup DOES clear are not conflicts: the ordinary deploy above already proves that.

# --- ~/.local is an absolute symlink to a directory on another disk (the owner's real layout) -----------------
host="$sandbox/symlocal"
make_host "$host"
mkdir -p -- "$sandbox/ext"
mv -- "$host/.local" "$sandbox/ext/.local"
mkdir -p -- "$sandbox/ext/.local/share/elsewhere"
printf 'kept\n' >"$sandbox/ext/.local/share/elsewhere/file"
ln -s -- "$sandbox/ext/.local" "$host/.local"
before="$(snap "$host")" ext_before="$(snap "$sandbox/ext")"
out="$(hl "$host" --dry-run 2>&1)" || fail "dry run over a symlinked .local failed: $out"
grep -q 'would stow: hypr nvim ricer welcome' <<<"$out" || fail "the dry run does not plan the stow: $out"
[[ "$(snap "$host")" == "$before" && "$(snap "$sandbox/ext")" == "$ext_before" ]] || fail 'the dry run changed a host with a symlinked .local'
out="$(hl "$host" 2>&1)" || fail "deploy over a symlinked .local failed: $out"
[[ -L "$host/.local" && "$(readlink -- "$host/.local")" == "$sandbox/ext/.local" ]] || fail 'the .local symlink itself was changed'
[[ -L "$sandbox/ext/.local/bin/vivac-welcome" && "$(readlink -f -- "$host/.local/bin/vivac-welcome")" == "$repo_root/dotfiles/welcome/.local/bin/vivac-welcome" ]] || fail 'the links did not land in the directory behind the symlink'
[[ "$(readlink -f -- "$host/.config/hypr/hyprland.lua")" == "$repo_root/dotfiles/hypr/.config/hypr/hyprland.lua" ]] || fail 'hyprland.lua was not deployed next to a symlinked .local'
[[ "$(<"$sandbox/ext/.local/share/elsewhere/file")" == kept ]] || fail 'a file behind the symlink was lost'
hl "$host" --rollback "$(backup_of "$out")" >/dev/null || fail 'rollback over a symlinked .local failed'
[[ "$(snap "$host")" == "$before" ]] || fail 'rollback did not restore the host with a symlinked .local'
[[ "$(snap "$sandbox/ext")" == "$ext_before" ]] || fail 'rollback left the directory behind the symlink different (links or directories remain)'

# --- the rollback doc ----------------------------------------------------------------------------------------
doc="$repo_root/docs/host-deploy.md"
# shellcheck disable=SC2016,SC2088  # literal doc text: tildes, braces and backticks are not expanded
for needle in 'deploy-host.sh --rollback' 'mv ~/.config/hypr/hyprland.lua{,.vivac}' '~/.local/state/vivac/backups/<stamp>' \
	'MANIFEST' 'generated/{hardware,input,monitors}.conf' '.bashrc' 'screenshot.sh' 'hyprpaper.conf' 'ws-refresh.sh' \
	'Only Lua-level breakage in `local.lua` is contained' 'Errors Hyprland records itself' \
	'newest backup that has something to undo' 'keeps no backup' '--force' '--without nvim' 'stow --simulate' 'rolled back automatically' 'A failed' 'kill -9' 'symlink to a directory elsewhere' '94afb84' '5e4eb8652b4776f139282a343f04a3a8c7f23cb0'; do
	grep -qF -- "$needle" "$doc" || fail "docs/host-deploy.md does not say: $needle"
done
grep -q 'host-deploy.md' "$repo_root/README.md" || fail 'README.md does not point at docs/host-deploy.md'
grep -q 'host-deploy.md' "$repo_root/docs/keys.md" || fail 'docs/keys.md does not point at docs/host-deploy.md'
printf 'host deploy: refusals, dry run, protect list, backups, VIVAC_REPO and rollback verified\n'
