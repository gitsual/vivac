#!/usr/bin/env bash
set -Eeuo pipefail

# Settings are chosen values with one writer each. Defaults reproduce the
# source workstation; a file overrides them; an unknown key or a malformed
# value is refused rather than reaching /etc. The XKB layout reaches the
# rendered input fragment and nothing else.

repo_root="${REPO_ROOT:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)}"
# shellcheck source=lib/kv.sh
source "$repo_root/lib/kv.sh"
# shellcheck source=lib/settings.sh
source "$repo_root/lib/settings.sh"

sandbox="$(mktemp -d "${TMPDIR:-/tmp}/vivac-settings.XXXXXX")"
trap 'rm -rf -- "$sandbox"' EXIT

fail() {
	printf '%s\n' "$1" >&2
	exit 1
}

# --- defaults without a file -------------------------------------------------------
settings_load "$sandbox/absent" || fail 'a missing settings file must mean the defaults'
[[ "$(settings_get locale)" == 'es_ES.UTF-8' && "$(settings_get keymap)" == es && "$(settings_get xkb_layout)" == es ]] ||
	fail 'defaults do not reproduce the source workstation'

# --- a file overrides only what it names ------------------------------------------------
printf 'xkb_layout=us,fr\n' >"$sandbox/settings"
settings_load "$sandbox/settings" || fail 'a valid file was refused'
[[ "$(settings_get xkb_layout)" == 'us,fr' ]] || fail 'the file value did not win'
[[ "$(settings_get keymap)" == es ]] || fail 'an unnamed setting lost its default'

# --- refusals -------------------------------------------------------------------------------
printf 'timezone=Europe/Madrid\n' >"$sandbox/settings"
settings_load "$sandbox/settings" 2>/dev/null && fail 'an unknown setting was accepted'
printf 'keymap=es; rm -rf /\n' >"$sandbox/settings"
settings_load "$sandbox/settings" 2>/dev/null && fail 'a keymap with shell metacharacters was accepted'
printf 'locale=es_ES\n' >"$sandbox/settings"
settings_load "$sandbox/settings" 2>/dev/null && fail 'a non-UTF-8 locale was accepted'
printf 'xkb_layout=US\n' >"$sandbox/settings"
settings_load "$sandbox/settings" 2>/dev/null && fail 'an upper-case XKB layout was accepted'

# --- the committed example is a valid settings file ------------------------------------------
settings_load "$repo_root/settings.example" || fail 'settings.example does not load'

# --- xkb_layout reaches input.lua and nothing else ----------------------------------------
home="$sandbox/home"
mkdir -p -- "$home"
printf 'xkb_layout=fr\nkeymap=us\nlocale=C.UTF-8\n' >"$sandbox/settings"
HOME="$home" XDG_CONFIG_HOME="$home/.config" XDG_STATE_HOME="$sandbox/state" SETTINGS_FILE="$sandbox/settings" \
	FACTS_FILE="$repo_root/tests/golden/laptop-intel/hardware-facts" FACTS_OVERRIDE="$sandbox/none" \
	bash "$repo_root/scripts/render-config.sh" --deploy >/dev/null || fail 'render with settings failed'
grep -Fq 'kb_layout = "fr"' "$home/.config/hypr/generated/input.lua" || fail 'xkb_layout did not reach input.lua'
grep -rq 'C.UTF-8\|KEYMAP\|LANG' "$home/.config" && fail 'a system axis leaked into a user render'

# --- apply-system reads the same file and touches only its two files (dry run) ------------
output="$(SETTINGS_FILE="$sandbox/settings" bash "$repo_root/scripts/apply-system.sh" --dry-run --locale --keymap)" ||
	fail 'apply-system dry run failed'
grep -Fxq 'would write /etc/locale.conf: LANG=C.UTF-8' <<<"$output" || fail "locale axis not previewed: $output"
grep -q '^would write /etc/vconsole.conf: KEYMAP=us' <<<"$output" || fail "keymap axis not previewed: $output"
grep -q 'would install\|would enable services' <<<"$output" && fail 'the axes enabled an unrelated profile'
printf 'keymap=bad name\n' >"$sandbox/settings"
SETTINGS_FILE="$sandbox/settings" bash "$repo_root/scripts/apply-system.sh" --dry-run --keymap >/dev/null 2>&1 &&
	fail 'apply-system accepted a malformed keymap'

# bar_wifi_interface: which Wi-Fi card the bar shows. wl* (the first one) by
# default; a host with two cards names the one that carries the traffic.
# Only an interface name or that glob: the value lands in the bar's JSON.
(
	source "$repo_root/lib/settings.sh"
	settings_defaults
	[[ "${SETTINGS[bar_wifi_interface]}" == 'wl*' ]] || fail "bar_wifi_interface default: ${SETTINGS[bar_wifi_interface]:-none}"
	settings_valid bar_wifi_interface wlp2s0f0u4 || fail 'bar_wifi_interface refused an interface name'
	settings_valid bar_wifi_interface 'wl*' || fail 'bar_wifi_interface refused its default'
	settings_valid bar_wifi_interface 'wl", "x' && fail 'bar_wifi_interface accepted a quote'
	settings_valid bar_wifi_interface 'a b' && fail 'bar_wifi_interface accepted a space'
	true
)

# bar_owner_scripts: the owner's own bar scripts (sessions, update-system.sh)
# are not part of vivac; only a machine that has them asks for them.
(
	source "$repo_root/lib/settings.sh"
	settings_defaults
	[[ "${SETTINGS[bar_owner_scripts]}" == no ]] || fail "bar_owner_scripts default: ${SETTINGS[bar_owner_scripts]:-none}"
	settings_valid bar_owner_scripts yes || fail 'bar_owner_scripts refused yes'
	settings_valid bar_owner_scripts maybe && fail 'bar_owner_scripts accepted maybe'
	true
)

printf 'settings: defaults, override, 4 refusals, one writer per axis verified\n'
