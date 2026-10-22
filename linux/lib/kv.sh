#!/usr/bin/env bash
# Safe reader/writer for the repository's flat KEY=value files (hardware facts,
# theme tokens, translation tables).
#
# The whole point of this file is that it never runs its input. A tokens file or
# a facts file is data that arrives from a generator, an override the user
# edited, or a fixture — none of it may reach a command position. So: no
# `source`, no `eval`, no `declare` of attacker-chosen names. Values are split
# on the first `=` only, and everything that could break the line format is
# percent-encoded on write and decoded on read.
#
# Sourced, not executed. Functions only; no side effects at source time.

# Encode a value for storage. Only the characters that would corrupt the file
# format are escaped — `%` itself (first, or decoding would be ambiguous),
# the line terminators, tab, and any remaining C0 control byte. Everything else,
# including `=`, backslashes and UTF-8, is stored literally so a human can still
# read and edit the file.
kv_encode() {
	local value="$1" out='' i char code
	for ((i = 0; i < ${#value}; i++)); do
		char="${value:i:1}"
		case "$char" in
		'%') out+='%25' ;;
		$'\n') out+='%0A' ;;
		$'\r') out+='%0D' ;;
		$'\t') out+='%09' ;;
		*)
			# Compare by code point, never with `<`: that operator uses the
			# locale's collation order, under which a multi-byte character
			# such as an em dash sorts below a space and would be mangled
			# into a percent escape. Only real C0 controls are escaped.
			printf -v code '%d' "'$char"
			if ((code < 32)); then
				printf -v char '%%%02X' "$code"
			fi
			out+="$char"
			;;
		esac
	done
	printf '%s' "$out"
}

# Decode a stored value. Any %XX sequence is restored; a stray `%` that is not
# followed by two hex digits is left alone rather than treated as an error, so a
# hand-edited file degrades to something readable instead of failing to parse.
kv_decode() {
	local value="$1" out='' i char hex
	for ((i = 0; i < ${#value}; i++)); do
		char="${value:i:1}"
		if [[ "$char" == '%' && "${value:i+1:2}" =~ ^[0-9A-Fa-f]{2}$ ]]; then
			hex="${value:i+1:2}"
			# printf -v, never $(printf ...): command substitution strips
			# trailing newlines, which would decode %0A to nothing at all.
			printf -v char '%b' "\\x$hex"
			out+="$char"
			i=$((i + 2))
		else
			out+="$char"
		fi
	done
	printf '%s' "$out"
}

# kv_get FILE KEY — print the decoded value, or return 1 when the key is absent.
# The last assignment wins, matching the merge semantics in kv_load.
kv_get() {
	local file="$1" wanted="$2" line key value found=1 result=''
	[[ -r "$file" ]] || return 1
	while IFS= read -r line || [[ -n "$line" ]]; do
		[[ -z "$line" || "$line" == '#'* ]] && continue
		[[ "$line" == *=* ]] || continue
		key="${line%%=*}"
		value="${line#*=}"
		if [[ "$key" == "$wanted" ]]; then
			result="$value"
			found=0
		fi
	done <"$file"
	((found == 0)) || return 1
	kv_decode "$result"
}

# kv_load FILE ARRAY_NAME — fill an existing associative array from FILE.
# Later assignments overwrite earlier ones, so loading several files in order
# gives last-one-wins merge semantics for free.
kv_load() {
	local file="$1" line key
	# Nameref parameters carry a __kv_ prefix: bash raises a circular reference
	# if the caller's array happens to share the parameter's name, and callers
	# legitimately use plain names like `facts` or `tokens`.
	local -n __kv_target="$2"
	[[ -r "$file" ]] || return 1
	while IFS= read -r line || [[ -n "$line" ]]; do
		[[ -z "$line" || "$line" == '#'* ]] && continue
		[[ "$line" == *=* ]] || continue
		key="${line%%=*}"
		# A malformed key can never become a command or a variable name: it is
		# only ever used as an associative-array subscript.
		[[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_.]*$ ]] || continue
		# shellcheck disable=SC2034  # assigned through the nameref for the caller
		__kv_target["$key"]="$(kv_decode "${line#*=}")"
	done <"$file"
}

# kv_write FILE ARRAY_NAME [HEADER] — write the array as a sorted KEY=value
# file. Sorting keeps the output stable so generated files diff cleanly and
# byte-for-byte golden comparisons stay meaningful.
kv_write() {
	local file="$1" header="${3:-}" key
	# shellcheck disable=SC2034  # read through the nameref below
	local -n __kv_source="$2"
	{
		[[ -n "$header" ]] && printf '%s\n' "$header"
		while IFS= read -r key; do
			printf '%s=%s\n' "$key" "$(kv_encode "${__kv_source["$key"]}")"
		done < <(printf '%s\n' "${!__kv_source[@]}" | LC_ALL=C sort)
	} >"$file"
}
