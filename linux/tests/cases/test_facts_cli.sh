#!/usr/bin/env bash
set -Eeuo pipefail

# The CLI is where the facts layer meets the filesystem, so these cases cover
# the things a library test cannot: that --dry-run really writes nothing, that
# the override file wins, that a machine-specific file never lands in the
# checkout, and that the generated output survives the privacy scanner.

repo_root="${REPO_ROOT:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)}"
cli="$repo_root/scripts/hardware-facts.sh"

sandbox="$(mktemp -d "${TMPDIR:-/tmp}/vivac-facts-cli.XXXXXX")"
trap 'rm -rf -- "$sandbox"' EXIT

fail() {
	printf '%s\n' "$1" >&2
	exit 1
}

# A laptop fixture, so the emitted values differ from whatever this host is and
# a leak from the live machine would be visible.
root="$sandbox/sysroot"
mkdir -p -- "$root/sys/class/dmi/id" "$root/sys/class/power_supply/BAT0" \
	"$root/sys/class/backlight/acpi_video0" "$root/sys/class/input/input3" \
	"$root/sys/class/net/wlan0/wireless" "$root/sys/class/bluetooth/hci0"
printf '10\n' >"$root/sys/class/dmi/id/chassis_type"
printf 'Battery\n' >"$root/sys/class/power_supply/BAT0/type"
printf 'SynPS/2 Synaptics TouchPad\n' >"$root/sys/class/input/input3/name"

facts="$sandbox/state/hardware-facts"
override="$sandbox/config/hardware-facts.override"
mkdir -p -- "$(dirname -- "$override")"

run() { SYSROOT="$root" FACTS_FILE="$facts" FACTS_OVERRIDE="$override" bash "$cli" "$@"; }

# --- before anything is emitted ---------------------------------------------
# Capture the status: under `set -e` an unguarded failing command would abort
# the test with its own exit code instead of reporting the assertion.
status=0
run --check >/dev/null 2>&1 || status=$?
((status == 3)) || fail "check: a missing facts file must exit 3, got $status"


# --- dry run writes nothing -------------------------------------------------
before="$(find "$sandbox" -type f | LC_ALL=C sort)"
output="$(run --dry-run)"
after="$(find "$sandbox" -type f | LC_ALL=C sort)"
[[ "$before" == "$after" ]] || fail 'dry-run: touched the filesystem'
[[ "$output" == *'chassis=laptop'* ]] || fail 'dry-run: did not report the fixture chassis'

# --- emit, then check -------------------------------------------------------
run --emit >/dev/null
[[ -r "$facts" ]] || fail 'emit: wrote no facts file'
run --check >/dev/null || fail 'check: refused a file it had just emitted'

grep -q '^chassis=laptop$' "$facts" || fail 'emit: fixture chassis not recorded'
grep -q '^has_battery=yes$' "$facts" || fail 'emit: fixture battery not recorded'

# Whatever this host is, the emitted file describes the FIXTURE.
[[ "$(run --print chassis)" == 'laptop' ]] || fail 'print: did not read the emitted fact'

# --- the override wins ------------------------------------------------------
printf 'chassis=desktop\nhas_touchpad=no\n' >"$override"
[[ "$(run --print chassis)" == 'desktop' ]] || fail 'print: the override did not win'
[[ "$(run --print has_touchpad)" == 'no' ]] || fail 'print: the override did not win for has_touchpad'
[[ "$(run --print has_wifi)" == 'yes' ]] || fail 'print: a fact absent from the override was lost'

# The override must not rewrite the generated file behind the user's back.
grep -q '^chassis=laptop$' "$facts" ||
	fail 'print: applying the override mutated the generated file'

# --- keys outside the allowlist are refused ---------------------------------
run --print hostname >/dev/null 2>&1 && fail 'print: answered for a non-allowlisted key'

# --- usage errors -----------------------------------------------------------
run --emit --check >/dev/null 2>&1 && fail 'usage: accepted two actions at once'
run --print >/dev/null 2>&1 && fail 'usage: accepted --print with no key'
run --nonsense >/dev/null 2>&1 && fail 'usage: accepted an unknown option'
run >/dev/null 2>&1 && fail 'usage: accepted no action at all'

# --- generated output is publishable ----------------------------------------
python3 "$repo_root/scripts/privacy-scan.py" "$facts" >/dev/null ||
	fail 'privacy: the generated facts file tripped the privacy scanner'

# --- nothing machine-specific lands in the checkout -------------------------
[[ ! -e "$repo_root/hardware-facts" ]] ||
	fail 'checkout: a generated facts file appeared in the repository'
# The VM gate runs this test on a tree exported without .git, so the ignore
# rule is asserted through git only where git can see a repository.
if git -C "$repo_root" rev-parse --git-dir >/dev/null 2>&1; then
	git -C "$repo_root" check-ignore -q hardware-facts ||
		fail 'checkout: the generated facts file is not gitignored'
else
	grep -Fxq 'hardware-facts' "$repo_root/.gitignore" ||
		fail 'checkout: .gitignore carries no rule for the generated facts file'
fi

printf 'facts cli: dry-run inert, override wins, allowlist enforced, output publishable\n'
