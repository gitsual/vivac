#!/usr/bin/env bash
set -Eeuo pipefail

# Adding the GPU catalogue must not touch the default profile: the deployable
# tree still matches the frozen baseline, the default package set bootstrap
# would install carries nothing from a GPU manifest, and no committed dotfile
# names a family. GPU stacks arrive only through an explicit path (a later
# unit's gpu-setup), never by default.

repo_root="${REPO_ROOT:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)}"

fail() {
	printf '%s\n' "$1" >&2
	exit 1
}

bash "$repo_root/scripts/freeze-baseline.sh" >/dev/null || fail 'the deployable tree drifted from the frozen baseline'

listing="$(SYSROOT="$repo_root/tests/fixtures/desktop-nvidia/sysroot" LSPCI_CMD=false PACMAN_CMD=false \
	bash "$repo_root/scripts/bootstrap.sh" --dry-run 2>/dev/null | grep '^would install official packages' || true)"
[[ -n "$listing" ]] || fail 'bootstrap dry run printed no package listing'
while IFS= read -r package; do
	[[ -n "$package" && "$package" != '#'* ]] || continue
	grep -Fxq -- "$package" "$repo_root/packages/pacman.txt" && continue
	[[ " ${listing#*: } " != *" $package "* ]] || fail "default bootstrap would install GPU package $package on an NVIDIA machine"
done < <(cat "$repo_root"/packages/gpu-*.txt)

while IFS= read -r id; do
	grep -rq -- "$id" "$repo_root/dotfiles" "$repo_root/templates" "$repo_root/render" && fail "family id $id appears in a deployable file"
done < <(awk -F'\t' '!/^#/ && NF { print $1 }' "$repo_root/data/gpu-catalogue.tsv")

printf 'gpu base unchanged: baseline intact, default install carries no GPU stack\n'
