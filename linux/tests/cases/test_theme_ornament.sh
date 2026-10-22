#!/usr/bin/env bash
set -Eeuo pipefail

# Ornament is earned, never asked for. A theme may add a layer over the
# wallpaper only when the author's own matrix calls its pairing affinity
# (distance <= 2), or when it carries one of the named aesthetics of the
# corpus — and carrying it means actually holding that aesthetic's canonical
# hexes, not printing its name in a comment.
#
# This case checks both directions: that every claim in the catalogue is a
# claim the theme can back, and that an unearned claim is refused out loud
# instead of quietly rendering without the layer.

repo_root="${REPO_ROOT:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)}"

fail() {
	printf '%s\n' "$1" >&2
	exit 1
}
[[ -f "$repo_root/data/aesthetics.tsv" ]] || fail 'the aesthetics table is missing'

work="$(mktemp -d)"
trap 'rm -rf -- "$work"' EXIT

# Every aesthetic a theme claims has to exist in the table, and a theme that
# claims one has to carry every hex the table fixes for it. This is the same
# rule the renderer enforces; asserting it here names the offending theme even
# when nobody is generating wallpapers.
claimed=0
for theme in "$repo_root"/data/themes/*.conf; do
	name="$(basename -- "$theme" .conf)"
	aesthetic="$(sed -nE 's/^# @aesthetic: (.*)$/\1/p' "$theme")"
	[[ -n "$aesthetic" ]] || continue
	claimed=$((claimed + 1))
	row="$(awk -F'\t' -v a="$aesthetic" '!/^#/ && NF && $1 == a' "$repo_root/data/aesthetics.tsv")"
	[[ -n "$row" ]] || fail "$name claims the aesthetic $aesthetic, which the corpus does not list"
	while IFS= read -r hex; do
		grep -qE "^[A-Z_]+=$hex$" "$theme" ||
			fail "$name claims $aesthetic but does not carry its canonical $hex"
	done < <(cut -f3 <<<"$row" | tr ',' '\n')
done
((claimed > 0)) || fail 'no theme carries a named aesthetic; the corpus is not reaching the catalogue'

# Every declared ornament has a template to render, and the eligibility rule
# holds: affinity, or an aesthetic the table lets ornament.
ornamented=0
for theme in "$repo_root"/data/themes/*.conf; do
	name="$(basename -- "$theme" .conf)"
	declared="$(sed -nE 's/^# @ornament: (.*)$/\1/p' "$theme")"
	[[ -n "$declared" ]] || continue
	ornamented=$((ornamented + 1))
	[[ -f "$repo_root/templates/wallpaper/ornament-$declared.svg.in" ]] ||
		fail "$name declares the ornament $declared, which has no template"

	distance="$(sed -nE 's/^# @distance: (.*)$/\1/p' "$theme")"
	((distance <= 2)) && continue
	aesthetic="$(sed -nE 's/^# @aesthetic: (.*)$/\1/p' "$theme")"
	[[ -n "$aesthetic" ]] ||
		fail "$name ornaments a pairing at distance $distance and names no aesthetic to carry it"
	allowed="$(awk -F'\t' -v a="$aesthetic" '!/^#/ && NF && $1 == a { print $4 }' "$repo_root/data/aesthetics.tsv")"
	[[ "$allowed" == yes ]] ||
		fail "$name ornaments under $aesthetic, which the corpus marks anti-ornamento"
done
((ornamented > 0)) || fail 'nothing in the catalogue has earned an ornament'

# The renderer itself: a full pass leaves no unresolved token behind, and the
# themes that earned a layer are exactly the ones that carry one.
"$repo_root/scripts/make-wallpaper.sh" --all --no-raster --out "$work" >"$work/log" 2>&1 ||
	fail "rendering the catalogue failed: $(tail -3 "$work/log")"
for svg in "$work"/*.svg; do
	grep -qE '@[A-Z][A-Z0-9_]*(:[a-z]+)?@' "$svg" &&
		fail "$(basename -- "$svg") still holds an unrendered token"
	tail -1 "$svg" | grep -q '</svg>' || fail "$(basename -- "$svg") is not closed"
done
rendered="$(grep -c ' + ' "$work/log" || true)"
((rendered == ornamented)) ||
	fail "$ornamented themes declare an ornament but $rendered rendered one"

# The negative direction. A theme that asks for a layer it has not earned is
# refused, and the refusal names the reason rather than rendering a plain
# wallpaper and saying nothing.
sed -E 's/^# @aesthetic: .*$/# @aesthetic: Nowhere/' \
	"$repo_root/data/themes/cosmos.conf" >"$work/pretender.conf"
grep -q 'Nowhere' "$work/pretender.conf" || fail 'the fixture did not take the unknown aesthetic'
if "$repo_root/scripts/make-wallpaper.sh" --theme "$work/pretender.conf" --no-raster \
	--out "$work" >"$work/pretend.log" 2>&1; then
	fail 'a theme claiming an aesthetic outside the corpus still received its ornament'
fi
grep -q 'the corpus does not list' "$work/pretend.log" ||
	fail "the refusal did not name the cause: $(tail -1 "$work/pretend.log")"

printf 'theme ornament: %d earned layers, %d aesthetic claims backed by their canonical hexes\n' \
	"$ornamented" "$claimed"
