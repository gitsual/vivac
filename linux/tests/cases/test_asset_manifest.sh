#!/usr/bin/env bash
set -Eeuo pipefail

# The asset manifest gate must reject all three ways the tree and the manifest
# can disagree. Each scenario runs against a disposable copy of the real assets,
# never against the checkout itself.

repo_root="${REPO_ROOT:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)}"
gate="$repo_root/scripts/check-asset-manifest.sh"

sandbox="$(mktemp -d "${TMPDIR:-/tmp}/vivac-assets.XXXXXX")"
trap 'rm -rf -- "$sandbox"' EXIT

# A minimal tree with one real asset is enough: the gate's three failure modes
# are independent of how many assets are listed.
mkdir -p -- "$sandbox/assets"
fixture="$repo_root/assets/screenshots/cosmos.png"
cp -- "$fixture" "$sandbox/assets/fixture.png"
manifest="$sandbox/manifest.tsv"

run_gate() {
	ASSET_ROOT="$sandbox" ASSET_MANIFEST="$manifest" bash "$gate" "$@"
}

fail() {
	printf '%s\n' "$1" >&2
	exit 1
}

run_gate --update >/dev/null
run_gate >/dev/null || fail 'baseline: a freshly generated manifest must verify'

# Scenario 1 — an asset exists in the tree but is not listed.
cp -- "$repo_root/dotfiles/hypr/.local/share/wallpapers/bad-romance.png" "$sandbox/assets/stray.png"
if run_gate >/dev/null 2>&1; then
	fail 'scenario 1: gate accepted a stray unlisted binary'
fi
rm -- "$sandbox/assets/stray.png"
run_gate >/dev/null || fail 'scenario 1: gate must pass again once the stray file is gone'

# Scenario 2 — a listed asset's bytes changed.
printf 'tampered\n' >>"$sandbox/assets/fixture.png"
if run_gate >/dev/null 2>&1; then
	fail 'scenario 2: gate accepted a tampered asset'
fi
run_gate --update >/dev/null
run_gate >/dev/null || fail 'scenario 2: regenerating the manifest must restore the green state'

# Scenario 3 — a listed asset disappeared from the tree.
rm -- "$sandbox/assets/fixture.png"
if run_gate >/dev/null 2>&1; then
	fail 'scenario 3: gate accepted a manifest entry with no file behind it'
fi

# Scenario 4 — a video is an asset too. `file` reports it as video/mp4 rather
# than image/*, so a gate that only knew about images would walk straight past
# the recorded tour and leave its bytes unpinned.
cp -- "$repo_root/assets/demo.mp4" "$sandbox/assets/film.mp4"
run_gate --update >/dev/null
grep -q $'assets/film.mp4\t' "$manifest" || fail 'scenario 4: the video was never discovered'
frame="$(awk -F'\t' '$1 == "assets/film.mp4" { print $4 }' "$manifest")"
[[ "$frame" == *x* && "$frame" != unknown ]] ||
	fail "scenario 4: the video's frame size was not measured (got '$frame')"
printf 'tampered\n' >>"$sandbox/assets/film.mp4"
if run_gate >/dev/null 2>&1; then
	fail 'scenario 4: gate accepted a tampered video'
fi

# Scenario 5 — an animated GIF is an asset too, and its frame size lives in a
# six-byte header rather than in a PNG chunk or an MP4 track box. A prober that
# only knew those two shapes would pin the bytes but report the size as n/a.
cp -- "$repo_root/assets/gifs/tour-palette.gif" "$sandbox/assets/loop.gif"
run_gate --update >/dev/null
grep -q $'assets/loop.gif\t' "$manifest" || fail 'scenario 5: the animation was never discovered'
frame="$(awk -F'\t' '$1 == "assets/loop.gif" { print $4 }' "$manifest")"
[[ "$frame" == *x* && "$frame" != unknown && "$frame" != n/a ]] ||
	fail "scenario 5: the animation's frame size was not measured (got '$frame')"
printf 'tampered\n' >>"$sandbox/assets/loop.gif"
if run_gate >/dev/null 2>&1; then
	fail 'scenario 5: gate accepted a tampered animation'
fi

printf 'asset manifest gate: 5 scenarios rejected as expected\n'
