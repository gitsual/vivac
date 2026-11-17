#!/usr/bin/env bash
set -Eeuo pipefail

# vivac-os-build drives sync, patches, vendor generation and the build.
# envsetup.sh only exposes adevtool as an *alias*, and aliases do not expand in
# a non-interactive script, so the build must call vendor/adevtool/bin/run.
# Here every heavy step is a stub that records how it was called.

repo_root="${REPO_ROOT:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)}"
tool="$repo_root/os/bin/vivac-os-build"

fail() {
	printf '%s\n' "$1" >&2
	exit 1
}
sandbox="$(mktemp -d "${TMPDIR:-/tmp}/vivac-os-build.XXXXXX")"
trap 'rm -rf -- "$sandbox"' EXIT
bin="$sandbox/bin" root="$sandbox/root" src="$sandbox/root/src" calls="$sandbox/calls"
mkdir -p "$bin" "$sandbox/patches" "$src/build" "$src/vendor/adevtool/bin" "$src/script" "$sandbox/path"
cp "$tool" "$bin/vivac-os-build"
ln -s ../patches "$bin/../patches" 2>/dev/null || true
printf '#!/usr/bin/env bash\necho "sync $*" >>%q\n' "$calls" >"$bin/vivac-os-sync"
printf '#!/usr/bin/env bash\necho "customize" >>%q\n' "$calls" >"$bin/vivac-os-customize"
printf '#!/usr/bin/env bash\necho "yarn $*" >>%q\n' "$calls" >"$sandbox/path/yarn"
printf '#!/usr/bin/env bash\necho "adevtool $*" >>%q\n' "$calls" >"$src/vendor/adevtool/bin/run"
printf '#!/usr/bin/env bash\necho "finalize" >>%q\n' "$calls" >"$src/script/finalize.sh"
cat >"$src/build/envsetup.sh" <<EOF
alias adevtool='vendor/adevtool/bin/run'
lunch() { echo "lunch \$*" >>"$calls"; }
m() { echo "m \$*" >>"$calls"; }
EOF
chmod +x "$bin"/* "$sandbox/path/yarn" "$src/vendor/adevtool/bin/run" "$src/script/finalize.sh"

PATH="$sandbox/path:$PATH" VIVAC_OS_ROOT="$root" bash "$bin/vivac-os-build" 2026111300 >/dev/null 2>"$sandbox/err" ||
	fail "build failed: $(tail -3 "$sandbox/err")"
grep -qx 'adevtool generate-all -d shiba' "$calls" || fail "adevtool generate-all was not run"
grep -qx 'lunch shiba-cur-user' "$calls" || fail "lunch not run after vendor generation"
grep -qx 'finalize' "$calls" || fail "finalize.sh not run"

if bash "$bin/vivac-os-build" notatag >/dev/null 2>&1; then fail "accepted a bad tag"; fi
