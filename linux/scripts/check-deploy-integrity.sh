#!/usr/bin/env bash
set -Eeuo pipefail

# Deployment integrity: the two ways files reach a machine (Stow for committed
# dotfiles, render-config.sh for machine-specific renders) must never fight
# over a path, never write into the checkout, and never leave a package or a
# fragment behind silently.
#
# Static checks read the tree. The dynamic check deploys both paths into a
# disposable HOME and inspects what landed there.

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
# shellcheck source=lib/kv.sh
source "$repo_root/lib/kv.sh"
# shellcheck source=lib/render.sh
source "$repo_root/lib/render.sh"

status=0
problem() {
	printf 'deploy integrity: %s\n' "$1" >&2
	status=1
}

# --- every Stow package directory is one deploy.sh knows about ------------------
declared="$(sed -n 's/^packages=(\(.*\))$/\1/p' "$repo_root/scripts/deploy.sh" | tr ' ' '\n' | LC_ALL=C sort)"
present="$(find "$repo_root/dotfiles" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | LC_ALL=C sort)"
[[ -n "$declared" ]] || problem 'could not read the package list from scripts/deploy.sh'
if [[ "$declared" != "$present" ]]; then
	problem "dotfiles/ packages differ from deploy.sh's list: $(diff <(printf '%s\n' "$declared") <(printf '%s\n' "$present") | grep '^[<>]' | tr '\n' ' ')"
fi

# --- render outputs stay under ~/.config and never collide with a stowed file ----
mapfile -t templates < <(find "$repo_root/render" -type f -name '*.in' | LC_ALL=C sort)
((${#templates[@]})) || problem 'no deploy-time templates under render/'
declare -A render_targets=()
for template in "${templates[@]}"; do
	relative="${template#"$repo_root"/}"
	target="${relative#render/}"
	target="${target%.in}"
	case "/$target/" in
	*/../* | */./*) problem "template escapes its directory: $relative" ;;
	esac
	[[ "$target" != /* ]] || problem "template names an absolute path: $relative"
	render_targets[".config/$target"]="$relative"
	while IFS= read -r stowed; do
		problem "$relative renders to ~/.config/$target, which package '${stowed#"$repo_root"/dotfiles/}' also stows"
	done < <(find "$repo_root/dotfiles" -mindepth 2 -path "$repo_root/dotfiles/*/.config/$target" -print)
done

# --- Hyprland loads exactly the fragments that exist, and every fragment is loaded
# hyprland.lua says fragment("name") for exactly the fragments that exist.
lua_conf="$repo_root/dotfiles/hypr/.config/hypr/hyprland.lua"
mapfile -t loaded < <(sed -n 's/^fragment("\([a-z]*\)")$/\1/p' "$lua_conf" | LC_ALL=C sort)
mapfile -t lua_fragments < <(find "$repo_root/render/hypr/generated" -type f -name '*.lua.in' -printf '%f\n' 2>/dev/null | sed 's/\.lua\.in$//' | LC_ALL=C sort)
if [[ "${loaded[*]}" != "${lua_fragments[*]}" ]]; then
	problem "hyprland.lua loads [${loaded[*]}] but render/hypr/generated/ provides [${lua_fragments[*]}]"
fi

# --- a real deploy of both paths into a disposable HOME ----------------------------
hash_checkout() {
	(
		cd "$repo_root"
		find dotfiles render templates data -type f -print0 | LC_ALL=C sort -z | xargs -0 sha256sum
	)
}
sandbox="$(mktemp -d "${TMPDIR:-/tmp}/vivac-integrity.XXXXXX")"
trap 'rm -rf -- "$sandbox"' EXIT
home="$sandbox/home"
mkdir -p -- "$home"
hash_checkout >"$sandbox/before"

HOME="$home" XDG_STATE_HOME="$sandbox/state" "$repo_root/scripts/deploy.sh" --all >/dev/null
HOME="$home" XDG_CONFIG_HOME="$home/.config" XDG_STATE_HOME="$sandbox/state" \
	FACTS_FILE="$repo_root/tests/golden/vm-virtio/hardware-facts" FACTS_OVERRIDE="$sandbox/none" \
	"$repo_root/scripts/render-config.sh" --deploy >/dev/null

hash_checkout >"$sandbox/after"
cmp -s "$sandbox/before" "$sandbox/after" || problem 'deploying into a sandbox changed the checkout'

# Every link Stow made points into dotfiles/; nothing else in HOME points into
# the checkout at all.
links=0
while IFS= read -r -d '' link; do
	links=$((links + 1))
	resolved="$(readlink -f -- "$link")"
	[[ "$resolved" == "$repo_root/dotfiles/"* ]] || problem "stowed link resolves outside dotfiles/: $link -> $resolved"
done < <(find "$home" -type l -print0)
((links > 0)) || problem 'the sandbox deploy produced no Stow links'

# Every render landed as a regular file whose real path is outside the checkout.
for target in "${!render_targets[@]}"; do
	path="$home/$target"
	[[ -f "$path" && ! -L "$path" ]] || problem "render is not a regular file: $target"
	resolved="$(readlink -f -- "$path")"
	[[ "$resolved" != "$repo_root"* ]] || problem "render resolves inside the checkout: $target"
done

# The two paths together left no file that neither owns: a stray would be a
# write nobody can account for.
while IFS= read -r -d '' file; do
	relative="${file#"$home"/}"
	[[ -v render_targets["$relative"] ]] || problem "unowned file after deploy: $relative"
done < <(find "$home" -type f -print0)

((status == 0)) || exit 1
printf 'deploy integrity: %d packages, %d stow links, %d renders, checkout untouched\n' \
	"$(printf '%s\n' "$present" | grep -c .)" "$links" "${#render_targets[@]}"
