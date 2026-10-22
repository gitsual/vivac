#!/usr/bin/env bash
set -Eeuo pipefail

# Gate for data/selectors.tsv: every row parses, every predicate is valid over
# the fact allowlist, and every manifest it names exists. A registry row is
# edited by hand, so the place to catch a typo is here, not on a user's
# machine at bootstrap time.

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
# shellcheck source=lib/kv.sh
source "$repo_root/lib/kv.sh"
# shellcheck source=lib/facts.sh
source "$repo_root/lib/facts.sh"
# shellcheck source=lib/selectors.sh
source "$repo_root/lib/selectors.sh"

registry="${SELECTORS_FILE:-$repo_root/data/selectors.tsv}"
selectors_load "$registry"

status=0
for id in "${SELECTOR_IDS[@]}"; do
	manifest="$repo_root/${SELECTOR_MANIFEST["$id"]}"
	[[ -f "$manifest" ]] || {
		printf 'selector %s names a manifest that does not exist: %s\n' "$id" "${SELECTOR_MANIFEST["$id"]}" >&2
		status=1
	}
done

# Every optional manifest must be reachable through a selector, or it is dead
# data nobody can install.
for manifest in "$repo_root"/packages/*.txt; do
	name="$(basename -- "$manifest")"
	[[ "$name" == pacman.txt || "$name" == aur.txt || "$name" == *.local.txt ]] && continue
	# A <selector>-aur.txt is reached through its own selector's base manifest,
	# not registered separately: the selector is one choice, and which half of
	# it comes from a repository and which from a build recipe is an
	# implementation detail of installing it.
	if [[ "$name" == *-aur.txt ]]; then
		# ...but it must belong to one, or it is a build recipe list nobody
		# will ever read.
		base="packages/${name%-aur.txt}.txt"
		owned=no
		for id in "${SELECTOR_IDS[@]}"; do
			[[ "${SELECTOR_MANIFEST["$id"]}" == "$base" ]] && owned=yes
		done
		[[ "$owned" == yes ]] || {
			printf 'packages/%s has no selector: nothing names %s\n' "$name" "$base" >&2
			status=1
		}
		continue
	fi
	# GPU manifests are reached through the catalogue; check-gpu-catalogue.sh owns them.
	[[ "$name" == gpu-*.txt ]] && continue
	referenced=no
	for id in "${SELECTOR_IDS[@]}"; do
		[[ "${SELECTOR_MANIFEST["$id"]}" == "packages/$name" ]] && referenced=yes
	done
	[[ "$referenced" == yes ]] || {
		printf 'packages/%s is not reachable through any selector\n' "$name" >&2
		status=1
	}
done

((status == 0)) && printf 'selectors: %d registered, all predicates parse, all manifests present\n' "${#SELECTOR_IDS[@]}"
exit "$status"
