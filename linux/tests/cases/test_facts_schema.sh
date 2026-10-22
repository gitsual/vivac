#!/usr/bin/env bash
set -Eeuo pipefail

# The facts file is the one artefact of this repository that describes the
# user's actual machine, and it travels — into bug reports, into fixtures, into
# published examples. These cases pin the two guarantees that make that safe:
# nothing outside the allowlist is ever written, and a file from a different
# schema is refused rather than misread.

repo_root="${REPO_ROOT:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)}"
# shellcheck source=/dev/null
source "$repo_root/lib/kv.sh"
# shellcheck source=/dev/null
source "$repo_root/lib/facts.sh"

sandbox="$(mktemp -d "${TMPDIR:-/tmp}/vivac-facts.XXXXXX")"
trap 'rm -rf -- "$sandbox"' EXIT

fail() {
	printf '%s\n' "$1" >&2
	exit 1
}

# --- the allowlist is closed ------------------------------------------------
# A detector that learns something private must not be able to leak it: the
# forbidden keys below are exactly the categories ADR-4 rules out.
# shellcheck disable=SC2034  # passed by name to facts_emit
declare -A facts=(
	[chassis]='laptop'
	[virt]='none'
	[has_battery]='yes'
	[hostname]='redacted-hostname'
	[serial_number]='redacted-serial'
	# Deliberately not a syntactically valid MAC: the point of the case is the
	# KEY being refused, and a real-looking address would trip the repository's
	# own privacy scanner — which is exactly the leak this allowlist prevents.
	[mac_address]='redacted-link-layer-address'
	[pci_bus_address]='0000:01:00.0'
	[username]='redacted-username'
	[edid]='redacted-display-id'
)

emitted="$sandbox/facts"
if facts_emit facts "$emitted" 2>"$sandbox/emit.err"; then
	fail 'allowlist: emitting non-allowlisted keys must report failure'
fi

for forbidden in hostname serial_number mac_address pci_bus_address username edid; do
	if grep -q "^${forbidden}=" "$emitted"; then
		fail "allowlist: $forbidden reached the facts file"
	fi
	grep -q "$forbidden" "$sandbox/emit.err" ||
		fail "allowlist: $forbidden was dropped without telling anyone"
done

# The allowlisted facts must still be there — one bad key cannot block the rest.
for allowed in chassis virt has_battery; do
	grep -q "^${allowed}=" "$emitted" || fail "allowlist: dropped the valid key $allowed"
done

# Stated as a subset rather than a list, so adding a key to the allowlist in a
# later unit does not require editing this assertion.
while IFS='=' read -r key _; do
	[[ -z "$key" || "$key" == '#'* ]] && continue
	facts_key_allowed "$key" || fail "allowlist: emitted key outside the allowlist: $key"
done <"$emitted"

# --- the schema stamp is mandatory and checked ------------------------------
grep -q "^FACTS_SCHEMA=${FACTS_SCHEMA}\$" "$emitted" ||
	fail 'schema: emitted file carries no schema stamp'

facts_require_schema "$emitted" || fail 'schema: refused a file it had just written'

printf 'FACTS_SCHEMA=99\nchassis=desktop\n' >"$sandbox/future"
if facts_require_schema "$sandbox/future" 2>/dev/null; then
	fail 'schema: accepted a file from a future schema version'
fi

printf 'chassis=desktop\n' >"$sandbox/unstamped"
if facts_require_schema "$sandbox/unstamped" 2>/dev/null; then
	fail 'schema: accepted a file with no schema stamp'
fi

# --- the override file wins -------------------------------------------------
printf 'FACTS_SCHEMA=1\nchassis=vm\nhas_battery=no\n' >"$sandbox/override"
declare -A merged=()
facts_load merged "$emitted" "$sandbox/override"
[[ "${merged[chassis]}" == 'vm' ]] || fail 'merge: the override file did not win'
[[ "${merged[has_battery]}" == 'no' ]] || fail 'merge: the override file did not win for has_battery'
[[ "${merged[virt]}" == 'none' ]] || fail 'merge: a fact absent from the override was lost'

# A missing override is normal, not an error.
declare -A base_only=()
facts_load base_only "$emitted" "$sandbox/does-not-exist" ||
	fail 'merge: a missing override file must not fail the load'
[[ "${base_only[chassis]}" == 'laptop' ]] || fail 'merge: base facts lost when the override is absent'

# --- reading a fact ---------------------------------------------------------
[[ "$(facts_get "$emitted" chassis)" == 'laptop' ]] || fail 'facts_get: wrong value'
[[ "$(facts_get "$emitted" has_touchpad 'unknown')" == 'unknown' ]] ||
	fail 'facts_get: an absent fact must fall back to the default'

# Asking for a key outside the allowlist is a caller bug, and says so.
if facts_get "$emitted" hostname >/dev/null 2>&1; then
	fail 'facts_get: answered for a key outside the allowlist'
fi

printf 'facts: allowlist closed (6 private keys refused), schema enforced, override wins\n'
