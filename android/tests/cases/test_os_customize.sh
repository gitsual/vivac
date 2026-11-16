#!/usr/bin/env bash
set -Eeuo pipefail

# vivac-os-customize applies the vivac patches to a synced GrapheneOS tree.
# Patches live in PATCH_DIR/<project path>/*.patch (applied in name order).
# Before applying, each touched project is reset to its committed state, so a
# rerun gives the same tree. A patch that no longer applies (upstream moved)
# makes it fail and leaves that project clean, never half-patched.

repo_root="${REPO_ROOT:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)}"
tool="$repo_root/os/bin/vivac-os-customize"

fail() {
	printf '%s\n' "$1" >&2
	exit 1
}
sandbox="$(mktemp -d "${TMPDIR:-/tmp}/vivac-os-customize.XXXXXX")"
trap 'rm -rf -- "$sandbox"' EXIT
src="$sandbox/src" patches="$sandbox/patches"
proj="$src/packages/apps/Updater"
mkdir -p "$proj/res/values" "$patches/packages/apps/Updater"
git -C "$proj" init -q
printf '<string name="url">https://releases.grapheneos.org/</string>\n' >"$proj/res/values/config.xml"
git -C "$proj" -c user.name=t -c user.email=t@t add -A
git -C "$proj" -c user.name=t -c user.email=t@t commit -qm base
sed 's|releases.grapheneos.org|updates.example.test|' "$proj/res/values/config.xml" >"$sandbox/new.xml"
(cd "$proj" && diff -u res/values/config.xml "$sandbox/new.xml" |
	sed -e '1s|.*|--- a/res/values/config.xml|' -e '2s|.*|+++ b/res/values/config.xml|') >"$patches/packages/apps/Updater/0001-url.patch" || true

run() { bash "$tool" "$src" "$patches"; }

run >/dev/null || fail "patch did not apply"
grep -q updates.example.test "$proj/res/values/config.xml" || fail "url not changed"
run >/dev/null || fail "second run failed (not idempotent)"
[[ "$(grep -c updates.example.test "$proj/res/values/config.xml")" == 1 ]] || fail "patched twice"

# Upstream changes the line the patch touches: refuse, leave the project clean.
git -C "$proj" checkout -q -- .
printf '<string name="url">https://moved.example/</string>\n' >"$proj/res/values/config.xml"
git -C "$proj" -c user.name=t -c user.email=t@t commit -qam upstream-moved
if run >/dev/null 2>&1; then fail "accepted a patch that no longer applies"; fi
[[ -z "$(git -C "$proj" status --porcelain)" ]] || fail "left the project half-patched"

if bash "$tool" "$src" "$sandbox/nope" >/dev/null 2>&1; then fail "accepted a missing patch folder"; fi
mkdir -p "$patches/../badpatches/not/a/project" && printf 'x\n' >"$patches/../badpatches/not/a/project/1.patch"
if bash "$tool" "$src" "$patches/../badpatches" >/dev/null 2>&1; then fail "accepted a patch for a project that is not in the tree"; fi
