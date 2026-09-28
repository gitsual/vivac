#!/usr/bin/env bash
set -Eeuo pipefail

# The graphical greeter is rendered from the settings: its process language
# and its keyboard layout are two separate values in greetd's command, the
# stylesheet comes from the palette, tuigreet stays selectable, and the
# selector installs exactly its manifest.

repo_root="${REPO_ROOT:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)}"
sandbox="$(mktemp -d "${TMPDIR:-/tmp}/vivac-greeter.XXXXXX")"
trap 'rm -rf -- "$sandbox"' EXIT
# shellcheck source=lib/kv.sh
source "$repo_root/lib/kv.sh"

fail() {
	printf '%s\n' "$1" >&2
	exit 1
}
printf 'locale=de_DE.UTF-8\nkeymap=us\nxkb_layout=fr\n' >"$sandbox/settings"
out="$(SETTINGS_FILE="$sandbox/settings" bash "$repo_root/scripts/apply-system.sh" --dry-run --greeter)" || fail 'greeter dry run failed'
command_line="$(grep '^would install /etc/greetd/config.toml with: ' <<<"$out")"
[[ "$command_line" == *'LANG=de_DE.UTF-8 '* ]] || fail "greeter language not taken from the settings: $command_line"
[[ "$command_line" == *'XKB_DEFAULT_LAYOUT=fr '* ]] || fail "greeter layout not taken from the settings: $command_line"
[[ "$command_line" != *'us'* ]] || fail 'the console keymap leaked into the greeter command'
[[ "$command_line" == *'cage -s -- regreet"'* ]] || fail "the greeter is not ReGreet in cage: $command_line"
grep -q 'regreet.css -> /etc/greetd/regreet.css' <<<"$out" || fail 'the stylesheet is not installed'
grep -q 'greetd.service' <<<"$out" || fail 'greetd is not enabled'

# --- the stylesheet is a render of the palette --------------------------------------------------------------
declare -A theme=()
kv_load "$repo_root/data/theme.conf" theme
grep -q "#${theme[COLOR_ACCENT]}" "$repo_root/system/etc/greetd/regreet.css" || fail 'the accent colour did not reach regreet.css'
grep -q '@COLOR' "$repo_root/system/etc/greetd/regreet.css" && fail 'an unrendered token in regreet.css'
[[ -f "$repo_root/templates/system/etc/greetd/regreet.css.in" ]] || fail 'regreet.css has no template'

# --- tuigreet is still the default graphical login ---------------------------------------------------------
out="$(SETTINGS_FILE="$sandbox/settings" bash "$repo_root/scripts/apply-system.sh" --dry-run --desktop-login)" || fail 'desktop-login dry run failed'
grep -q 'system/etc/greetd/config.toml -> /etc/greetd/config.toml' <<<"$out" || fail 'tuigreet config is no longer installed by --desktop-login'
grep -Eq 'regreet|cage' <<<"$out" && fail '--desktop-login alone installs the GUI greeter'
grep -q 'tuigreet' "$repo_root/system/etc/greetd/config.toml" || fail 'the tuigreet config changed'

# --- the selector adds exactly its manifest and asks apply-system for the greeter --------------------------
listing() {
	SYSROOT="$repo_root/tests/fixtures/laptop-intel/sysroot" LSPCI_CMD=false PACMAN_CMD=false \
		bash "$repo_root/scripts/bootstrap.sh" --dry-run --system "$@" 2>/dev/null
}
base="$(listing)"
with="$(listing --gui-greeter)"
extra="$(LC_ALL=C comm -13 <(grep '^would install official' <<<"$base" | sed 's/.*: //' | tr ' ' '\n' | LC_ALL=C sort) \
	<(grep '^would install official' <<<"$with" | sed 's/.*: //' | tr ' ' '\n' | LC_ALL=C sort))"
[[ "$extra" == "$(<"$repo_root/packages/gui-greeter.txt")" ]] || fail "--gui-greeter added something outside its manifest: $extra"
grep -q 'would install /etc/greetd/config.toml with: command = "env LANG=' <<<"$with" || fail 'bootstrap --gui-greeter did not reach apply-system --greeter'
grep -Eq 'regreet|cage' <<<"$base" && fail 'the default bootstrap installs the GUI greeter'

printf 'gui greeter: two axes from the settings, palette stylesheet, tuigreet untouched, selector exact\n'
