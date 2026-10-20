#!/usr/bin/env bash
# Send a classic Hyprland dispatcher to the compositor, whichever config
# language it was started with.
#
# A hyprlang session takes `hyprctl dispatch workspace 3`. A Lua session
# evaluates the dispatch argument as Lua, so the same call has to arrive as
# `hyprctl dispatch 'hl.dsp.focus({ workspace = 3 })'`. Callers keep the
# classic vocabulary (it is also what data/help-registry.tsv stores) and this
# file translates it from a closed table. A dispatcher that is not in the
# table fails with rc 2 instead of being smuggled through hl.dsp.exec_raw,
# which runs a binary and would report success for any string.
#
#   hypr_ipc_mode                       lua | classic, probed once per instance
#   hypr_dispatch_expr DISP [ARGS...]   print the Lua expression, rc 2 if unknown
#   hypr_dispatch DISP [ARGS...]        run it
#
# Sourced, not executed: functions only, no side effects at source time.
# VIVAC_HYPR_IPC_MODE=lua|classic skips the probe (tests); HYPR_IPC_TIMEOUT
# bounds every hyprctl call in seconds (default 5).

# Lua mode is the one where `hyprctl eval 'return true'` answers ok.
hypr_ipc_mode() {
	local override="${VIVAC_HYPR_IPC_MODE:-}"
	if [[ "$override" == lua || "$override" == classic ]]; then
		printf '%s\n' "$override"
		return 0
	fi
	local signature="${HYPRLAND_INSTANCE_SIGNATURE:-}" cache='' mode
	if [[ "$signature" =~ ^[A-Za-z0-9_.-]+$ ]]; then
		cache="${XDG_RUNTIME_DIR:-${TMPDIR:-/tmp}}/vivac/hypr-ipc-mode.$signature"
		if [[ -r "$cache" ]]; then
			mode="$(<"$cache")"
			if [[ "$mode" == lua || "$mode" == classic ]]; then
				printf '%s\n' "$mode"
				return 0
			fi
		fi
	fi
	# Only a definite answer is cached: exactly `ok` is Lua, an "unknown request"
	# style reply is a hyprlang compositor. A timeout, an empty reply or a socket
	# error says nothing about the config language, so this call falls back to
	# classic and the next one asks again.
	mode=classic
	local reply='' definite=false
	if command -v hyprctl >/dev/null 2>&1; then
		reply="$(timeout "${HYPR_IPC_TIMEOUT:-5}" hyprctl eval 'return true' 2>&1)" || true
		if [[ "$reply" == ok ]]; then
			mode=lua definite=true
		elif [[ "$reply" == *[Uu]nknown\ request* || "$reply" == *[Ii]nvalid\ request* ]]; then
			definite=true
		fi
	fi
	if $definite && [[ -n "$cache" ]] && mkdir -p -- "${cache%/*}" 2>/dev/null; then
		printf '%s\n' "$mode" >"$cache.$$" 2>/dev/null && mv -f -- "$cache.$$" "$cache" 2>/dev/null || true
	fi
	printf '%s\n' "$mode"
}

# The long-bracket string for an arbitrary command: the level is raised until
# the closing sequence cannot occur inside it, nor form at its end ("x]==" plus
# the closing "]==]" would close early). A leading newline is dropped by
# Lua, so one more is added to keep the command byte for byte.
_hypr_ipc_long_string() {
	local text="$1" level='==' lead=''
	while [[ "$text]" == *"]${level}]"* ]]; do level+='='; done
	[[ "$text" == $'\n'* ]] && lead=$'\n'
	printf '[%s[%s%s]%s]' "$level" "$lead" "$text" "$level"
}

_hypr_ipc_direction() {
	case "$1" in
	l | left) printf left ;;
	r | right) printf right ;;
	u | up) printf up ;;
	d | down) printf down ;;
	*) return 1 ;;
	esac
}

hypr_dispatch_expr() {
	local dispatcher="${1:-}" direction
	shift || true
	local -a args=("$@")
	local why="bad arguments"
	case "$dispatcher" in
	killactive) ((${#args[@]} == 0)) && { printf 'hl.dsp.window.close()\n'; return 0; } ;;
	exit) ((${#args[@]} == 0)) && { printf 'hl.dsp.exit()\n'; return 0; } ;;
	togglefloating) ((${#args[@]} == 0)) && { printf 'hl.dsp.window.float({ action = "toggle" })\n'; return 0; } ;;
	fullscreen) ((${#args[@]} == 0)) && { printf 'hl.dsp.window.fullscreen()\n'; return 0; } ;;
	layoutmsg)
		if ((${#args[@]} == 1)) && [[ "${args[0]}" =~ ^[a-z]+$ ]]; then
			printf 'hl.dsp.layout("%s")\n' "${args[0]}"
			return 0
		fi
		;;
	movefocus)
		if ((${#args[@]} == 1)) && direction="$(_hypr_ipc_direction "${args[0]}")"; then
			printf 'hl.dsp.focus({ direction = "%s" })\n' "$direction"
			return 0
		fi
		;;
	movewindow)
		if ((${#args[@]} == 1)) && direction="$(_hypr_ipc_direction "${args[0]}")"; then
			printf 'hl.dsp.window.move({ direction = "%s" })\n' "$direction"
			return 0
		fi
		;;
	resizeactive)
		if ((${#args[@]} == 2)) && [[ "${args[0]}" =~ ^-?[0-9]+$ && "${args[1]}" =~ ^-?[0-9]+$ ]]; then
			printf 'hl.dsp.window.resize({ x = %s, y = %s, relative = true })\n' "${args[0]}" "${args[1]}"
			return 0
		fi
		;;
	workspace)
		if ((${#args[@]} == 1)); then
			if [[ "${args[0]}" =~ ^[0-9]+$ ]]; then
				printf 'hl.dsp.focus({ workspace = %s })\n' "${args[0]}"
				return 0
			elif [[ "${args[0]}" =~ ^e[+-][0-9]+$ ]]; then
				printf 'hl.dsp.focus({ workspace = "%s" })\n' "${args[0]}"
				return 0
			fi
		fi
		;;
	movetoworkspace)
		if ((${#args[@]} == 1)) && [[ "${args[0]}" =~ ^[0-9]+$ ]]; then
			printf 'hl.dsp.window.move({ workspace = %s })\n' "${args[0]}"
			return 0
		fi
		;;
	dpms)
		if ((${#args[@]} == 1)) && [[ "${args[0]}" == on || "${args[0]}" == off ]]; then
			printf 'hl.dsp.dpms({ action = "%s" })\n' "${args[0]}"
			return 0
		fi
		;;
	focuswindow)
		if ((${#args[@]} == 1)) && [[ "${args[0]}" =~ ^address:0x[0-9a-fA-F]+$ ]]; then
			printf 'hl.dsp.focus({ window = "%s" })\n' "${args[0]}"
			return 0
		fi
		;;
	exec)
		[[ "${args[0]:-}" == -- ]] && args=("${args[@]:1}")
		if ((${#args[@]} > 0)); then
			printf 'hl.dsp.exec_cmd(%s)\n' "$(_hypr_ipc_long_string "${args[*]}")"
			return 0
		fi
		;;
	*) why="unknown dispatcher" ;;
	esac
	printf 'hypr-ipc: %s: %s %s\n' "$why" "$dispatcher" "${args[*]}" >&2
	return 2
}

hypr_dispatch() {
	if ! command -v hyprctl >/dev/null 2>&1; then
		printf 'hypr-ipc: hyprctl not found, cannot dispatch %s\n' "$*" >&2
		return 1
	fi
	local timeout_s="${HYPR_IPC_TIMEOUT:-5}" expr
	if [[ "$(hypr_ipc_mode)" == lua ]]; then
		expr="$(hypr_dispatch_expr "$@")" || return $?
		timeout "$timeout_s" hyprctl dispatch "$expr"
	else
		timeout "$timeout_s" hyprctl dispatch "$@"
	fi
}
