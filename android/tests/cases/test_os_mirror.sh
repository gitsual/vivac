#!/usr/bin/env bash
set -Eeuo pipefail

# vivac-os-mirror copies the local update server folder to the Pi with rsync
# in two passes: first the zips (and signatures), then the channel metadata,
# so the phone never reads metadata pointing at files not there yet. On the
# destination it keeps only the newest KEEP builds (default 2) to spare the SD
# card; builds named by any channel metadata are never removed.

repo_root="${REPO_ROOT:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)}"
tool="$repo_root/os/bin/vivac-os-mirror"

fail() {
	printf '%s\n' "$1" >&2
	exit 1
}
sandbox="$(mktemp -d "${TMPDIR:-/tmp}/vivac-os-mirror.XXXXXX")"
trap 'rm -rf -- "$sandbox"' EXIT
src="$sandbox/server" dst="$sandbox/pi"
mkdir -p "$src" "$dst" "$sandbox/bin"
for b in 2026101000 2026111300 2026121000; do
	printf 'O%s' "$b" >"$src/shiba-ota_update-$b.zip"
	printf 'I%s' "$b" >"$src/shiba-install-$b.zip"
	printf 'S%s' "$b" >"$src/shiba-install-$b.zip.sig"
done
printf '2026121000 1 shiba testing\n' >"$src/shiba-testing"
printf '2026101000 1 shiba stable\n' >"$src/shiba-stable"

# Record rsync passes to check the order (metadata strictly after zips).
cat >"$sandbox/bin/rsync" <<FAKE
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$sandbox/rsync.log"
exec /usr/bin/rsync "\$@"
FAKE
chmod +x "$sandbox/bin/rsync"
export PATH="$sandbox/bin:$PATH"

VIVAC_OS_MIRROR_KEEP=2 bash "$tool" "$src" "$dst" || fail "mirror failed"
for f in shiba-ota_update-2026121000.zip shiba-install-2026111300.zip.sig shiba-testing shiba-stable; do
	cmp -s "$src/$f" "$dst/$f" || fail "$f not mirrored"
done
# newest 2 kept (2026121000, 2026111300) + 2026101000 because stable names it
[[ -f "$dst/shiba-ota_update-2026101000.zip" ]] || fail "removed a build a channel still points at"

rm "$src/shiba-stable"; printf '2026121000 1 shiba stable\n' >"$src/shiba-stable"
VIVAC_OS_MIRROR_KEEP=2 bash "$tool" "$src" "$dst" || fail "second mirror failed"
[[ ! -e "$dst/shiba-ota_update-2026101000.zip" && ! -e "$dst/shiba-install-2026101000.zip.sig" ]] || fail "old build not pruned"
[[ -f "$dst/shiba-ota_update-2026111300.zip" ]] || fail "pruned a build inside KEEP"

mapfile -t lines <"$sandbox/rsync.log"
((${#lines[@]} >= 2)) || fail "expected two rsync passes"
[[ "${lines[0]}" == *"--exclude=*"* && "${lines[0]}" != *"shiba-testing"* ]] || fail "first pass does not hold back metadata"
if bash "$tool" "$sandbox/nope" "$dst" 2>/dev/null; then fail "accepted a missing source"; fi
