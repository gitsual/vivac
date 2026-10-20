#!/usr/bin/env bash
set -Eeuo pipefail

# The deploy-integrity gate runs against a disposable copy of the checkout so
# each failure mode can be planted: a render colliding with a stowed file, a
# package deploy.sh does not know, a Hyprland source line with no template.

repo_root="${REPO_ROOT:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)}"

sandbox="$(mktemp -d "${TMPDIR:-/tmp}/vivac-integrity-test.XXXXXX")"
trap 'rm -rf -- "$sandbox"' EXIT
copy="$sandbox/repo"
mkdir -p -- "$copy"
# The build workdir and the release artifacts are gitignored but still on
# disk, and a build that failed leaves gigabytes of qcow2 behind. Copying them
# turns this gate's verdict into "disk quota exceeded", which tells a reader
# nothing about deployment.
tar --exclude=.git --exclude=.vm-test --exclude=.vm-image --exclude=dist --exclude=.audit -cf - -C "$repo_root" . | tar -xf - -C "$copy"

fail() {
	printf '%s\n' "$1" >&2
	exit 1
}
gate() { bash "$copy/scripts/check-deploy-integrity.sh"; }
expect_refusal() {
	local reason="$1" output
	output="$(gate 2>&1)" && fail "gate passed with $reason"
	[[ "$output" == *"$2"* ]] || fail "gate refused $reason without naming it: $output"
}

gate >/dev/null || fail 'baseline: the gate must pass on an unmodified copy'

# --- a stowed file at a render's path -------------------------------------------
printf '{}\n' >"$copy/dotfiles/waybar/.config/waybar/config"
expect_refusal 'a stow/render collision' 'also stows'
rm -- "$copy/dotfiles/waybar/.config/waybar/config"

# --- a package directory deploy.sh never deploys ---------------------------------
mkdir -p -- "$copy/dotfiles/extra/.config/extra"
printf 'x\n' >"$copy/dotfiles/extra/.config/extra/rc"
expect_refusal 'an undeclared package' "differ from deploy.sh's list"
rm -rf -- "$copy/dotfiles/extra"

# --- a source line with no template behind it --------------------------------------
printf 'source = ~/.config/hypr/generated/extra.conf\n' >>"$copy/dotfiles/hypr/.config/hypr/hyprland.conf"
expect_refusal 'a sourced fragment nobody renders' 'provides ['
sed -i '$d' "$copy/dotfiles/hypr/.config/hypr/hyprland.conf"

# --- a template nothing sources ------------------------------------------------------
printf '# orphan\n' >"$copy/render/hypr/generated/orphan.conf.in"
expect_refusal 'a fragment hyprland.conf never sources' 'provides ['
rm -- "$copy/render/hypr/generated/orphan.conf.in"

# --- the Lua loader and the Lua fragments must name each other ---------------------------
printf '# orphan\n' >"$copy/render/hypr/generated/orphan.lua.in"
expect_refusal 'a Lua fragment hyprland.lua never loads' 'hyprland.lua loads ['
rm -- "$copy/render/hypr/generated/orphan.lua.in"
printf 'fragment("extra")\n' >>"$copy/dotfiles/hypr/.config/hypr/hyprland.lua"
expect_refusal 'a loaded fragment nobody renders' 'hyprland.lua loads ['
sed -i '$d' "$copy/dotfiles/hypr/.config/hypr/hyprland.lua"

gate >/dev/null || fail 'the copy did not return to green'
printf 'deploy integrity: 6 planted faults refused, clean copy accepted\n'
