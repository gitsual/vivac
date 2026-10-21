#!/usr/bin/env bash
# User settings: the values a person chooses, as opposed to hardware facts,
# which are detected. Today these are the language axes: the system locale,
# the console keymap and the Hyprland keyboard layout. Each is written by
# exactly one place in this repository (tests/cases/test_axis_single_writer.sh
# holds that line), and each reads its value from here.
#
# The file lives in $XDG_CONFIG_HOME/vivac/settings, flat KV via
# lib/kv.sh, and is never committed. A missing file means the defaults, which
# reproduce the source workstation. An unknown key or a malformed value is an
# error: a typo in a keymap name would otherwise reach /etc/vconsole.conf.
#
# Sourced, not executed. Requires lib/kv.sh.

SETTINGS_ALLOWED_KEYS=(locale keymap xkb_layout ime theme weather_location shared_settings language ask_url ask_model ask_allow_lan)
# The only keys that may travel to the optional shared file. OS locale, keymap
# and layout stay local: the other OS names them differently.
SETTINGS_SHARED_KEYS=(theme weather_location language)
declare -gA SETTINGS=()

# settings_defaults — reset SETTINGS to the values the source workstation uses.
settings_defaults() {
	SETTINGS=(
		[locale]=es_ES.UTF-8
		[keymap]=es
		[xkb_layout]=es
		[ime]=none
		[theme]=bad-romance
		[weather_location]=auto
		[shared_settings]=none
		[language]=auto
		[ask_url]=http://localhost:11434
		[ask_model]=none
		[ask_allow_lan]=false
	)
}

# settings_valid KEY VALUE — 0 when VALUE is an acceptable KEY.
#   locale      a UTF-8 locale name (only those are generated), or C.UTF-8
#   keymap      a console keymap name as localectl lists them
#   xkb_layout  one or more XKB layouts, comma-separated (us,es)
#   theme       a name in the catalogue; the file has to exist, which only the
#               renderer can know, so here the shape is all that is checked
#   weather_location
#               what the bar asks wttr.in about: "auto" means by IP, which is
#               what the service does with an empty path. Anything else is a
#               place name or airport code, and is restricted to the characters
#               a place name needs so the value cannot smuggle a second URL or
#               a shell metacharacter into the module's command line.
#   shared_settings
#               none, or where the file shared with another OS lives: an
#               absolute path or one under ~/
#   language    auto (follow LANG) or a table name from i18n/
#   ask_url     the Ollama server vivac-ask talks to: http://HOST:PORT and no
#               path. Whether the host may be off this machine is vivac-ask's
#               call (ask_allow_lan); here only the shape is checked.
#   ask_model   none (the first model the server lists) or a model name as
#               Ollama writes them (qwen2.5:7b, library/name:tag)
#   ask_allow_lan
#               true lets ask_url name a machine on the local network
settings_valid() {
	local key="$1" value="$2"
	case "$key" in
	locale) [[ "$value" == 'C.UTF-8' || "$value" =~ ^[a-z]{2,3}(_[A-Z]{2})?(@[a-z]+)?\.UTF-8$ ]] ;;
	keymap) [[ "$value" =~ ^[A-Za-z0-9_.-]+$ ]] ;;
	xkb_layout) [[ "$value" =~ ^[a-z]{2,8}(,[a-z]{2,8})*$ ]] ;;
	ime) [[ "$value" == none || "$value" == fcitx5 ]] ;;
	theme) [[ "$value" =~ ^[a-z][a-z0-9-]*$ ]] ;;
	weather_location) [[ "$value" =~ ^[A-Za-z0-9_.,+-]+$ ]] ;;
	shared_settings) [[ "$value" == none || "$value" =~ ^(/|~/)[[:print:]]+$ ]] ;;
	language) [[ "$value" == auto || "$value" =~ ^[a-z]{2,3}$ ]] ;;
	ask_url)
		# Host (a name, an IPv4 or a bracketed IPv6) and port; ] first in the
		# bracket is a literal ].
		local pattern='^http://[][A-Za-z0-9.:_-]+/?$'
		[[ "$value" =~ $pattern ]]
		;;
	ask_model) [[ "$value" =~ ^[A-Za-z0-9][A-Za-z0-9._:/-]*$ ]] ;;
	ask_allow_lan) [[ "$value" == true || "$value" == false ]] ;;
	*) return 1 ;;
	esac
}

# settings_load FILE — defaults, then FILE on top when it exists.
settings_load() {
	local file="$1" key allowed ok
	settings_defaults
	[[ -e "$file" ]] || return 0
	local -A __settings_read=()
	kv_load "$file" __settings_read || {
		printf 'settings: cannot read %s\n' "$file" >&2
		return 1
	}
	for key in "${!__settings_read[@]}"; do
		ok=1
		for allowed in "${SETTINGS_ALLOWED_KEYS[@]}"; do
			[[ "$key" == "$allowed" ]] && ok=0
		done
		((ok == 0)) || {
			printf 'settings: %s is not a setting this repository knows (%s)\n' "$key" "${SETTINGS_ALLOWED_KEYS[*]}" >&2
			return 1
		}
		settings_valid "$key" "${__settings_read["$key"]}" || {
			printf 'settings: %s has a malformed value: %q\n' "$key" "${__settings_read["$key"]}" >&2
			return 1
		}
		SETTINGS["$key"]="${__settings_read["$key"]}"
	done
}

# settings_get KEY — print one setting after settings_load.
settings_get() {
	[[ -v SETTINGS["$1"] ]] || {
		printf 'settings: no such setting %s\n' "$1" >&2
		return 1
	}
	printf '%s' "${SETTINGS["$1"]}"
}

# settings_write_local FILE KEY VALUE — set one key, in place, atomically.
#
# Validated first and refused if it does not hold: a settings file is read by
# renderers that trust it, so the moment to reject a bad value is before it is
# on disk, not when a stylesheet comes out malformed. The key is rewritten
# rather than appended, so setting the same axis twice leaves one line.
settings_write_local() {
	local file="$1" key="$2" value="$3" temporary
	settings_valid "$key" "$value" || {
		printf 'settings: %s is not a valid %s\n' "$value" "$key" >&2
		return 1
	}
	mkdir -p -- "$(dirname -- "$file")"
	temporary="$(mktemp -- "$file.XXXXXX")"
	if [[ -f "$file" ]]; then
		grep -vE "^[[:space:]]*${key}[[:space:]]*=" "$file" >"$temporary" || true
	fi
	printf '%s=%s\n' "$key" "$value" >>"$temporary"
	LC_ALL=C sort -o "$temporary" "$temporary"
	mv -- "$temporary" "$file"
}

# settings_shared_path FILE — print the shared file's path when FILE configures
# one. Silent failure otherwise: no sharing is the normal case, not an error.
settings_shared_path() {
	local raw
	raw="$(kv_get "$1" shared_settings 2>/dev/null)" || return 1
	[[ "$raw" != none ]] && settings_valid shared_settings "$raw" || return 1
	printf '%s' "${raw/#\~\//$HOME/}"
}

# settings_shared_root FILE — print the shared root (docs/bridge.md at the root
# of the product): the folder that holds the shared file, where the drop tray
# lives too. Silent failure while shared_settings=none, as above.
settings_shared_root() {
	local shared
	shared="$(settings_shared_path "$1")" || return 1
	dirname -- "$shared"
}

# settings_shared_write PATH KEY VALUE — set one key of the shared file in
# place. The file is read by another OS, so its other lines (a `mod=` of the
# Windows side, say) and their order are kept; CR and a BOM are dropped on
# rewrite, the new line is LF. A value already there writes nothing, and a
# missing folder (an unmounted partition) is never created.
settings_shared_write() {
	local path="$1" key="$2" value="$3" line temporary hit=0 same=0 first=1
	local -a lines=()
	[[ -d "$(dirname -- "$path")" ]] || return 0
	if [[ -f "$path" ]]; then
		while IFS= read -r line || [[ -n "$line" ]]; do
			line="${line%$'\r'}"
			((first)) && line="${line#$'\xef\xbb\xbf'}"
			first=0
			lines+=("$line")
		done <"$path"
	fi
	for line in "${lines[@]}"; do
		[[ "$line" == "$key="* ]] || continue
		hit=$((hit + 1))
		[[ "$line" == "$key=$value" ]] && same=1
	done
	((hit == 1 && same == 1)) && return 0
	temporary="$(mktemp -- "$path.XXXXXX")"
	hit=0
	{
		for line in "${lines[@]}"; do
			if [[ "$line" == "$key="* ]]; then
				((hit++)) || printf '%s=%s\n' "$key" "$value"
			else
				printf '%s\n' "$line"
			fi
		done
		((hit)) || printf '%s=%s\n' "$key" "$value"
	} >"$temporary"
	mv -- "$temporary" "$path"
}

# --- changes the shared file could not take yet --------------------------------------------------
# A shared write is skipped while its folder is away (an unmounted partition) or
# while a pull holds the lock. The key is recorded in $state/vivac/shared-pending
# so the next session-start pull sends the local value instead of taking the
# other OS's older one. Callers need XDG_STATE_HOME or HOME.
_settings_state_dir() { printf '%s' "${XDG_STATE_HOME:-$HOME/.local/state}/vivac"; }
settings_pending_has() { grep -qxF -- "$1" "$(_settings_state_dir)/shared-pending" 2>/dev/null; }
settings_pending_add() {
	local dir file
	dir="$(_settings_state_dir)" file="$dir/shared-pending"
	settings_pending_has "$1" && return 0
	mkdir -p -- "$dir" && printf '%s\n' "$1" >>"$file"
}
settings_pending_remove() {
	local file temporary
	file="$(_settings_state_dir)/shared-pending"
	[[ -f "$file" ]] || return 0
	temporary="$(mktemp -- "$file.XXXXXX")"
	grep -vxF -- "$1" "$file" >"$temporary" || true
	mv -- "$temporary" "$file"
}

# _settings_shared_push SHARED KEY VALUE — one shared write under the shared lock.
# rc 3: the lock stayed busy. rc 4: the write failed. A pull that already holds
# the lock says so in VIVAC_SHARED_LOCK_HELD, which its children inherit.
_settings_shared_push() {
	local shared="$1" key="$2" value="$3" dir rc=0
	if [[ -n "${VIVAC_SHARED_LOCK_HELD:-}" ]]; then
		settings_shared_write "$shared" "$key" "$value" || return 4
		settings_pending_remove "$key"
		return 0
	fi
	dir="$(_settings_state_dir)"
	mkdir -p -- "$dir" || return 4
	(
		flock -w "${VIVAC_SETTINGS_LOCK_WAIT:-10}" 9 || exit 3
		settings_shared_write "$shared" "$key" "$value" || exit 4
		settings_pending_remove "$key"
	) 9>"$dir/shared-sync.lock" || rc=$?
	return "$rc"
}

# settings_write FILE KEY VALUE — the change path: the local file, then the
# shared one for the shared keys when sharing is configured. A shared file
# that cannot be written costs a warning, never the local change, and the key
# stays pending until a pull can send it. The warning comes once per key.
settings_write() {
	local file="$1" key="$2" value="$3" shared candidate rc
	settings_write_local "$file" "$key" "$value" || return 1
	for candidate in "${SETTINGS_SHARED_KEYS[@]}"; do
		[[ "$candidate" == "$key" ]] || continue
		shared="$(settings_shared_path "$file")" || return 0
		if [[ ! -d "$(dirname -- "$shared")" ]]; then
			settings_pending_has "$key" ||
				printf 'settings: the shared folder %s is not there; %s stays local and is sent when it is\n' "$(dirname -- "$shared")" "$key" >&2
			settings_pending_add "$key" || true
			return 0
		fi
		rc=0
		_settings_shared_push "$shared" "$key" "$value" || rc=$?
		if ((rc)); then
			settings_pending_has "$key" ||
				printf 'settings: could not update the shared file %s; %s stays local and is sent next time\n' "$shared" "$key" >&2
			settings_pending_add "$key" || true
		fi
	done
	return 0
}
