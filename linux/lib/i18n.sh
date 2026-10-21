#!/usr/bin/env bash
# User-facing strings, one flat KEY=value table per language under i18n/.
#
# Two rules, both structural rather than conventional:
#
#   1. A translation is TEXT. Commands, dispatcher names and document paths
#      live in the registries (data/*.tsv) under typed action columns; a
#      translation table only ever holds label_key=text, and nothing here
#      passes a value to a command position (ADR-6).
#   2. Placeholders are {1}, {2}, ... substituted by parameter expansion —
#      never printf with a data-controlled format string. A translator cannot
#      break formatting, and a value like `$(id)` stays four literal bytes.
#
# English is the reference: a key absent from another language falls back to
# the English text and is marked so the gap is visible instead of silent.
#
# Sourced, not executed. Requires lib/kv.sh.

I18N_DIR="${I18N_DIR:-}"
I18N_REFERENCE=en
declare -gA I18N_TEXT=() I18N_FALLBACK=()
I18N_LANG=''

# i18n_load LANG [DIR] — load the reference table, then LANG over it. Keys
# that only the reference provides are remembered as fallbacks.
i18n_load() {
	local lang="$1" dir="${2:-${I18N_DIR:-}}" key
	local -A reference=() requested=()
	I18N_TEXT=()
	I18N_FALLBACK=()
	# shellcheck disable=SC2034  # exposed for callers that print the active language
	I18N_LANG="$lang"

	kv_load "$dir/$I18N_REFERENCE.conf" reference || {
		printf 'i18n: reference table %s/%s.conf is unreadable\n' "$dir" "$I18N_REFERENCE" >&2
		return 1
	}
	if [[ "$lang" != "$I18N_REFERENCE" ]]; then
		kv_load "$dir/$lang.conf" requested || {
			printf 'i18n: no table for %s, using %s\n' "$lang" "$I18N_REFERENCE" >&2
		}
	fi

	for key in "${!reference[@]}"; do
		if [[ -v requested["$key"] ]]; then
			I18N_TEXT["$key"]="${requested["$key"]}"
		else
			I18N_TEXT["$key"]="${reference["$key"]}"
			[[ "$lang" == "$I18N_REFERENCE" ]] || I18N_FALLBACK["$key"]=1
		fi
	done
	# A key the requested language has but the reference does not is not a
	# string this program knows; it is ignored here and refused by the gate.
}

# i18n_get KEY — print the text. A fallback is marked with the reference
# language tag so a half-translated UI shows exactly where the gap is. An
# unknown key prints the key itself in brackets: never empty, never a crash.
i18n_get() {
	local key="$1"
	if [[ ! -v I18N_TEXT["$key"] ]]; then
		printf '[%s]' "$key"
		return 1
	fi
	if [[ -v I18N_FALLBACK["$key"] ]]; then
		printf '[%s] %s' "$I18N_REFERENCE" "${I18N_TEXT["$key"]}"
	else
		printf '%s' "${I18N_TEXT["$key"]}"
	fi
}

# i18n_format KEY ARG... — i18n_get with {1}, {2}, ... replaced by ARGs.
# Pure string substitution: an argument containing `{2}` or `$x` is inserted
# as those literal characters.
i18n_format() {
	local key="$1" text status=0 index=1 placeholder
	shift
	text="$(i18n_get "$key")" || status=$?
	for arg in "$@"; do
		placeholder="{$index}"
		text="${text//"$placeholder"/"$arg"}"
		index=$((index + 1))
	done
	printf '%s' "$text"
	return "$status"
}

# i18n_session_language [SETTINGS_FILE] — the language a program should speak:
# VIVAC_LANG (one run), then the `language` setting unless it is auto, then
# LANG, then the reference. A table name is two or three lower-case letters;
# a garbled setting or LANG (C, POSIX) is skipped, a VIVAC_LANG that is not a
# name means the reference outright, and an unreadable settings file is never
# an error. Callers load the result with i18n_load.
i18n_session_language() {
	local file="${1:-${SETTINGS_FILE:-${XDG_CONFIG_HOME:-$HOME/.config}/vivac/settings}}" candidate
	if [[ -n "${VIVAC_LANG:-}" ]]; then
		candidate="${VIVAC_LANG%%[._@]*}"
		[[ "$candidate" =~ ^[a-z]{2,3}$ ]] || candidate="$I18N_REFERENCE"
		printf '%s' "$candidate"
		return 0
	fi
	for candidate in "$(kv_get "$file" language 2>/dev/null || true)" "${LANG:-}"; do
		[[ "$candidate" == auto ]] && continue
		candidate="${candidate%%[._@]*}"
		if [[ "$candidate" =~ ^[a-z]{2,3}$ ]]; then
			printf '%s' "$candidate"
			return 0
		fi
	done
	printf '%s' "$I18N_REFERENCE"
}
