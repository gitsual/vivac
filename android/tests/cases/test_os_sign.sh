#!/usr/bin/env bash
set -Eeuo pipefail

# vivac-os-sign reads the key passphrase from KEYS/passphrase.cred. That
# credential is user-scoped: as a normal user, systemd-creds refuses
# system-scoped work (varlink PermissionDenied), so both ends use --user.
# The passphrase must reach generate-release.sh only through $password.

repo_root="${REPO_ROOT:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)}"
tool="$repo_root/os/bin/vivac-os-sign"

fail() {
	printf '%s\n' "$1" >&2
	exit 1
}
sandbox="$(mktemp -d "${TMPDIR:-/tmp}/vivac-os-sign.XXXXXX")"
trap 'rm -rf -- "$sandbox"' EXIT
root="$sandbox/root" src="$sandbox/root/src" path="$sandbox/path"
mkdir -p "$root/keys/shiba" "$src/script" "$path"
ln -s "$root/keys" "$src/keys"
printf 'sealed' >"$root/keys/passphrase.cred"

cat >"$path/systemd-creds" <<'EOF'
#!/usr/bin/env bash
[[ " $* " == *" --user "* ]] || { echo 'Failed to decrypt: org.varlink.service.PermissionDenied' >&2; exit 1; }
printf 's3cret'
EOF
cat >"$src/script/generate-release.sh" <<EOF
#!/usr/bin/env bash
printf '%s|%s\n' "\$*" "\$password" >"$sandbox/release"
EOF
chmod +x "$path/systemd-creds" "$src/script/generate-release.sh"

PATH="$path:$PATH" VIVAC_OS_ROOT="$root" bash "$tool" 2026111300 >/dev/null 2>"$sandbox/err" </dev/null ||
	fail "sign failed: $(tail -2 "$sandbox/err")"
[[ "$(cat "$sandbox/release")" == 'shiba 2026111300|s3cret' ]] || fail "release not signed with the sealed passphrase: $(cat "$sandbox/release")"

if bash "$tool" nope >/dev/null 2>&1; then fail "accepted a bad build number"; fi
