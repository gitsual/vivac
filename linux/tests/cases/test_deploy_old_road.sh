#!/usr/bin/env bash
set -Eeuo pipefail

# A home deployed while the checkout's root was elsewhere (before linux/
# existed: <checkout>/dotfiles, kept reachable through a link) holds links Stow
# does not own as written, and Stow alone refuses every package over them. They
# lead to the very files of this checkout, so deploy.sh backs them up and
# remakes them; a link to anything else is still treated as the owner's.

repo_root="${REPO_ROOT:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)}"
deploy="$repo_root/scripts/deploy.sh"
sandbox="$(mktemp -d "${TMPDIR:-/tmp}/vivac-oldroad.XXXXXX")"
trap 'rm -rf -- "$sandbox"' EXIT
fail() {
	printf '%s\n' "$1" >&2
	exit 1
}

home="$sandbox/home"
road="$sandbox/old-root" # the old road: a link standing where the root used to be
ln -s -- "$repo_root" "$road"
mkdir -p -- "$home/.local/bin" "$home/.config/hypr" "$sandbox/elsewhere"
welcome=.local/bin/vivac-welcome
hypr=.config/hypr/hyprland.lua
ln -s -- "$road/dotfiles/welcome/$welcome" "$home/$welcome"
ln -s -- "../../../old-root/dotfiles/hypr/$hypr" "$home/$hypr"
printf 'the owner\n' >"$sandbox/elsewhere/hyprpaper.conf"
ln -s -- "$sandbox/elsewhere/hyprpaper.conf" "$home/.config/hypr/hyprpaper.conf"
run() { HOME="$home" XDG_STATE_HOME="$sandbox/state" DEPLOY_BACKUP_ROOT="$sandbox/bk" "$deploy" --no-theme "$@"; }

out="$(run --dry-run hypr welcome 2>&1)" || fail "the dry run refused the old links: $out"
[[ "$out" == *"would back up $home/$welcome"* ]] || fail "the dry run did not plan the old link: $out"
[[ "$(readlink -- "$home/$welcome")" == "$road/"* ]] || fail 'the dry run changed a link'

out="$(run hypr welcome 2>&1)" || fail "deploy refused the old links: $out"
for rel in "$welcome" "$hypr"; do
	link="$home/$rel"
	[[ -L "$link" ]] || fail "$rel is not a link"
	[[ "$(readlink -- "$link")" != *old-root* ]] || fail "$rel still goes the old road"
	[[ "$(readlink -f -- "$link")" == "$repo_root/dotfiles/"* ]] || fail "$rel does not lead into the checkout"
	[[ -L "$sandbox/bk/$rel" ]] || fail "the old link $rel is not in the backup"
done
[[ -L "$sandbox/bk/.config/hypr/hyprpaper.conf" && "$(readlink -- "$sandbox/bk/.config/hypr/hyprpaper.conf")" == "$sandbox/elsewhere/hyprpaper.conf" ]] || fail "the owner's link is not in the backup as it was"
[[ "$(<"$sandbox/elsewhere/hyprpaper.conf")" == 'the owner' ]] || fail "the owner's file behind a link was touched"

rm -rf -- "$sandbox/bk"
out="$(run hypr welcome 2>&1)" || fail "a second deploy failed: $out"
[[ ! -e "$sandbox/bk" ]] || fail "a second deploy backed up links it had just made: $out"

# Once the old road is gone, nothing points through it.
rm -- "$road"
[[ -z "$(find "$home" -xtype l -print -quit)" ]] || fail 'a link broke when the old road went away'
printf 'links made from an old checkout root: backed up and remade; a link elsewhere is backed up as it was\n'
