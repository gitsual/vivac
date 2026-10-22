#!/usr/bin/env bash
set -Eeuo pipefail

# The predicate grammar is the one place where registry data would reach a
# command position if it were evaluated carelessly. These cases pin: nothing
# is ever executed, parse errors are caught before evaluation, && binds
# tighter than ||, ~ matches a word in a list, and the registry loader keeps
# empty columns in place.

repo_root="${REPO_ROOT:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)}"
# shellcheck source=/dev/null
source "$repo_root/lib/kv.sh"
# shellcheck source=/dev/null
source "$repo_root/lib/facts.sh"
# shellcheck source=/dev/null
source "$repo_root/lib/selectors.sh"

sandbox="$(mktemp -d "${TMPDIR:-/tmp}/vivac-selectors.XXXXXX")"
trap 'rm -rf -- "$sandbox"' EXIT

fail() {
	printf '%s\n' "$1" >&2
	exit 1
}

# shellcheck disable=SC2034  # passed by name
declare -A laptop=([chassis]='laptop' [gpu_vendors]='intel nvidia' [gpu_hybrid]='yes' [kernels]='linux linux-zen' [has_battery]='yes')
# shellcheck disable=SC2034
declare -A guest=([chassis]='vm' [gpu_vendors]='virtio' [gpu_hybrid]='no' [kernels]='linux' [has_battery]='no')

holds() { selector_predicate_holds "$1" "$2"; }

# --- evaluation ---------------------------------------------------------------
holds '' laptop || fail 'empty predicate must always hold'
holds 'chassis=laptop' laptop || fail '= on an equal value'
holds 'chassis=laptop' guest && fail '= on a different value'
holds 'chassis!=vm' laptop || fail '!= on a different value'
holds 'chassis!=vm' guest && fail '!= on an equal value'
holds 'gpu_vendors~nvidia' laptop || fail '~ must find a word in a list'
holds 'gpu_vendors~nvidia' guest && fail '~ must not match an absent word'
holds 'gpu_vendors~vidia' laptop && fail '~ matches whole words, not substrings'
holds 'kernels~linux' laptop || fail '~ must match the first word too'
holds 'monitor_count=2' laptop && fail 'an absent fact compares as empty, never as true'

# --- precedence: && binds tighter than || ---------------------------------------
holds 'chassis=vm || chassis=laptop && gpu_hybrid=yes' laptop || fail 'a || (b && c): right clause true'
holds 'chassis=vm || chassis=laptop && gpu_hybrid=no' laptop && fail 'a || (b && c): both false'
holds 'chassis=laptop && gpu_hybrid=no || has_battery=yes' laptop || fail '(a && b) || c: c true'
holds 'chassis=laptop && gpu_hybrid=no || has_battery=no' laptop && fail '(a && b) || c: all false'

# --- nothing is executed ---------------------------------------------------------
# shellcheck disable=SC2034,SC2016  # the value is a literal on purpose
declare -A hostile=([chassis]='$(touch "'"$sandbox"'/pwned")')
holds 'chassis=laptop' hostile && fail 'a hostile fact value compared equal'
[[ ! -e "$sandbox/pwned" ]] || fail 'a fact value reached a command position'

# --- parse errors are caught, and caught BEFORE evaluation ----------------------
# Ends in an explicit `return 0`: the && list returns 1 when validation fails
# (the expected case), and under set -e a bare call would abort the script.
bad() {
	selectors_validate_predicate "$1" 2>/dev/null && fail "accepted invalid predicate: $1"
	return 0
}
bad 'chassis'                       # no operator
bad 'chassis==laptop'               # unknown operator
bad 'chassis=laptop &&'             # dangling operator
bad '&& chassis=laptop'             # leading operator
bad 'chassis=laptop chassis=vm'     # two atoms, no operator
bad 'hostname=box'                  # key outside the fact allowlist
bad 'chassis=lap top'               # value with a space
# shellcheck disable=SC2016  # literal on purpose
bad 'chassis=$(id)'                 # shell in a value
selectors_validate_predicate 'chassis=vm || gpu_vendors~nvidia && kernels~linux-zen' ||
	fail 'rejected a valid predicate'
selectors_validate_predicate '' || fail 'rejected the empty predicate'

# --- the loader keeps empty columns in place -----------------------------------
registry="$sandbox/selectors.tsv"
printf '%s\n' \
	'# comment' \
	$'always\tpackages/a.txt\t\t--always\tselector.always' \
	$'only-vm\tpackages/b.txt\tchassis=vm\t--only-vm\tselector.vm' >"$registry"
selectors_load "$registry" || fail 'loader rejected a valid registry'
[[ "${SELECTOR_PREDICATE[always]}" == '' ]] || fail "empty predicate column shifted: got '${SELECTOR_PREDICATE[always]}'"
[[ "${SELECTOR_FLAG[always]}" == '--always' ]] || fail "flag column shifted: got '${SELECTOR_FLAG[always]}'"
[[ "${SELECTOR_LABEL[only-vm]}" == 'selector.vm' ]] || fail 'label column lost'
[[ "$(selector_for_flag --only-vm)" == 'only-vm' ]] || fail 'flag lookup failed'
selector_for_flag --nope >/dev/null && fail 'flag lookup matched an unknown flag'

[[ "$(selectors_applicable laptop | tr '\n' ' ')" == 'always ' ]] || fail 'laptop: wrong applicable set'
[[ "$(selectors_applicable guest | tr '\n' ' ')" == 'always only-vm ' ]] || fail 'guest: wrong applicable set'

# --- malformed registry rows are errors, not skips ---------------------------------
for row in \
	$'Bad Id\tpackages/x.txt\t\t--x\tl' \
	$'x\tpackages/x.txt\t\tno-dashes\tl' \
	$'x\tpackages/x.txt\tchassis\t--x\tl' \
	$'x\tpackages/x.txt\t\t--x' \
	$'always\tpackages/x.txt\t\t--x\tl\nalways\tpackages/y.txt\t\t--y\tm'; do
	printf '%s\n' "$row" >"$registry"
	selectors_load "$registry" 2>/dev/null && fail "loader accepted a malformed row: $row"
done

printf 'selectors: grammar evaluated without eval, precedence pinned, 8 parse errors caught\n'
