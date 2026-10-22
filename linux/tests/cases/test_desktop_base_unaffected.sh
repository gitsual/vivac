#!/usr/bin/env bash
set -Eeuo pipefail

# --desktop adds exactly the desktop manifest and nothing else; without it the
# default bootstrap lists not one of those packages, and its listing is the
# same on every archetype the manifest does not care about.

repo_root="${REPO_ROOT:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)}"
manifest="$repo_root/packages/desktop.txt"

fail() {
	printf '%s\n' "$1" >&2
	exit 1
}
listing() {
	SYSROOT="$repo_root/tests/fixtures/$1/sysroot" LSPCI_CMD=false PACMAN_CMD=false \
		bash "$repo_root/scripts/bootstrap.sh" --dry-run "${@:2}" 2>/dev/null | grep '^would install official packages' || true
}
LC_ALL=C sort -cu "$manifest" || fail 'packages/desktop.txt is not sorted unique'
mapfile -t desktop < <(grep -Ev '^[[:space:]]*(#|$)' "$manifest")
((${#desktop[@]} >= 8)) || fail 'the desktop manifest is too short to be the promised set'
for package in "${desktop[@]}"; do
	grep -Fxq -- "$package" "$repo_root/packages/pacman.txt" && fail "$package is in the base manifest and the desktop one"
done

base="$(listing vm-virtio)"
with="$(listing vm-virtio --desktop)"
[[ -n "$base" && -n "$with" ]] || fail 'bootstrap dry run printed no package listing'
for package in "${desktop[@]}"; do
	[[ " ${base#*: } " != *" $package "* ]] || fail "default bootstrap would install desktop package $package"
	[[ " ${with#*: } " == *" $package "* ]] || fail "--desktop does not install $package"
done
extra="$(LC_ALL=C comm -13 <(tr ' ' '\n' <<<"${base#*: }" | LC_ALL=C sort) <(tr ' ' '\n' <<<"${with#*: }" | LC_ALL=C sort))"
[[ "$extra" == "$(printf '%s\n' "${desktop[@]}" | LC_ALL=C sort)" ]] || fail "--desktop added something outside its manifest: $extra"
[[ "$(listing laptop-intel)" == "$base" ]] || fail 'the default listing depends on the archetype'

printf 'desktop apps: --desktop adds its manifest only; the default listing is untouched\n'
