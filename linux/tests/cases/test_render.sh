#!/usr/bin/env bash
set -Eeuo pipefail

# The renderer is what turns one palette file into every themed config. These
# cases pin: substitution is exact and literal, each filter does one thing,
# an unknown token is an error rather than an empty string, and a template
# renders byte-for-byte reproducibly.

repo_root="${REPO_ROOT:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)}"
# shellcheck source=/dev/null
source "$repo_root/lib/kv.sh"
# shellcheck source=/dev/null
source "$repo_root/lib/render.sh"

sandbox="$(mktemp -d "${TMPDIR:-/tmp}/vivac-render.XXXXXX")"
trap 'rm -rf -- "$sandbox"' EXIT

fail() {
	printf '%s\n' "$1" >&2
	exit 1
}

printf 'COLOR_BG=2D1F2D\nCOLOR_ACCENT=E1777D\n' >"$sandbox/theme.conf"
render_load_tokens "$sandbox/theme.conf" || fail 'refused a valid tokens file'

# --- substitution and filters -------------------------------------------------
[[ "$(render_string 'x #@COLOR_BG@ y')" == 'x #2D1F2D y' ]] || fail 'plain substitution'
[[ "$(render_string '@COLOR_BG:lower@')" == '2d1f2d' ]] || fail 'lower filter'
[[ "$(render_string 'rgba(@COLOR_BG:rgb@, 0.95)')" == 'rgba(45, 31, 45, 0.95)' ]] || fail 'rgb filter'
[[ "$(render_string '#@COLOR_BG@f2 and @COLOR_ACCENT@')" == '#2D1F2Df2 and E1777D' ]] ||
	fail 'two tokens on one line, with a literal alpha suffix'
[[ "$(render_string 'no tokens here')" == 'no tokens here' ]] || fail 'a line without tokens is untouched'
[[ "$(render_string '')" == '' ]] || fail 'empty line'

# Things that look like tokens but are not must stay literal: rasi's own
# @variable references are lower-case, and a lone @ is just an @.
[[ "$(render_string 'text-color: @fg0;')" == 'text-color: @fg0;' ]] || fail 'rasi @variables must survive'
[[ "$(render_string 'a@b.c @ end')" == 'a@b.c @ end' ]] || fail 'stray @ must survive'

# --- errors are errors, never empty output ---------------------------------------
render_string '@NO_SUCH_TOKEN@' >/dev/null 2>&1 && fail 'unknown token rendered instead of failing'
render_string '@COLOR_BG:nope@' >/dev/null 2>&1 && fail 'unknown filter rendered instead of failing'

printf 'COLOR_BG=#2D1F2D\n' >"$sandbox/bad-hash.conf"
render_load_tokens "$sandbox/bad-hash.conf" 2>/dev/null && fail 'accepted a value with a leading #'
printf 'COLOR_BG=2d1f2d\n' >"$sandbox/bad-case.conf"
render_load_tokens "$sandbox/bad-case.conf" 2>/dev/null && fail 'accepted lower-case hex (canonical form is upper)'
printf 'COLOR_BG=red\n' >"$sandbox/bad-word.conf"
render_load_tokens "$sandbox/bad-word.conf" 2>/dev/null && fail 'accepted a non-hex value'
render_load_tokens "$sandbox/theme.conf"

# --- nothing is executed, a value is literal bytes ------------------------------
# shellcheck disable=SC2016
printf '%s\n' 'window { background: #@COLOR_BG@; } /* $(touch "'"$sandbox"'/pwned") `id` ${x} */' \
	'border: @COLOR_ACCENT@;' >"$sandbox/t.css.in"
render_file "$sandbox/t.css.in" "$sandbox/t.css" || fail 'render_file failed on a valid template'
[[ ! -e "$sandbox/pwned" ]] || fail 'template text reached a command position'
# shellcheck disable=SC2016
[[ "$(head -n1 "$sandbox/t.css")" == 'window { background: #2D1F2D; } /* $(touch "'"$sandbox"'/pwned") `id` ${x} */' ]] ||
	fail 'template text was altered beyond the placeholders'

# --- reproducible, and a failing render leaves no partial output ---------------
render_file "$sandbox/t.css.in" "$sandbox/t2.css"
cmp -s "$sandbox/t.css" "$sandbox/t2.css" || fail 'two renders differ'
printf '@MISSING@\n' >"$sandbox/broken.in"
render_file "$sandbox/broken.in" "$sandbox/broken.out" 2>/dev/null && fail 'rendered a broken template'
[[ ! -e "$sandbox/broken.out" ]] || fail 'a failed render left a partial output file'
[[ -z "$(find "$sandbox" -name 'broken.out.*')" ]] || fail 'a failed render left its temp file behind'

# --- output path mapping ----------------------------------------------------------
[[ "$(render_output_path templates/waybar/.config/waybar/style.css.in)" == 'dotfiles/waybar/.config/waybar/style.css' ]] ||
	fail 'output path mapping'

printf 'render: filters exact, unknown tokens refused, values literal, output reproducible\n'
