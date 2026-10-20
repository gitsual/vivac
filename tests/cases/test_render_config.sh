#!/usr/bin/env bash
set -Eeuo pipefail

# The deploy-time renderer writes only under the user's config directory,
# backs up whatever it replaces the way deploy.sh does, is idempotent, and
# reports drift once the facts or the deployed files change.

repo_root="${REPO_ROOT:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)}"
renderer="$repo_root/scripts/render-config.sh"
facts="$repo_root/tests/golden/desktop-nvidia/hardware-facts"

sandbox="$(mktemp -d "${TMPDIR:-/tmp}/vivac-render-config.XXXXXX")"
trap 'rm -rf -- "$sandbox"' EXIT
home="$sandbox/home"
state="$sandbox/state"
mkdir -p -- "$home/.config/waybar" "$state"

fail() {
	printf '%s\n' "$1" >&2
	exit 1
}
run() { HOME="$home" XDG_CONFIG_HOME="$home/.config" XDG_STATE_HOME="$state" FACTS_FILE="$facts" FACTS_OVERRIDE="$sandbox/override" bash "$renderer" "$@"; }
hash_checkout() {
	(
		cd "$repo_root"
		find dotfiles templates render data -type f -print0 | LC_ALL=C sort -z | xargs -0 sha256sum
	)
}
backups() { compgen -G "$state/vivac/backups/*/.config/$1" || true; }

# A machine deployed before this unit still carries Stow's link to the Waybar
# config that no longer exists in the repository: a dangling symlink.
ln -s -- "$repo_root/dotfiles/waybar/.config/waybar/config" "$home/.config/waybar/config"

hash_checkout >"$sandbox/before"

# --- a dry run touches nothing -----------------------------------------------------
run --dry-run >"$sandbox/dry.out" || fail 'dry run failed'
grep -q "^would back up $home/.config/waybar/config" "$sandbox/dry.out" || fail 'dry run did not announce the backup'
grep -q "^would write $home/.config/hypr/generated/monitors.lua" "$sandbox/dry.out" || fail 'dry run did not announce the render'
[[ -L "$home/.config/waybar/config" ]] || fail 'dry run replaced the existing file'
[[ ! -e "$home/.config/hypr" ]] || fail 'dry run created output'
[[ -z "$(backups waybar/config)" ]] || fail 'dry run wrote a backup'

# --- a deploy writes into the config directory and nowhere else ----------------------
run --deploy >"$sandbox/deploy.out" || fail 'deploy failed'
for file in waybar/config hypr/generated/hardware.lua hypr/generated/monitors.lua hypr/generated/input.lua; do
	[[ -f "$home/.config/$file" && ! -L "$home/.config/$file" ]] || fail "not rendered as a regular file: $file"
done
hash_checkout >"$sandbox/after"
cmp -s "$sandbox/before" "$sandbox/after" || fail 'a deploy-time render changed the checkout'
mapfile -t moved < <(backups waybar/config)
[[ ${#moved[@]} -eq 1 && -L "${moved[0]}" ]] || fail 'the stale symlink was not moved to the backup location'
[[ ! -e "$home/.config/waybar/config.old" ]] || fail 'unexpected sidecar file'

# --- a second deploy is a no-op ------------------------------------------------------
run --deploy >"$sandbox/again.out" || fail 'second deploy failed'
grep -q '^rendered ' "$sandbox/again.out" && fail 'second deploy rewrote an unchanged file'
[[ "$(backups '*' | wc -l)" -eq 1 ]] || fail 'second deploy created another backup'
run --check-drift >/dev/null || fail 'fresh deploy reported drift'

# --- a hand edit or a changed fact is drift, and --deploy repairs it -------------
printf '%s\n' '# edited by hand' >>"$home/.config/hypr/generated/input.lua"
run --check-drift >/dev/null 2>&1 && fail 'drift check accepted a hand-edited render'
printf 'has_battery=yes\n' >"$sandbox/override"
run --deploy >/dev/null || fail 'repair deploy failed'
grep -q '"battery"' "$home/.config/waybar/config" || fail 'the override did not reach the render'
[[ "$(backups 'hypr/generated/input.lua' | wc -l)" -eq 1 ]] || fail 'the hand-edited file was not backed up before repair'
run --check-drift >/dev/null || fail 'drift remained after repair'

# --- no facts is an error with guidance, not an empty render -------------------------
rm -rf -- "$home/.config/hypr"
output="$(HOME="$home" XDG_STATE_HOME="$state" FACTS_FILE="$sandbox/absent" FACTS_OVERRIDE="$sandbox/absent" bash "$renderer" --deploy 2>&1)" && fail 'rendered without facts'
[[ "$output" == *'hardware-facts.sh --emit'* ]] || fail "missing-facts message lacks guidance: $output"
[[ ! -e "$home/.config/hypr" ]] || fail 'rendered output without facts'

# --- a committed template can never depend on the machine -------------------------------
mkdir -p -- "$sandbox/templates/hypr/.config/hypr"
cp -- "$repo_root/render/hypr/generated/hardware.lua.in" "$sandbox/templates/hypr/.config/hypr/hardware.lua.in"
if TEMPLATES_DIR="$sandbox/templates" RENDER_ROOT="$sandbox/out" bash "$repo_root/scripts/check-theme-drift.sh" --render >/dev/null 2>&1; then
	fail 'the committed render path accepted a guarded template'
fi

printf 'render-config: checkout untouched, backups honoured, drift detected and repaired\n'
