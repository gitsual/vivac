#!/usr/bin/env bash
# Token substitution for theme templates.
#
# A template is a committed file with @NAME@ placeholders. Rendering replaces
# each with the token's value from data/theme.conf, optionally through one
# filter, and nothing else: no shell expansion, no command, no include. The
# @NAME@ syntax is chosen over ${NAME} precisely so that the CSS, INI and
# rasi syntax around it stays literal (ADR-2).
#
#   @NAME@         the value as stored          2D1F2D
#   @NAME:lower@   lower-cased                  2d1f2d
#   @NAME:rgb@     decimal triplet for rgba()   45, 31, 45
#
# An unknown token or filter is an error, never an empty string: a placeholder
# silently rendered as nothing would ship a broken stylesheet.
#
# Deploy-time templates under render/ additionally see hardware facts, loaded
# with render_load_facts: each fact is a token named FACT_<KEY> in upper case
# (@FACT_MAX_SCALE@), and a line may start with a guard
#
#   @?predicate@rest of the line
#
# which keeps the line (without the guard) when the predicate holds over the
# facts and drops it otherwise. The predicate grammar is lib/selectors.sh's:
# key=value, key!=value, key~word, joined by && and ||. A guard in a template
# rendered without facts is an error, so a committed theme template can never
# depend on the machine it is rendered on.
#
# Sourced, not executed. Requires lib/kv.sh; guards require lib/facts.sh and
# lib/selectors.sh as well.

declare -gA RENDER_TOKENS=() RENDER_FACTS=()

# render_load_tokens FILE — load the palette. Values must be bare 6-digit hex;
# anything else is refused here so a template never has to guess.
render_load_tokens() {
	local file="$1" key
	RENDER_TOKENS=()
	kv_load "$file" RENDER_TOKENS || {
		printf 'render: cannot read theme file %s\n' "$file" >&2
		return 1
	}
	for key in "${!RENDER_TOKENS[@]}"; do
		[[ "${RENDER_TOKENS["$key"]}" =~ ^[0-9A-F]{6}$ ]] || {
			printf 'render: token %s is not bare upper-case 6-digit hex: %q\n' "$key" "${RENDER_TOKENS["$key"]}" >&2
			return 1
		}
	done
}

# render_load_facts FILE... — load hardware facts for a deploy-time render.
# Later files win (the user's override). Every fact becomes a token
# FACT_<KEY>; values are words, not colours, so no hex check applies. Facts
# never enter RENDER_FACTS through any other path, which is what lets a guard
# trust that array.
render_load_facts() {
	local key
	RENDER_FACTS=()
	facts_load RENDER_FACTS "$@" || {
		printf 'render: no readable facts file among: %s\n' "$*" >&2
		return 1
	}
	for key in "${!RENDER_FACTS[@]}"; do
		RENDER_TOKENS["FACT_${key^^}"]="${RENDER_FACTS["$key"]}"
	done
}

# render_guard_holds PREDICATE — 0 when the guarded line stays. Facts must be
# loaded; a template that guards on a machine no facts describe is a bug in
# how it was invoked, not a line to drop quietly.
render_guard_holds() {
	local predicate="$1"
	[[ -v RENDER_FACTS[FACTS_SCHEMA] ]] || {
		printf 'render: guard %q used without hardware facts\n' "$predicate" >&2
		return 2
	}
	selectors_validate_predicate "$predicate" || return 2
	selector_predicate_holds "$predicate" RENDER_FACTS
}

# render_scale_channels HEX PERCENT — scale every channel toward black.
render_scale_channels() {
	local value="$1" percent="$2" channel scaled out=''
	for channel in 0 2 4; do
		scaled=$(((0x${value:$channel:2} * percent) / 100))
		printf -v out '%s%02X' "$out" "$scaled"
	done
	printf '%s' "$out"
}

# render_apply_filter VALUE FILTER
render_apply_filter() {
	local value="$1" filter="$2"
	case "$filter" in
	'') printf '%s' "$value" ;;
	lower) printf '%s' "${value,,}" ;;
	upper) printf '%s' "${value^^}" ;;
	rgb) printf '%d, %d, %d' "0x${value:0:2}" "0x${value:2:2}" "0x${value:4:2}" ;;
	# Derived shades, for gradients that need depth without adding colours to
	# the palette. A derivation is a transformation of a corpus colour, not a
	# new one: the wallpaper needs a floor under its background and a rim over
	# it, and inventing two hexes per theme would break the corpus rule.
	dark) render_scale_channels "$value" 70 ;;
	darker) render_scale_channels "$value" 45 ;;
	dim) render_scale_channels "$value" 78 ;;
	*)
		printf 'render: unknown filter %q\n' "$filter" >&2
		return 1
		;;
	esac
}

# render_string TEXT — substitute every placeholder in TEXT. Scans left to
# right with parameter expansion only; a value is inserted as literal bytes.
render_string() {
	local text="$1" out='' rest name filter value
	rest="$text"
	while [[ "$rest" =~ @([A-Z][A-Z0-9_]*)(:([a-z]+))?@ ]]; do
		name="${BASH_REMATCH[1]}"
		filter="${BASH_REMATCH[3]}"
		[[ -v RENDER_TOKENS["$name"] ]] || {
			printf 'render: unknown token @%s@\n' "$name" >&2
			return 1
		}
		value="$(render_apply_filter "${RENDER_TOKENS["$name"]}" "$filter")" || return 1
		out+="${rest%%"${BASH_REMATCH[0]}"*}$value"
		rest="${rest#*"${BASH_REMATCH[0]}"}"
	done
	printf '%s' "$out$rest"
}

# render_file TEMPLATE OUTPUT — render line by line so a template of any size
# costs no more than its length, then write atomically.
render_file() {
	local template="$1" output="$2" line rendered tmp lineno=0 guard
	[[ -r "$template" ]] || {
		printf 'render: no template at %s\n' "$template" >&2
		return 1
	}
	tmp="$(mktemp -- "${output}.XXXXXX")"
	local failed=0
	while IFS= read -r line || [[ -n "$line" ]]; do
		lineno=$((lineno + 1))
		if [[ "$line" =~ ^@\?([^@]*)@(.*)$ ]]; then
			line="${BASH_REMATCH[2]}"
			guard=0
			render_guard_holds "${BASH_REMATCH[1]}" || guard=$?
			case "$guard" in
			0) ;;
			1) continue ;;
			*)
				printf 'render: %s line %d\n' "$template" "$lineno" >&2
				failed=1
				break
				;;
			esac
		fi
		if rendered="$(render_string "$line")"; then
			printf '%s\n' "$rendered"
		else
			printf 'render: %s line %d\n' "$template" "$lineno" >&2
			failed=1
			break
		fi
	done <"$template" >"$tmp"
	if ((failed)); then
		rm -f -- "$tmp"
		return 1
	fi
	mv -- "$tmp" "$output"
}

# render_output_path TEMPLATE — where a template renders to: the same path
# under dotfiles/ with the .in suffix removed.
#   templates/waybar/.config/waybar/style.css.in
#   -> dotfiles/waybar/.config/waybar/style.css
#   templates/system/etc/greetd/regreet.css.in
#   -> system/etc/greetd/regreet.css        (system files are not stowed)
render_output_path() {
	local template="$1"
	template="${template#templates/}"
	if [[ "$template" == system/* ]]; then
		printf '%s' "${template%.in}"
	else
		printf 'dotfiles/%s' "${template%.in}"
	fi
}

# render_deploy_output_path TEMPLATE — where a deploy-time template renders
# to: the same path under the user's config directory, never the checkout.
#   render/hypr/generated/monitors.lua.in
#   -> $XDG_CONFIG_HOME/hypr/generated/monitors.lua
render_deploy_output_path() {
	local template="$1"
	template="${template#render/}"
	printf '%s/%s' "${XDG_CONFIG_HOME:-$HOME/.config}" "${template%.in}"
}
