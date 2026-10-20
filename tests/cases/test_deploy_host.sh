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
# --- the rollback doc ----------------------------------------------------------------------------------------
doc="$repo_root/docs/host-deploy.md"
# shellcheck disable=SC2016,SC2088  # literal doc text: tildes, braces and backticks are not expanded
for needle in 'deploy-host.sh --rollback' 'mv ~/.config/hypr/hyprland.lua{,.vivac}' '~/.local/state/vivac/backups/<stamp>' \
	'MANIFEST' 'generated/{hardware,input,monitors}.conf' '.bashrc' 'screenshot.sh' 'hyprpaper.conf' 'ws-refresh.sh' \
	'Only Lua-level breakage in `local.lua` is contained' 'Errors Hyprland records itself'; do
	grep -qF -- "$needle" "$doc" || fail "docs/host-deploy.md does not say: $needle"
done
grep -q 'host-deploy.md' "$repo_root/README.md" || fail 'README.md does not point at docs/host-deploy.md'
grep -q 'host-deploy.md' "$repo_root/docs/keys.md" || fail 'docs/keys.md does not point at docs/host-deploy.md'
printf 'host deploy: refusals, dry run, protect list, backups, VIVAC_REPO and rollback verified\n'
