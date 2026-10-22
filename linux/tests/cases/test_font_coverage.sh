#!/usr/bin/env bash
set -Eeuo pipefail

# CJK and emoji are covered by fonts the base manifest installs, and the VM
# gate proves it by code point (fc-match ':charset=...'), not by family name.
# Here: the manifest names the fonts, tests/guest-acceptance.sh asks by code point,
# and, when this host has the same fonts, fc-match agrees.

repo_root="${REPO_ROOT:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)}"

fail() {
	printf '%s\n' "$1" >&2
	exit 1
}
for font in noto-fonts noto-fonts-cjk noto-fonts-emoji ttf-jetbrains-mono-nerd; do
	grep -Fxq -- "$font" "$repo_root/packages/pacman.txt" || fail "$font is not in the base manifest"
done
for codepoint in 4e2d 3042 1f600; do
	grep -Fq "charset=$codepoint" "$repo_root/tests/guest-acceptance.sh" || fail "the guest acceptance does not ask fc-match for U+$codepoint"
done
if command -v fc-list >/dev/null && fc-list | grep -q 'Noto Sans CJK'; then
	fc-match -f '%{family}\n' ':charset=4e2d' | grep -q 'CJK' || fail 'U+4E2D does not resolve to a CJK font on this host'
	fc-match -f '%{family}\n' ':charset=1f600' | grep -qi 'emoji' || fail 'U+1F600 does not resolve to an emoji font on this host'
	printf 'font coverage: manifest, VM assertions, and fc-match by code point on this host\n'
else
	printf 'font coverage: manifest and VM assertions (this host has no Noto CJK to ask)\n'
fi
