#!/usr/bin/env bash
# The selector registry: which optional package sets exist, and which machines
# each applies to, expressed as a predicate over hardware facts.
#
# The predicate grammar is deliberately tiny and is evaluated by a hand-rolled
# tokenizer — never by `eval` or `[[ $predicate ]]`. A registry row is data
# that a contributor edits, and this is the one place where that data would
# otherwise reach a command position. Anything the grammar does not cover is a
# parse error caught by the gate, not a runtime surprise.
#
#   atom     := key=value | key!=value | key~word
#   clause   := atom ( "&&" atom )*
#   predicate:= "" | clause ( "||" clause )*
#
# `key~word` holds when word is one of the space-separated words in the fact's
# value (gpu_vendors, kernels). Keys must be allowlisted fact keys.
#
# Sourced, not executed. Requires lib/facts.sh (for the key allowlist).

SELECTORS_FILE="${SELECTORS_FILE:-}"

# Row storage, indexed by selector id, filled by selectors_load.
declare -gA SELECTOR_MANIFEST=() SELECTOR_PREDICATE=() SELECTOR_FLAG=() SELECTOR_LABEL=()
declare -ga SELECTOR_IDS=()

# selectors_load FILE — read the registry. Malformed rows are errors: the file
# is small, hand-edited, and a bad row silently skipped would hide a selector.
selectors_load() {
	local file="$1" line id manifest predicate flag label lineno=0
	local -a cols
	SELECTOR_IDS=()
	SELECTOR_MANIFEST=()
	SELECTOR_PREDICATE=()
	SELECTOR_FLAG=()
	SELECTOR_LABEL=()
	[[ -r "$file" ]] || {
		printf 'selectors: cannot read %s\n' "$file" >&2
		return 1
	}
	while IFS= read -r line || [[ -n "$line" ]]; do
		lineno=$((lineno + 1))
		[[ -z "$line" || "$line" == '#'* ]] && continue
		# Not `IFS=$'\t' read`: tab is whitespace to IFS, so consecutive tabs
		# collapse and an empty predicate column would shift every later
		# column left. mapfile -d keeps empty fields.
		mapfile -d $'\t' -t cols < <(printf '%s' "$line")
		id="${cols[0]:-}" manifest="${cols[1]:-}" predicate="${cols[2]:-}" flag="${cols[3]:-}" label="${cols[4]:-}"
		[[ "$id" =~ ^[a-z][a-z0-9-]*$ ]] || {
			printf 'selectors: line %d: bad id %q\n' "$lineno" "$id" >&2
			return 1
		}
		[[ -n "$manifest" && -n "$flag" && -n "$label" ]] || {
			printf 'selectors: line %d: row for %s is missing a column\n' "$lineno" "$id" >&2
			return 1
		}
		[[ "$flag" == --* ]] || {
			printf 'selectors: line %d: system_flag must start with --, got %q\n' "$lineno" "$flag" >&2
			return 1
		}
		[[ ! -v SELECTOR_MANIFEST["$id"] ]] || {
			printf 'selectors: line %d: duplicate id %s\n' "$lineno" "$id" >&2
			return 1
		}
		selectors_validate_predicate "$predicate" || {
			printf 'selectors: line %d: in predicate for %s\n' "$lineno" "$id" >&2
			return 1
		}
		SELECTOR_IDS+=("$id")
		SELECTOR_MANIFEST["$id"]="$manifest"
		SELECTOR_PREDICATE["$id"]="$predicate"
		SELECTOR_FLAG["$id"]="$flag"
		# shellcheck disable=SC2034  # read by bootstrap.sh --list-selectors
		SELECTOR_LABEL["$id"]="$label"
	done <"$file"
}

# selectors_validate_predicate PREDICATE — parse without evaluating. This is
# what the gate runs, so a typo in a key or an operator fails check.sh instead
# of quietly making a selector never (or always) apply.
selectors_validate_predicate() {
	local predicate="$1" token expect=atom key
	[[ -z "$predicate" ]] && return 0
	for token in $predicate; do
		case "$expect" in
		atom)
			[[ "$token" =~ ^([a-z_]+)(=|!=|~)([A-Za-z0-9_.:-]*)$ ]] || {
				printf 'selectors: not an atom: %q\n' "$token" >&2
				return 1
			}
			key="${BASH_REMATCH[1]}"
			facts_key_allowed "$key" || {
				printf 'selectors: %q is not a fact key\n' "$key" >&2
				return 1
			}
			expect=operator
			;;
		operator)
			[[ "$token" == '&&' || "$token" == '||' ]] || {
				printf 'selectors: expected && or ||, got %q\n' "$token" >&2
				return 1
			}
			expect=atom
			;;
		esac
	done
	[[ "$expect" == operator ]] || {
		printf 'selectors: predicate ends after an operator\n' >&2
		return 1
	}
}

# selector_atom_holds ATOM FACTS_ARRAY_NAME
selector_atom_holds() {
	local atom="$1"
	local -n __sel_facts="$2"
	local key op wanted actual word
	[[ "$atom" =~ ^([a-z_]+)(=|!=|~)([A-Za-z0-9_.:-]*)$ ]] || return 1
	key="${BASH_REMATCH[1]}"
	op="${BASH_REMATCH[2]}"
	wanted="${BASH_REMATCH[3]}"
	actual="${__sel_facts["$key"]:-}"
	case "$op" in
	'=') [[ "$actual" == "$wanted" ]] ;;
	'!=') [[ "$actual" != "$wanted" ]] ;;
	'~')
		for word in $actual; do
			[[ "$word" == "$wanted" ]] && return 0
		done
		return 1
		;;
	esac
}

# selector_predicate_holds PREDICATE FACTS_ARRAY_NAME
#
# Left to right: a clause is a run of atoms joined by && and holds when every
# atom does; the predicate holds when any clause does. No parentheses.
selector_predicate_holds() {
	local predicate="$1" facts_name="$2" token clause_ok=true any_ok=false
	[[ -z "$predicate" ]] && return 0
	for token in $predicate; do
		case "$token" in
		'&&') ;;
		'||')
			$clause_ok && any_ok=true
			clause_ok=true
			;;
		*)
			selector_atom_holds "$token" "$facts_name" || clause_ok=false
			;;
		esac
	done
	$clause_ok && any_ok=true
	$any_ok
}

# selector_applicable ID FACTS_ARRAY_NAME — 0 if the selector applies here.
selector_applicable() {
	[[ -v SELECTOR_PREDICATE["$1"] ]] || return 2
	selector_predicate_holds "${SELECTOR_PREDICATE["$1"]}" "$2"
}

# selectors_applicable FACTS_ARRAY_NAME — print the ids that apply, in
# registry order.
selectors_applicable() {
	local id
	for id in "${SELECTOR_IDS[@]}"; do
		selector_applicable "$id" "$1" && printf '%s\n' "$id"
	done
	return 0
}

# selector_for_flag FLAG — print the id whose system_flag is FLAG, or fail.
selector_for_flag() {
	local id
	for id in "${SELECTOR_IDS[@]}"; do
		[[ "${SELECTOR_FLAG["$id"]}" == "$1" ]] && {
			printf '%s\n' "$id"
			return 0
		}
	done
	return 1
}
