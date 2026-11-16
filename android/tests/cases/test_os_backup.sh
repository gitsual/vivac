#!/usr/bin/env bash
set -Eeuo pipefail

# vivac-os-backup copies what a wipe would lose from the phone over adb, for
# the migration to vivac-os: build facts, the list of user apps with the
# store that installed each one, and the whole shared storage (/sdcard).
# It refuses unless exactly one phone is connected and it is the expected
# device, and it fails if the copied file count does not match the phone's.

repo_root="${REPO_ROOT:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)}"
tool="$repo_root/os/bin/vivac-os-backup"

fail() {
	printf '%s\n' "$1" >&2
	exit 1
}
sandbox="$(mktemp -d "${TMPDIR:-/tmp}/vivac-os-backup.XXXXXX")"
trap 'rm -rf -- "$sandbox"' EXIT
mkdir -p "$sandbox/bin" "$sandbox/phone/DCIM" "$sandbox/phone/Music"
printf 'a' >"$sandbox/phone/DCIM/p1.jpg"
printf 'b' >"$sandbox/phone/Music/s1.opus"

# A fake adb backed by $sandbox/phone. FAKE_DEVICES and FAKE_PRODUCT steer it.
cat >"$sandbox/bin/adb" <<'FAKE'
#!/usr/bin/env bash
phone="$FAKE_PHONE"
case "$1" in
devices) printf 'List of devices attached\n'; for d in $FAKE_DEVICES; do printf '%s\tdevice\n' "$d"; done ;;
shell)
	shift
	case "$*" in
	'getprop ro.product.device') printf '%s\n' "$FAKE_PRODUCT" ;;
	getprop*) printf '[ro.build.version.incremental]: [2026111300]\n' ;;
	'pm list packages -3 -i') printf 'package:org.fdroid.fdroid  installer=null\npackage:com.termux  installer=org.fdroid.fdroid\n' ;;
	'find /sdcard/ -type f'*) (cd "$phone" && find . -type f | sed 's|^\.|/sdcard|') ;;
	*) exit 3 ;;
	esac ;;
pull) mkdir -p "$3" && cp -r "$phone/." "$3/" ;;
*) exit 3 ;;
esac
FAKE
chmod +x "$sandbox/bin/adb"
export PATH="$sandbox/bin:$PATH" FAKE_PHONE="$sandbox/phone"

run() { bash "$tool" "$@"; }

out="$sandbox/out1"
FAKE_DEVICES=SERIAL1 FAKE_PRODUCT=shiba run "$out" >/dev/null || fail "backup of a good phone failed"
[[ -f "$out/sdcard/DCIM/p1.jpg" && -f "$out/sdcard/Music/s1.opus" ]] || fail "shared storage not copied"
grep -q $'^com.termux\torg.fdroid.fdroid$' "$out/packages.tsv" || fail "packages.tsv missing termux row"
grep -q $'^org.fdroid.fdroid\tnull$' "$out/packages.tsv" || fail "packages.tsv missing fdroid row"
grep -q 'ro.build.version.incremental' "$out/getprop.txt" || fail "build facts not saved"
grep -q 'Seedvault' "$out/CHECKLIST.md" || fail "manual checklist not written"

if FAKE_DEVICES='' FAKE_PRODUCT=shiba run "$sandbox/out2" >/dev/null 2>&1; then fail "ran with no phone"; fi
if FAKE_DEVICES='S1 S2' FAKE_PRODUCT=shiba run "$sandbox/out3" >/dev/null 2>&1; then fail "ran with two phones"; fi
if FAKE_DEVICES=S1 FAKE_PRODUCT=husky run "$sandbox/out4" >/dev/null 2>&1; then fail "ran on the wrong device"; fi
[[ ! -e "$sandbox/out2/sdcard" && ! -e "$sandbox/out4/sdcard" ]] || fail "copied data after refusing"

# The phone gains a file between the count and the copy: the copy no longer
# matches the phone, which must be reported as a failure.
mv "$sandbox/bin/adb" "$sandbox/bin/adb.real"
# shellcheck disable=SC2016 # the wrapper expands these itself
printf '#!/usr/bin/env bash\nif [[ $1 == pull ]]; then rm -f "$FAKE_PHONE/Music/s1.opus"; fi\nexec "%s" "$@"\n' "$sandbox/bin/adb.real" >"$sandbox/bin/adb"
chmod +x "$sandbox/bin/adb"
if FAKE_DEVICES=S1 FAKE_PRODUCT=shiba run "$sandbox/out5" >/dev/null 2>&1; then fail "accepted a copy that does not match the phone"; fi
