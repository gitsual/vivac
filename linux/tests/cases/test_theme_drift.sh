#!/usr/bin/env bash
set -Eeuo pipefail

# The drift gate is what makes data/theme.conf the single source of colour.
# Against a disposable copy of the checkout: a hand-edited render fails, a
# template with no render fails, --render repairs, and changing one token
# reaches every consumer that names it.

repo_root="${REPO_ROOT:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)}"
gate="$repo_root/scripts/check-theme-drift.sh"

sandbox="$(mktemp -d "${TMPDIR:-/tmp}/vivac-drift.XXXXXX")"
trap 'rm -rf -- "$sandbox"' EXIT
cp -r -- "$repo_root/templates" "$sandbox/templates"
cp -r -- "$repo_root/dotfiles" "$sandbox/dotfiles"
cp -r -- "$repo_root/system" "$sandbox/system"
cp -- "$repo_root/data/theme.conf" "$sandbox/theme.conf"

fail() {
	printf '%s\n' "$1" >&2
	exit 1
}
run() { THEME_FILE="$sandbox/theme.conf" TEMPLATES_DIR="$sandbox/templates" RENDER_ROOT="$sandbox" bash "$gate" "$@"; }

run >/dev/null || fail 'baseline: the committed renders must match their templates'

# --- a render edited by hand is drift --------------------------------------------
sed -i 's/#E1777D/#FF0000/' "$sandbox/dotfiles/wofi/.config/wofi/style.css"
run >/dev/null 2>&1 && fail 'gate accepted a hand-edited render'
run --render >/dev/null
run >/dev/null || fail '--render did not repair the hand edit'
grep -q '#E1777D' "$sandbox/dotfiles/wofi/.config/wofi/style.css" || fail '--render did not restore the palette value'

# --- a template with no render is drift ---------------------------------------------
printf 'x: #@COLOR_BG@;\n' >"$sandbox/templates/wofi/.config/wofi/extra.css.in"
run >/dev/null 2>&1 && fail 'gate accepted a template without a committed render'
rm -- "$sandbox/templates/wofi/.config/wofi/extra.css.in"

# --- a template naming an unknown token is drift, not an empty string ----------------
printf 'x: #@NOT_A_TOKEN@;\n' >>"$sandbox/templates/wofi/.config/wofi/style.css.in"
run >/dev/null 2>&1 && fail 'gate accepted a template with an unknown token'
sed -i '$d' "$sandbox/templates/wofi/.config/wofi/style.css.in"
run >/dev/null || fail 'did not return to green after removing the bad line'

# --- one token reaches every consumer ----------------------------------------------
before="$(grep -rl 'E1777D\|225, 119, 125' "$sandbox/dotfiles" | LC_ALL=C sort)"
[[ -n "$before" ]] || fail 'no consumer references the accent colour'
consumers="$(printf '%s\n' "$before" | grep -c .)"
sed -i 's/^COLOR_ACCENT=.*/COLOR_ACCENT=ABCDEF/' "$sandbox/theme.conf"
run >/dev/null 2>&1 && fail 'gate accepted stale renders after a palette change'
run --render >/dev/null
after="$(grep -rl 'ABCDEF\|171, 205, 239' "$sandbox/dotfiles" | LC_ALL=C sort)"
[[ "$before" == "$after" ]] || {
	printf 'propagation: consumers before %s\n after %s\n' "$before" "$after" >&2
	exit 1
}
grep -rq 'E1777D\|225, 119, 125' "$sandbox/dotfiles" && fail 'the old accent value survived a re-render'

# The terminal pair is intentionally separate: changing the palette accent
# must not touch it.
terminal_bg="$(sed -nE 's/^TERMINAL_BG=(.*)$/\1/p' "$sandbox/theme.conf" | tr 'A-F' 'a-f')"
grep -q "^background #$terminal_bg\$" "$sandbox/dotfiles/kitty/.config/kitty/kitty.conf" ||
	fail 'the terminal background changed with the palette accent'

printf 'theme drift: hand edit, orphan template, unknown token refused; accent reached %d consumers\n' "$consumers"
