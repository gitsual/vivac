#!/usr/bin/env bash
set -Eeuo pipefail

# LC_ALL=C is pinned at parser call sites only (pacman, lspci, sort, localectl
# list-keymaps). A global export would silently turn every message a user
# sees into C-locale English and hide the language axes this repository
# takes care to keep separate.

repo_root="${REPO_ROOT:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)}"
cd "$repo_root"

if grep -rnE '^[[:space:]]*(export[[:space:]]+LC_ALL|LC_ALL=[^[:space:]]*[[:space:]]*$|declare[[:space:]]+(-x[[:space:]]+)?LC_ALL)' scripts lib tests dotfiles | grep .; then
	printf 'LC_ALL is set globally somewhere above\n' >&2
	exit 1
fi

sites="$(grep -rhoE 'LC_ALL=C [a-z-]+' scripts lib tests | sort | uniq -c | sort -rn | awk '{print $3":"$1}' | tr '\n' ' ')"
printf 'no global LC_ALL; call-site pins: %s\n' "$sites"
