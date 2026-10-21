#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
full=false
[[ "${1:-}" == --full-local ]] && full=true

if $full; then
	# Intentionally ignored snapshots for local machine recovery/review.
	pacman -Qqen | LC_ALL=C sort -u >"$repo_root/packages/pacman-full.local.txt"
	pacman -Qqem | LC_ALL=C sort -u >"$repo_root/packages/aur-full.local.txt"
	printf '%s\n' 'wrote ignored full local snapshots'
	exit 0
fi

status=0
for manifest in pacman aur; do
	file="$repo_root/packages/$manifest.txt"
	temporary="$(mktemp)"
	trap 'rm -f "$temporary"' EXIT
	while IFS= read -r package; do
		[[ -z "$package" || "$package" == \#* ]] && continue
		if pacman -Q "$package" >/dev/null 2>&1; then
			printf '%s\n' "$package" >>"$temporary"
		else
			printf 'not installed (kept in manifest): %s\n' "$package" >&2
			status=1
		fi
	done <"$file"
	LC_ALL=C sort -u "$temporary" -o "$temporary"
	# Only rewrite when every declared package is installed; never silently shrink.
	if ((status == 0)); then
		mv "$temporary" "$file"
		trap - EXIT
	fi
done

exit "$status"
