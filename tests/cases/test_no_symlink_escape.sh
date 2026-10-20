#!/usr/bin/env bash
set -Eeuo pipefail

# A deploy-time render must never write into the checkout, whatever the
# target directory points at. A folded Stow tree, or any hand-made link from
# ~/.config into the repository, is refused before a byte is written.

repo_root="${REPO_ROOT:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)}"
renderer="$repo_root/scripts/render-config.sh"

sandbox="$(mktemp -d "${TMPDIR:-/tmp}/vivac-escape.XXXXXX")"
trap 'rm -rf -- "$sandbox"' EXIT
home="$sandbox/home"
mkdir -p -- "$home/.config"

fail() {
	printf '%s\n' "$1" >&2
	exit 1
}
run() { HOME="$home" XDG_CONFIG_HOME="$home/.config" XDG_STATE_HOME="$sandbox/state" FACTS_FILE="$repo_root/tests/golden/vm-virtio/hardware-facts" FACTS_OVERRIDE="$sandbox/none" bash "$renderer" "$@"; }
hash_checkout() {
	(
		cd "$repo_root"
		find dotfiles templates render data -type f -print0 | LC_ALL=C sort -z | xargs -0 sha256sum
	)
}

hash_checkout >"$sandbox/before"

# ~/.config/hypr folded onto the repository, as `stow` without --no-folding
# would leave it: the generated/ directory would land inside dotfiles/.
ln -s -- "$repo_root/dotfiles/hypr/.config/hypr" "$home/.config/hypr"
# ~/.config/waybar linked one level deeper into the checkout.
ln -s -- "$repo_root/dotfiles/waybar/.config/waybar" "$home/.config/waybar"

for mode in --dry-run --deploy; do
	output="$(run "$mode" 2>&1)" && fail "$mode wrote through a link into the checkout"
	[[ "$output" == *'resolves inside the checkout'* ]] || fail "$mode: refusal did not name the cause: $output"
done

[[ ! -e "$repo_root/dotfiles/hypr/.config/hypr/generated" ]] || fail 'generated/ was created inside the checkout'
[[ ! -e "$repo_root/dotfiles/waybar/.config/waybar/config" ]] || fail 'a Waybar config was written into the checkout'
hash_checkout >"$sandbox/after"
cmp -s "$sandbox/before" "$sandbox/after" || fail 'the checkout changed'

# A link that resolves elsewhere is fine: the gate is about the checkout,
# not about symlinks.
rm -- "$home/.config/hypr" "$home/.config/waybar"
mkdir -p -- "$sandbox/elsewhere"
ln -s -- "$sandbox/elsewhere" "$home/.config/hypr"
run --deploy >/dev/null || fail 'a link outside the checkout was refused'
[[ -f "$sandbox/elsewhere/generated/monitors.lua" ]] || fail 'render did not follow the harmless link'

printf 'symlink escape: refused for 2 links into the checkout, allowed elsewhere\n'
