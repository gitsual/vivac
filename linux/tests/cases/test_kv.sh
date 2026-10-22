#!/usr/bin/env bash
set -Eeuo pipefail

# lib/kv.sh is the single parser for every flat file in the repository, and the
# values it handles come from generators, user overrides and fixtures. These
# cases pin the two properties everything else relies on: anything written can
# be read back byte-for-byte, and nothing in a value can reach a command.

repo_root="${REPO_ROOT:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)}"
# shellcheck source=/dev/null
source "$repo_root/lib/kv.sh"

sandbox="$(mktemp -d "${TMPDIR:-/tmp}/vivac-kv.XXXXXX")"
trap 'rm -rf -- "$sandbox"' EXIT

fail() {
	printf '%s\n' "$1" >&2
	exit 1
}

# --- round trip -------------------------------------------------------------
# One entry per hazard: the separator, the escape character itself, line
# terminators that would split a record, a tab, non-ASCII, backslashes, and
# shell metacharacters that must stay inert.
# shellcheck disable=SC2016  # the metacharacter entry is literal on purpose
declare -A original=(
	[plain]='desktop'
	[empty]=''
	[with_equals]='kb_options=ctrl:nocaps'
	[with_percent]='100% scaled, 50%% literal'
	[with_newline]=$'first\nsecond'
	[with_crlf]=$'carriage\r\nreturn'
	[with_tab]=$'left\tright'
	[non_ascii]='ñandú — 日本語 — Ćwikła'
	[backslashes]='C:\path\to\thing and \\ double'
	[shell_metachars]='$(touch "$sandbox/pwned"); `id`; ${HOME}; rm -rf /'
	[leading_space]='   padded   '
	[looks_like_comment]='# not a comment, a value'
)

kv_write "$sandbox/round-trip.conf" original '# header'

declare -A restored=()
kv_load "$sandbox/round-trip.conf" restored

for key in "${!original[@]}"; do
	[[ -v restored["$key"] ]] || fail "round trip: key lost on read: $key"
	if [[ "${restored["$key"]}" != "${original["$key"]}" ]]; then
		printf 'round trip mismatch for %s\n  wrote %q\n  read  %q\n' \
			"$key" "${original["$key"]}" "${restored["$key"]}" >&2
		exit 1
	fi
done

((${#restored[@]} == ${#original[@]})) ||
	fail "round trip: expected ${#original[@]} keys, read ${#restored[@]}"

# --- nothing is executed ----------------------------------------------------
[[ ! -e "$sandbox/pwned" ]] || fail 'injection: a value reached a command position'

# The dangerous value must survive intact rather than being neutered.
# shellcheck disable=SC2016  # matching the literal text, not expanding it
[[ "${restored[shell_metachars]}" == *'$(touch'* ]] ||
	fail 'injection: the metacharacter value was mangled instead of stored literally'

# --- a value never breaks the record format ---------------------------------
# Every stored line must be exactly one KEY=value pair: if encoding leaked a
# newline, the file would have more lines than keys.
records="$(grep -cv '^#' "$sandbox/round-trip.conf")"
((records == ${#original[@]})) ||
	fail "encoding: expected ${#original[@]} records, file has $records lines"

# --- kv_get agrees with kv_load, and last assignment wins -------------------
[[ "$(kv_get "$sandbox/round-trip.conf" non_ascii)" == "${original[non_ascii]}" ]] ||
	fail 'kv_get: disagreed with kv_load on a non-ASCII value'

kv_get "$sandbox/round-trip.conf" no_such_key >/dev/null 2>&1 &&
	fail 'kv_get: reported success for a missing key'

printf 'chassis=desktop\nchassis=laptop\n' >"$sandbox/duplicate.conf"
[[ "$(kv_get "$sandbox/duplicate.conf" chassis)" == 'laptop' ]] ||
	fail 'kv_get: last assignment must win'

# --- malformed input degrades, it does not explode --------------------------
printf '%s\n' \
	'# comment' \
	'' \
	'no_separator_here' \
	'9_invalid_key=dropped' \
	'valid=kept' \
	'stray_percent=100%' \
	'truncated_escape=abc%4' >"$sandbox/malformed.conf"

declare -A malformed=()
kv_load "$sandbox/malformed.conf" malformed

[[ "${malformed[valid]:-}" == 'kept' ]] || fail 'malformed: a valid line after a bad one was dropped'
[[ ! -v malformed[9_invalid_key] ]] || fail 'malformed: accepted a key that is not an identifier'
[[ ! -v malformed[no_separator_here] ]] || fail 'malformed: accepted a line with no separator'
[[ "${malformed[stray_percent]:-}" == '100%' ]] || fail 'malformed: a lone % must survive decoding'
[[ "${malformed[truncated_escape]:-}" == 'abc%4' ]] || fail 'malformed: a truncated escape must survive decoding'

# --- output is stable -------------------------------------------------------
kv_write "$sandbox/stable-a.conf" original '# header'
kv_write "$sandbox/stable-b.conf" original '# header'
cmp -s "$sandbox/stable-a.conf" "$sandbox/stable-b.conf" ||
	fail 'stability: two writes of the same data produced different bytes'

printf 'kv: %d values round-tripped, injection inert, malformed input degraded\n' "${#original[@]}"

# --- dotted keys, as translation tables use them (selector.vm) ---------------------
printf 'selector.vm=Guest\nnot a key=skipped\n' >"$sandbox/dotted.conf"
[[ "$(kv_get "$sandbox/dotted.conf" selector.vm)" == Guest ]] || fail 'kv_get: dotted key not read'
printf 'kv: dotted keys read\n'
