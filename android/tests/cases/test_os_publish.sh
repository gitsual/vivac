#!/usr/bin/env bash
set -Eeuo pipefail

# vivac-os-publish copies a signed release into the static update server
# folder the phone's Updater reads, then writes the channel metadata
# "<device>-<channel>" LAST, so the phone never sees a build whose zips are
# not there yet. The timestamp comes from the release's own "<device>-testing"
# file. A release folder without exactly one OTA zip, or without that
# metadata, is refused and the server folder is left untouched.

repo_root="${REPO_ROOT:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)}"
tool="$repo_root/os/bin/vivac-os-publish"

fail() {
	printf '%s\n' "$1" >&2
	exit 1
}
sandbox="$(mktemp -d "${TMPDIR:-/tmp}/vivac-os-publish.XXXXXX")"
trap 'rm -rf -- "$sandbox"' EXIT
rel="$sandbox/release" srv="$sandbox/server"
mkdir -p "$rel" "$srv"
printf 'OTA' >"$rel/shiba-ota_update-2026111300.zip"
printf 'INSTALL' >"$rel/shiba-install-2026111300.zip"
printf 'SIG' >"$rel/shiba-install-2026111300.zip.sig"
printf '2026111300 1794537720 shiba testing\n' >"$rel/shiba-testing"

bash "$tool" "$rel" "$srv" testing || fail "publish to testing failed"
for f in shiba-ota_update-2026111300.zip shiba-install-2026111300.zip shiba-install-2026111300.zip.sig; do
	cmp -s "$rel/$f" "$srv/$f" || fail "$f not copied"
done
[[ "$(cat "$srv/shiba-testing")" == '2026111300 1794537720 shiba testing' ]] || fail "testing metadata wrong"
[[ ! -e "$srv/shiba-stable" ]] || fail "stable written without being asked"

bash "$tool" "$rel" "$srv" stable || fail "promote to stable failed"
[[ "$(cat "$srv/shiba-stable")" == '2026111300 1794537720 shiba stable' ]] || fail "stable metadata wrong"
[[ -z "$(find "$srv" -name '.*')" ]] || fail "left temporary files behind"

if bash "$tool" "$rel" "$srv" nightly 2>/dev/null; then fail "accepted an unknown channel"; fi

empty="$sandbox/empty" srv2="$sandbox/server2"
mkdir -p "$empty" "$srv2"
if bash "$tool" "$empty" "$srv2" testing 2>/dev/null; then fail "accepted a release without an OTA zip"; fi
cp "$rel/shiba-ota_update-2026111300.zip" "$empty/"
if bash "$tool" "$empty" "$srv2" testing 2>/dev/null; then fail "accepted a release without metadata"; fi
[[ -z "$(ls -A "$srv2")" ]] || fail "server folder touched by a refused publish"
