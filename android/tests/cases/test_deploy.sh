#!/usr/bin/env bash
set -Eeuo pipefail

# android/scripts/deploy.sh in a fake Termux ($PREFIX and $HOME in a
# sandbox): every android/bin tool is linked into $PREFIX/bin; a file the
# user already had there is moved to a timestamped backup, never deleted; the
# Termux:Boot script is written and executable and starts sshd with a wake
# lock; sshd_config ends up refusing passwords; a second run changes nothing;
# --dry-run writes nothing at all.

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

after="$(snapshot)"
bash "$deploy" >/dev/null || fail "second deploy failed"
[[ "$(snapshot)" == "$after" ]] || fail "second deploy is not idempotent"
