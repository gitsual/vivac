#!/usr/bin/env bash
set -Eeuo pipefail

# Hyprlang has no inline block. A block opened and closed on the same line is
# parsed as nothing and every setting inside it is dropped without a warning:
# the config still loads, the option keeps its default, and nothing on screen
# says so. It cost this desktop three settings at once. `hyprlock.conf` asked
# for the palette as its background and for the cursor to be hidden, and drew a
# black field with a cursor on it; the compositor config (since ported to Lua) asked
# for preserve_split and new_on_top, and `hyprctl getoption` answered 0 to both.
#
# Only Hyprlang files are checked. CSS and rofi's rasi are different languages
# in which a one-line rule is ordinary and correct.

repo_root="${REPO_ROOT:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)}"
cd "$repo_root"

files="$(find templates/hypr dotfiles/hypr -type f \( -name '*.conf' -o -name '*.conf.in' \) | LC_ALL=C sort)"
[ -n "$files" ] || {
    printf 'no Hyprland configuration files found to check\n' >&2
    exit 1
}

# A line that opens a brace and closes it again, ignoring comments. The leading
# word is the block name, so `bind = ... {` style lines and strings are not it.
if printf '%s\n' "$files" | xargs grep -nE '^[[:space:]]*[a-zA-Z_][a-zA-Z0-9_-]*[[:space:]]*\{.*\}' | grep -v '^[^:]*:[0-9]*:[[:space:]]*#' | grep .; then
    printf 'Hyprlang block written inline above: open it across lines, or its contents are silently ignored\n' >&2
    exit 1
fi

printf 'no inline Hyprlang blocks in %d configuration files\n' "$(printf '%s\n' "$files" | wc -l)"
