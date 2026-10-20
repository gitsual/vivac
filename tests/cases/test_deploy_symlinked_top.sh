#!/usr/bin/env bash
set -Eeuo pipefail

# A home whose top-level directory (.local, .config) is a symlink to a directory
# somewhere else (another disk): deploy.sh keeps that symlink as it is and links
# the package files into the directory it points at. Stow alone refuses such a
# home ("existing target is not owned by stow: .local").

repo_root="${REPO_ROOT:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)}"
deploy="$repo_root/scripts/deploy.sh"
sandbox="$(mktemp -d "${TMPDIR:-/tmp}/vivac-symtop.XXXXXX")"
trap 'rm -rf -- "$sandbox"' EXIT
fail() {
	printf '%s\n' "$1" >&2
	exit 1
}
tree() { (cd "$1" && find . -printf '%p %y %m %l\n' | LC_ALL=C sort && find . -type f -exec sha256sum {} + | LC_ALL=C sort -k2); }

for top in .local .config; do
	home="$sandbox/home$top" ext="$sandbox/ext$top"
	mkdir -p -- "$home" "$ext/keep"
	printf 'elsewhere\n' >"$ext/keep/file"
	ln -s -- "$ext" "$home/$top" # absolute, outside the home
	if [[ "$top" == .config ]]; then
		mkdir -p -- "$ext/hypr"
		printf 'owner hyprland\n' >"$ext/hypr/hyprland.lua"
		printf 'owner paper\n' >"$ext/hypr/hyprpaper.conf"
	fi
	before="$(tree "$ext")"
	run() { HOME="$home" XDG_STATE_HOME="$sandbox/state$top" DEPLOY_BACKUP_ROOT="$sandbox/bk$top" "$deploy" --no-theme --protect .config/hypr/hyprpaper.conf "$@"; }

	out="$(run --dry-run hypr welcome 2>&1)" || fail "$top: the dry run failed: $out"
	[[ "$(tree "$ext")" == "$before" ]] || fail "$top: the dry run changed the directory behind the symlink"

	out="$(run hypr welcome 2>&1)" || fail "$top: deploy failed: $out"
	[[ -L "$home/$top" && "$(readlink -- "$home/$top")" == "$ext" ]] || fail "$top: the symlink itself was changed"
	if [[ "$top" == .local ]]; then
		link="$ext/bin/vivac-welcome"
		want="$repo_root/dotfiles/welcome/.local/bin/vivac-welcome"
	else
		link="$ext/hypr/hyprland.lua"
		want="$repo_root/dotfiles/hypr/.config/hypr/hyprland.lua"
		[[ "$(<"$ext/hypr/hyprpaper.conf")" == 'owner paper' && ! -L "$ext/hypr/hyprpaper.conf" ]] || fail "$top: a protected file behind the symlink was touched"
		cmp -s "$sandbox/bk$top/.config/hypr/hyprland.lua" <(printf 'owner hyprland\n') || fail "$top: the owner's file is not in the backup"
	fi
	[[ -L "$link" && "$(readlink -f -- "$link")" == "$want" ]] || fail "$top: $link is not a link into the checkout"
	[[ "$(<"$ext/keep/file")" == elsewhere ]] || fail "$top: a file behind the symlink was lost"

	run hypr welcome >/dev/null 2>&1 || fail "$top: a second deploy failed"
	[[ -L "$home/$top" && "$(readlink -f -- "$link")" == "$want" ]] || fail "$top: the second deploy broke the links"
done
printf 'symlinked top-level directories: deployed into the resolved directory, symlink and protect list kept\n'
