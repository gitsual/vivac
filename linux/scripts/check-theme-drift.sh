#!/usr/bin/env bash
set -Eeuo pipefail

# Every template under templates/ renders to its twin under dotfiles/. This
# gate re-renders each into a scratch file and compares bytes, so a themed
# config that was edited by hand, or a palette change that was not re-rendered,
# fails check.sh instead of quietly diverging from the palette.
#
# templates/wallpaper/ is the exception, and deliberately: a wallpaper has no
# single committed twin. It is rendered once per theme into dist/, by
# scripts/make-wallpaper.sh, and tests/cases/test_theme_ornament.sh is what
# checks those renders resolve. A dotfile has one palette; a wallpaper has as
# many as the catalogue offers. templates/brand/ is the same case with one
# theme chosen for it: scripts/make-logo.sh renders the banner into assets/,
# and data/asset-manifest.tsv is what pins the bytes that ship.
#
# --render writes the renders into the checkout. It is the sanctioned way to
# regenerate after editing data/theme.conf or a template; its output belongs
# in the same commit as the edit that caused it.

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
# shellcheck source=lib/kv.sh
source "$repo_root/lib/kv.sh"
# shellcheck source=lib/render.sh
source "$repo_root/lib/render.sh"

theme="${THEME_FILE:-$repo_root/data/theme.conf}"
templates_dir="${TEMPLATES_DIR:-$repo_root/templates}"
output_root="${RENDER_ROOT:-$repo_root}"
write=false

case "${1:-}" in
'') ;;
--render) write=true ;;
-h | --help)
	printf 'Usage: scripts/check-theme-drift.sh [--render]\n'
	exit 0
	;;
*)
	printf 'Unknown option: %s\n' "$1" >&2
	exit 2
	;;
esac

render_load_tokens "$theme"

scratch="$(mktemp -d "${TMPDIR:-/tmp}/vivac-render.XXXXXX")"
trap 'rm -rf -- "$scratch"' EXIT

status=0
count=0
while IFS= read -r template; do
	relative="${template#"$templates_dir"/}"
	target="$output_root/$(render_output_path "templates/$relative")"
	count=$((count + 1))

	if $write; then
		mkdir -p -- "$(dirname -- "$target")"
		render_file "$template" "$target"
		printf 'rendered %s\n' "${target#"$output_root"/}"
		continue
	fi

	rendered="$scratch/$count"
	render_file "$template" "$rendered" || {
		status=1
		continue
	}
	if [[ ! -f "$target" ]]; then
		printf 'template has no committed render: %s -> %s\n' "$relative" "${target#"$output_root"/}" >&2
		status=1
	elif ! cmp -s "$rendered" "$target"; then
		printf 'theme drift: %s differs from its template render\n' "${target#"$output_root"/}" >&2
		diff -u --label 'rendered' "$rendered" --label 'committed' "$target" | head -n 20 >&2 || true
		status=1
	fi
done < <(find "$templates_dir" \( -path "$templates_dir/wallpaper" -o -path "$templates_dir/brand" \) -prune -o -type f -name '*.in' -print | LC_ALL=C sort)

((count > 0)) || {
	printf 'no templates found under %s\n' "$templates_dir" >&2
	exit 1
}

if $write; then
	printf 'theme: %d files rendered\n' "$count"
	exit 0
fi
if ((status)); then
	printf 'Re-render with scripts/check-theme-drift.sh --render and commit the result.\n' >&2
	exit 1
fi
printf 'theme: %d committed renders match their templates\n' "$count"
