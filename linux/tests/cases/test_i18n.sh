#!/usr/bin/env bash
# shellcheck disable=SC2016  # injection literals are quoted single on purpose throughout
set -Eeuo pipefail

# Translation tables are the third flat-file input a contributor edits, and
# the one whose values end up on screen. These cases pin: a value never
# executes, a gap is visible rather than silent, placeholders are literal
# substitution, and the coverage gate refuses each way a table can rot.

repo_root="${REPO_ROOT:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)}"
# shellcheck source=/dev/null
source "$repo_root/lib/kv.sh"
# shellcheck source=/dev/null
source "$repo_root/lib/i18n.sh"
gate="$repo_root/scripts/check-i18n-coverage.sh"

sandbox="$(mktemp -d "${TMPDIR:-/tmp}/vivac-i18n.XXXXXX")"
trap 'rm -rf -- "$sandbox"' EXIT
mkdir -p -- "$sandbox/i18n" "$sandbox/data"

fail() {
	printf '%s\n' "$1" >&2
	exit 1
}

# shellcheck disable=SC2016  # the injection values are literal on purpose
printf '%s\n' '# keys: 4' \
	'greeting=Hello, {1}' \
	'both=Second {2} then first {1}' \
	'hostile=$(touch "'"$sandbox"'/pwned") `id` ${HOME}' \
	'only_english=Reference only' >"$sandbox/i18n/en.conf"
printf '%s\n' '# keys: 3' \
	'greeting=Hola, {1}' \
	'both=Segundo {2} y primero {1}' \
	'hostile=inofensivo' >"$sandbox/i18n/es.conf"

# --- English --------------------------------------------------------------------
i18n_load en "$sandbox/i18n"
[[ "$(i18n_get greeting)" == 'Hello, {1}' ]] || fail 'en: raw text'
[[ "$(i18n_format greeting World)" == 'Hello, World' ]] || fail 'en: substitution'
[[ "$(i18n_format both A B)" == 'Second B then first A' ]] || fail 'placeholders are positional, not ordered'
[[ "$(i18n_format greeting '{2}$x')" == 'Hello, {2}$x' ]] || fail 'an argument is inserted literally'

# --- nothing executes -------------------------------------------------------------
value="$(i18n_get hostile)"
[[ "$value" == *'$(touch'* && "$value" == *'`id`'* ]] || fail 'hostile value was mangled instead of stored'
[[ ! -e "$sandbox/pwned" ]] || fail 'a translation reached a command position'

# --- Spanish: translated where present, visibly English where not --------------------
i18n_load es "$sandbox/i18n"
[[ "$(i18n_format greeting Mundo)" == 'Hola, Mundo' ]] || fail 'es: translation not used'
[[ "$(i18n_get only_english)" == '[en] Reference only' ]] || fail 'es: fallback must be marked'
[[ "$(i18n_get hostile)" == 'inofensivo' ]] || fail 'es: translated key must not fall back'

# --- unknown key: never empty, never a crash -----------------------------------------
out="$(i18n_get no.such.key || true)"
[[ "$out" == '[no.such.key]' ]] || fail "unknown key rendered as '$out'"
i18n_get no.such.key >/dev/null 2>&1 && fail 'unknown key must report failure'

# --- a language with no table at all falls back entirely, and says so --------------
i18n_load fr "$sandbox/i18n" 2>"$sandbox/fr.err"
[[ "$(i18n_get greeting)" == '[en] Hello, {1}' ]] || fail 'fr: no table must fall back to English'
grep -q 'no table for fr' "$sandbox/fr.err" || fail 'fr: missing table must be reported'

# --- the coverage gate ---------------------------------------------------------------
gate_on() { I18N_DIR="$sandbox/i18n" I18N_DATA_DIR="$sandbox/data" bash "$gate" >/dev/null 2>&1; }
# The sandbox es.conf above is deliberately incomplete; the gate must say so.
gate_on && fail 'gate: accepted a table missing a key'

printf '%s\n' '# keys: 4' 'greeting=Hola, {1}' 'both=Segundo {2} y primero {1}' 'hostile=inofensivo' \
	'only_english=Sólo referencia' >"$sandbox/i18n/es.conf"
gate_on || fail 'gate: refused two complete tables'

printf 'extra=Sobra\n' >>"$sandbox/i18n/es.conf"
sed -i 's/^# keys: 4/# keys: 5/' "$sandbox/i18n/es.conf"
gate_on && fail 'gate: accepted a key the reference lacks'
sed -i '/^extra=/d; s/^# keys: 5/# keys: 4/' "$sandbox/i18n/es.conf"

sed -i 's/^# keys: 4/# keys: 9/' "$sandbox/i18n/en.conf"
gate_on && fail 'gate: accepted a wrong declared count'
sed -i 's/^# keys: 9/# keys: 4/' "$sandbox/i18n/en.conf"

printf 'greeting=Hello again\n' >>"$sandbox/i18n/en.conf"
sed -i 's/^# keys: 4/# keys: 5/' "$sandbox/i18n/en.conf"
gate_on && fail 'gate: accepted a duplicate key'
sed -i '$d; s/^# keys: 5/# keys: 4/' "$sandbox/i18n/en.conf"

sed -i 's/^greeting=Hello, {1}/greeting=Hello, %s/' "$sandbox/i18n/en.conf"
gate_on && fail 'gate: accepted a printf directive in a value'
sed -i 's/^greeting=Hello, %s/greeting=Hello, {1}/' "$sandbox/i18n/en.conf"

printf '%s\n' $'# id\tmanifest\tpredicate\tsystem_flag\tlabel_key' \
	$'x\tpackages/x.txt\t\t--x\tselector.unknown' >"$sandbox/data/selectors.tsv"
gate_on && fail 'gate: accepted a registry label no table defines'
rm -- "$sandbox/data/selectors.tsv"
gate_on || fail 'gate: did not return to green'

printf 'i18n: values inert, fallback marked, placeholders literal, 6 gate scenarios refused\n'
