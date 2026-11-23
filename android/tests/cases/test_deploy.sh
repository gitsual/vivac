#!/usr/bin/env bash
set -Eeuo pipefail

# android/scripts/deploy.sh in a fake Termux ($PREFIX and $HOME in a
# sandbox): every android/bin tool is linked into $PREFIX/bin; a file the
# user already had there is moved to a timestamped backup, never deleted; the
# Termux:Boot script is written and executable and starts sshd with a wake
# lock; sshd_config ends up refusing passwords; Termux wears the theme named
# in ~/.config/vivac/settings (the terminal colours Linux's kitty wears), a
# colours file of the user's own being backed up first; a second run changes
# nothing; --dry-run writes nothing at all.

repo_root="${REPO_ROOT:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)}"
deploy="$repo_root/scripts/deploy.sh"

fail() {
	printf '%s\n' "$1" >&2
	exit 1
}
sandbox="$(mktemp -d "${TMPDIR:-/tmp}/vivac-deploy.XXXXXX")"
trap 'rm -rf -- "$sandbox"' EXIT
export PREFIX="$sandbox/usr" HOME="$sandbox/home"
mkdir -p "$PREFIX/bin" "$PREFIX/etc/ssh" "$HOME"
printf 'old mine\n' >"$PREFIX/bin/vivac-facts"
printf 'Port 8022\n#PasswordAuthentication yes\nPrintMotd yes\n' >"$PREFIX/etc/ssh/sshd_config"
mkdir -p "$HOME/.termux" "$HOME/.config/vivac"
printf 'background=#000000\n' >"$HOME/.termux/colors.properties"
printf 'theme=metropolis\n' >"$HOME/.config/vivac/settings"

snapshot() { (cd "$sandbox" && find . -printf '%p %y %l\n' | LC_ALL=C sort && find . -type f -exec md5sum {} + | LC_ALL=C sort); }

# Dry run: nothing changes.
before="$(snapshot)"
bash "$deploy" --dry-run >/dev/null || fail "dry run failed"
[[ "$(snapshot)" == "$before" ]] || fail "dry run changed files"

bash "$deploy" >/dev/null || fail "deploy failed"
for tool in "$repo_root"/bin/*; do
	name="$(basename "$tool")"
	[[ "$(readlink -- "$PREFIX/bin/$name")" == "$tool" ]] || fail "$name not linked into \$PREFIX/bin"
done
backup="$(find "$HOME/.local/state/vivac/backups" -type f -name vivac-facts)"
[[ -n "$backup" && "$(cat "$backup")" == 'old mine' ]] || fail "the user's own vivac-facts was not backed up"

boot="$HOME/.termux/boot/vivac"
[[ -x "$boot" ]] || fail "boot script missing or not executable"
grep -q 'termux-wake-lock' "$boot" || fail "boot script takes no wake lock"
grep -q 'sshd' "$boot" || fail "boot script does not start sshd"

conf="$PREFIX/etc/ssh/sshd_config"
grep -qx 'PasswordAuthentication no' "$conf" || fail "sshd still accepts passwords"
grep -qx 'PrintMotd yes' "$conf" || fail "deploy lost the user's sshd settings"
[[ "$(grep -c '^PasswordAuthentication' "$conf")" == 1 ]] || fail "PasswordAuthentication set twice"

colors="$HOME/.termux/colors.properties"
grep -qx 'background=#0b100f' "$colors" || fail "Termux background is not the theme's terminal background: $(cat "$colors")"
grep -qx 'foreground=#c9c9c8' "$colors" || fail "Termux foreground is not the theme's"
grep -qx 'cursor=#aaa875' "$colors" || fail "Termux cursor is not the theme's accent"
grep -q 'Written by vivac' "$colors" || fail "colours file not marked as vivac's"
mine="$(find "$HOME/.local/state/vivac/backups" -type f -name colors.properties)"
[[ -n "$mine" && "$(cat "$mine")" == 'background=#000000' ]] || fail "the user's own colours were not backed up"

after="$(snapshot)"
bash "$deploy" >/dev/null || fail "second deploy failed"
[[ "$(snapshot)" == "$after" ]] || fail "second deploy is not idempotent"
