#!/usr/bin/env bash
set -Eeuo pipefail

# build-bar-hover.sh — build lib/bar-hover/vivac-hover.c, the Waybar module
# that opens a bar panel on hover, into a shared library Waybar loads.
#
#   build-bar-hover.sh [--output FILE]
#
# FILE defaults to ~/.local/lib/vivac/vivac-hover.so, the path the bar's
# template names. It is rebuilt only when the source is newer. Exit 1 when
# gcc, pkg-config or the GTK 3 headers are missing: the bar then renders
# without hover (render-config.sh checks for the file).

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
source_dir="$repo_root/lib/bar-hover"
output="$HOME/.local/lib/vivac/vivac-hover.so"
while (($#)); do
	case "$1" in
	--output)
		output="${2:?--output needs a file}"
		shift 2
		;;
	*)
		printf 'usage: build-bar-hover.sh [--output FILE]\n' >&2
		exit 2
		;;
	esac
done

for tool in gcc pkg-config; do
	command -v "$tool" >/dev/null || {
		printf 'build-bar-hover: %s is not installed\n' "$tool" >&2
		exit 1
	}
done
pkg-config --exists gtk+-3.0 || {
	printf 'build-bar-hover: no GTK 3 headers (gtk3)\n' >&2
	exit 1
}

if [[ -f "$output" && "$output" -nt "$source_dir/vivac-hover.c" && "$output" -nt "$source_dir/waybar_cffi_module.h" ]]; then
	printf 'up to date: %s\n' "$output"
	exit 0
fi
mkdir -p -- "$(dirname -- "$output")"
scratch="$(mktemp -- "$output.XXXXXX")"
trap 'rm -f -- "$scratch"' EXIT
# shellcheck disable=SC2046  # pkg-config prints several words on purpose
gcc -shared -fPIC -O2 -Wall -Wextra -Werror -o "$scratch" "$source_dir/vivac-hover.c" -I"$source_dir" $(pkg-config --cflags --libs gtk+-3.0)
chmod 0755 -- "$scratch"
mv -f -- "$scratch" "$output"
trap - EXIT
printf 'built %s\n' "$output"
