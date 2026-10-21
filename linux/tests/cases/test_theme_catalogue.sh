#!/usr/bin/env bash
set -Eeuo pipefail

# Every theme in the catalogue answers the same questions the default theme
# answers, uses only colours the corpus actually contains, declares where its
# pairing sits in the author's own 8x8 root matrix, and stays legible.
#
# The corpus rule is the corpus's own: a colour that is not in it does not
# enter. The matrix rule is likewise theirs: a pair at distance >= 5 is a
# rupture and does not close without a declared mediator.

repo_root="${REPO_ROOT:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)}"

fail() {
	printf '%s\n' "$1" >&2
	exit 1
}
[[ -f "$repo_root/data/palette-corpus.tsv" ]] || fail 'the palette corpus is missing'
[[ -f "$repo_root/data/root-distance.tsv" ]] || fail 'the root distance matrix is missing'

expected_keys="$(grep -oE '^[A-Z][A-Z0-9_]*' "$repo_root/data/theme.conf" | LC_ALL=C sort)"
[[ -n "$expected_keys" ]] || fail 'the default theme declares no keys'

themes=("$repo_root/data/theme.conf")
while IFS= read -r theme; do themes+=("$theme"); done < <(find "$repo_root/data/themes" -name '*.conf' -type f | LC_ALL=C sort)
((${#themes[@]} >= 4)) || fail 'the catalogue offers almost nothing to choose from'

for theme in "${themes[@]}"; do
	name="$(basename -- "$theme" .conf)"
	keys="$(grep -oE '^[A-Z][A-Z0-9_]*' "$theme" | LC_ALL=C sort)"
	[[ "$keys" == "$expected_keys" ]] ||
		fail "theme $name does not answer the same questions as the default: $(comm -3 <(printf '%s\n' "$expected_keys") <(printf '%s\n' "$keys") | tr -d '\t' | tr '\n' ' ')"

	while IFS='=' read -r key value; do
		[[ "$key" =~ ^[A-Z] ]] || continue
		[[ "$value" =~ ^[0-9A-F]{6}$ ]] || fail "$name: $key is not bare upper-case hex: $value"
		grep -qE "^$value	" "$repo_root/data/palette-corpus.tsv" ||
			fail "$name: $key uses $value, which is not in the corpus — a colour with no cause is slop"
	done <"$theme"
done

# The declared pairing must match the matrix, and a rupture must name what
# carries it.
for theme in "$repo_root"/data/themes/*.conf; do
	name="$(basename -- "$theme" .conf)"
	dominant="$(sed -nE 's/^# @dominant: (.*)$/\1/p' "$theme")"
	accent="$(sed -nE 's/^# @accent: (.*)$/\1/p' "$theme")"
	declared="$(sed -nE 's/^# @distance: (.*)$/\1/p' "$theme")"
	[[ -n "$dominant" && -n "$accent" ]] || fail "$name declares no dominant and accent roots"
	[[ "$declared" =~ ^[0-9]$ ]] || fail "$name declares no distance"

	actual="$(awk -F'\t' -v a="$dominant" -v b="$accent" \
		'!/^#/ && NF && (($1 == a && $2 == b) || ($1 == b && $2 == a)) { print $3 }' \
		"$repo_root/data/root-distance.tsv")"
	[[ -n "$actual" ]] || fail "$name pairs $dominant with $accent, which the matrix does not list"
	((declared == actual)) || fail "$name claims distance $declared for $dominant+$accent; the matrix says $actual"

	if ((actual >= 5)); then
		sed -nE 's/^# @mediator: (.*)$/\1/p' "$theme" | grep -q . ||
			fail "$name is a rupture at distance $actual and names no mediator"
	fi
done

# Legibility is not a matter of taste: body text and the accent have to clear
# a contrast floor against the background they sit on.
python - "${themes[@]}" <<'PY'
import math
import sys
from pathlib import Path


def channel(component: float) -> float:
    component /= 255
    return component / 12.92 if component <= 0.03928 else ((component + 0.055) / 1.055) ** 2.4


def luminance(hex_value: str) -> float:
    r, g, b = (int(hex_value[i:i + 2], 16) for i in (0, 2, 4))
    return 0.2126 * channel(r) + 0.7152 * channel(g) + 0.0722 * channel(b)


def ratio(a: str, b: str) -> float:
    first, second = luminance(a), luminance(b)
    lighter, darker = max(first, second), min(first, second)
    return (lighter + 0.05) / (darker + 0.05)


FLOORS = (("COLOR_FG", 7.0), ("COLOR_FG_DIM", 4.5), ("COLOR_ACCENT", 3.0), ("TERMINAL_FG", 7.0))

# Two roles painted the same colour are one role with two names. northern-lights
# shipped COLOR_MUTED identical to COLOR_FG_DIM and COLOR_INFO a hair from
# COLOR_ACCENT, so a footer hint and a dimmed subtitle came out the same, and
# so did an accent and a notice -- distinctions every other theme makes.
# Contrast against the background cannot see this: these pairs sit at similar
# luminance by design and differ in hue, so they are compared by perceptual
# distance instead. The floor is well under the closest pair the catalogue
# ships (79.8, the-hermit accent against info); it is there to catch roles
# that collapse, not to arbitrate taste.
SEPARATIONS = ((("COLOR_FG_DIM", "COLOR_MUTED"), 60.0), (("COLOR_ACCENT", "COLOR_INFO"), 60.0))


def distance(a: str, b: str) -> float:
    """Redmean: a cheap approximation of perceived difference between two sRGB colours."""
    first = [int(a[i:i + 2], 16) for i in (0, 2, 4)]
    second = [int(b[i:i + 2], 16) for i in (0, 2, 4)]
    mean_red = (first[0] + second[0]) / 2
    weights = (2 + mean_red / 256, 4.0, 2 + (255 - mean_red) / 256)
    return math.sqrt(sum(w * (x - y) ** 2 for w, x, y in zip(weights, first, second)))


failed = False
for path in sys.argv[1:]:
    values = dict(
        line.split("=", 1)
        for line in Path(path).read_text().splitlines()
        if line[:1].isupper() and "=" in line
    )
    name = Path(path).stem
    for key, floor in FLOORS:
        background = values["TERMINAL_BG"] if key.startswith("TERMINAL") else values["COLOR_BG"]
        measured = ratio(values[key], background)
        if measured < floor:
            print(f"{name}: {key} is {measured:.1f}:1 against its background, under the {floor}:1 floor", file=sys.stderr)
            failed = True
    for (one, other), floor in SEPARATIONS:
        apart = distance(values[one], values[other])
        if apart < floor:
            print(f"{name}: {one} and {other} are {apart:.0f} apart, under the {floor:.0f} floor; they read as one colour", file=sys.stderr)
            failed = True
sys.exit(1 if failed else 0)
PY

printf 'theme catalogue: %d themes, corpus-only colours, declared distances match the matrix\n' "${#themes[@]}"
