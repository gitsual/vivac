#!/usr/bin/env bash
# The fakes are shell source written out literally: their $ expands when they run.
# shellcheck disable=SC2016
set -Eeuo pipefail

# android/scripts/bootstrap.sh against fake pkg, git and deploy: installs the
# Termux packages vivac needs (python-cryptography from pkg, never pip, so
# nothing compiles on the phone); clones the repo the first time and only
# fast-forwards it after; then runs the android deploy from that checkout.

repo_root="${REPO_ROOT:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)}"
script="$repo_root/scripts/bootstrap.sh"

fail() {
	printf '%s\n' "$1" >&2
	exit 1
}
sandbox="$(mktemp -d "${TMPDIR:-/tmp}/vivac-bootstrap.XXXXXX")"
trap 'rm -rf -- "$sandbox"' EXIT
mkdir -p "$sandbox/bin" "$sandbox/home"
export CALLS="$sandbox/calls" HOME="$sandbox/home" PREFIX="$sandbox/usr"
: >"$CALLS"
cat >"$sandbox/bin/pkg" <<'FAKE'
#!/usr/bin/env bash
printf 'pkg %s\n' "$*" >>"$CALLS"
FAKE
cat >"$sandbox/bin/git" <<'FAKE'
#!/usr/bin/env bash
printf 'git %s\n' "$*" >>"$CALLS"
if [[ "$1" == clone ]]; then mkdir -p "${@: -1}/android/scripts"
	printf '#!/usr/bin/env bash\nprintf "deploy %%s\\n" "$*" >>"$CALLS"\n' >"${@: -1}/android/scripts/deploy.sh"; fi
FAKE
chmod +x "$sandbox/bin/"*

PATH="$sandbox/bin:$PATH" bash "$script" >/dev/null || fail "bootstrap failed"
calls="$(cat "$CALLS")"
grep -q '^pkg install -y .*python-cryptography' <<<"$calls" || fail "python-cryptography not from pkg: $calls"
for p in python openssh termux-api git; do
	grep -q "^pkg install -y .*\b$p\b" <<<"$calls" || fail "pkg install misses $p: $calls"
done
grep -q '^pip' <<<"$calls" && fail "bootstrap must not use pip"
grep -q "^git clone .* $HOME/vivac\$" <<<"$calls" || fail "repo not cloned to ~/vivac: $calls"
grep -qx 'deploy ' <<<"$calls" || fail "deploy not run: $calls"

: >"$CALLS"
PATH="$sandbox/bin:$PATH" bash "$script" >/dev/null || fail "second bootstrap failed"
calls="$(cat "$CALLS")"
grep -q '^git clone' <<<"$calls" && fail "second run cloned again"
grep -q "^git -C $HOME/vivac pull --ff-only" <<<"$calls" || fail "second run did not fast-forward: $calls"
