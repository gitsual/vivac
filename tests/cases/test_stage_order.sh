#!/usr/bin/env bash
set -Eeuo pipefail

# The asset manifest hashes rendered bytes. If it ran before the render stage
# it would pass on stale output and the ordering bug would be silent, so the
# order is asserted here by line number rather than assumed.

repo_root="${REPO_ROOT:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)}"
check="$repo_root/scripts/check.sh"

line_of() { grep -n "^stage '$1'" "$check" | head -n1 | cut -d: -f1; }

render="$(line_of 'committed renders and theme drift')"
manifest="$(line_of 'asset manifest')"
baseline="$(line_of 'default profile baseline')"
verify="$(line_of 'hyprland config verification')"

[[ -n "$render" ]] || { printf 'check.sh has no render stage\n' >&2; exit 1; }
[[ -n "$manifest" ]] || { printf 'check.sh has no asset manifest stage\n' >&2; exit 1; }
[[ -n "$baseline" ]] || { printf 'check.sh has no baseline stage\n' >&2; exit 1; }
[[ -n "$verify" ]] || { printf 'check.sh has no hyprland config verification stage\n' >&2; exit 1; }

((render < manifest)) || {
	printf 'stage order: render (line %d) must precede asset manifest (line %d)\n' "$render" "$manifest" >&2
	exit 1
}
# The baseline compares deployable bytes, which are render output too.
((render < baseline)) || {
	printf 'stage order: render (line %d) must precede default profile baseline (line %d)\n' "$render" "$baseline" >&2
	exit 1
}

# Hyprland verifies the committed hyprland.lua, which is render output too.
((render < verify)) || {
	printf 'stage order: render (line %d) must precede hyprland config verification (line %d)\n' "$render" "$verify" >&2
	exit 1
}

printf 'stage order: render (%d) < asset manifest (%d), render < baseline (%d)\n' "$render" "$manifest" "$baseline"
