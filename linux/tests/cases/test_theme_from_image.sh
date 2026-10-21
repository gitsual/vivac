#!/usr/bin/env bash
set -Eeuo pipefail

# A palette from a picture (vivac-theme from-image). The same picture makes the
# same file as on Windows (shared/fixtures/theme-from-image), with either
# decoder; whatever the picture, the palette passes the very gate the shipped
# eight pass (test_theme_catalogue.sh, run over it); and a made palette lives
# outside the checkout yet joins the catalogue, while a hand-edited one that
# breaks the corpus rule does not.

repo_root="${REPO_ROOT:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)}"
maker="$repo_root/scripts/theme-from-image.py"
picker="$repo_root/dotfiles/ricer/.local/bin/vivac-theme"
fixtures="$repo_root/../shared/fixtures/theme-from-image"

fail() {
	printf '%s\n' "$1" >&2
	exit 1
}
[[ -f "$maker" ]] || fail 'scripts/theme-from-image.py is missing'

work="$(mktemp -d)"
trap 'rm -rf -- "$work"' EXIT

# --- the root table --------------------------------------------------------------------------
# Every ground and accent of the corpus has a root, and the table reads each
# shipped theme the way that theme declares itself.
missing="$(awk -F'\t' 'NR == FNR { if (!/^#/ && NF) root[$1] = $2; next }
	!/^#/ && NF && ($3 == "deep" || $3 == "base" || $3 == "accent") && !($1 in root) { print $1 }' \
	"$repo_root/data/corpus-roots.tsv" "$repo_root/data/palette-corpus.tsv")"
[[ -z "$missing" ]] || fail "corpus colours with no root: $(tr '\n' ' ' <<<"$missing")"
for theme in "$repo_root"/data/themes/*.conf; do
	dominant="$(sed -nE 's/^# @dominant: (.*)$/\1/p' "$theme")"
	accent="$(sed -nE 's/^# @accent: (.*)$/\1/p' "$theme")"
	bg="$(sed -nE 's/^COLOR_BG=(.*)$/\1/p' "$theme")"
	hl="$(sed -nE 's/^COLOR_ACCENT=(.*)$/\1/p' "$theme")"
	[[ "$(awk -F'\t' -v h="$bg" '$1 == h { print $2 }' "$repo_root/data/corpus-roots.tsv")" == "$dominant" ]] ||
		fail "$(basename -- "$theme"): the root table files its ground $bg elsewhere than $dominant"
	[[ "$(awk -F'\t' -v h="$hl" '$1 == h { print $2 }' "$repo_root/data/corpus-roots.tsv")" == "$accent" ]] ||
		fail "$(basename -- "$theme"): the root table files its accent $hl elsewhere than $accent"
done

# --- the same file as Windows ----------------------------------------------------------------
decoders=(python)
command -v gdk-pixbuf-pixdata >/dev/null && decoders+=(pixbuf)
if [[ -d "$fixtures" ]]; then
	for fixture in dusk ember; do
		for decoder in "${decoders[@]}"; do
			rm -rf -- "$work/out"
			VIVAC_PICTURE_DECODER="$decoder" python3 -I "$maker" "$fixtures/$fixture.png" --dir "$work/out" \
				--data "$repo_root/data" >/dev/null 2>"$work/err" || fail "$fixture ($decoder): $(cat "$work/err")"
			cmp -s "$work/out/$fixture.conf" "$fixtures/$fixture.conf" ||
				fail "$fixture.png ($decoder decoder) does not make $fixture.conf: $(diff "$fixtures/$fixture.conf" "$work/out/$fixture.conf" | tr '\n' ' ')"
			cmp -s "$work/out/$fixture.png" "$fixtures/$fixture.png" || fail "$fixture: the picture was not kept as the wallpaper"
		done
	done
else
	printf 'fixtures: not inside the product; skipped\n'
fi

# --- any picture passes the catalogue gate ---------------------------------------------------
# Pictures drawn here (a hue each, noise, outliers, some flat) through the
# pure-Python decoder, then the shipped eight plus all of these through
# test_theme_catalogue.sh itself.
mkdir -p -- "$work/gate/data/themes" "$work/pictures"
cp -- "$repo_root/data/theme.conf" "$repo_root/data/palette-corpus.tsv" "$repo_root/data/root-distance.tsv" "$work/gate/data/"
cp -- "$repo_root"/data/themes/*.conf "$work/gate/data/themes/"
python3 -I - "$work/pictures" <<'PY'
import struct, sys, zlib
seed = 12345
def rand():
    global seed
    seed = (seed * 1103515245 + 12345) % 2147483648
    return seed
def png(path, w, h, pixel):
    raw = b"".join(b"\0" + bytes(c for x in range(w) for c in pixel(x, y)) for y in range(h))
    chunk = lambda k, d: struct.pack(">I", len(d)) + k + d + struct.pack(">I", zlib.crc32(k + d))
    open(path, "wb").write(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
                           + chunk(b"IDAT", zlib.compress(raw)) + chunk(b"IEND", b""))
for n in range(10):
    base = [(rand() >> s) % 256 for s in (16, 8, 0)]
    cells = [[min(255, max(0, base[k] + (rand() >> 16) % 81 - 40)) if i % 17 else (rand() >> 8) % 256
              for k in range(3)] for i in range(30 * 20)]
    png(f"{sys.argv[1]}/random-{n}.png", 30, 20, lambda x, y: cells[y * 30 + x])
for name, flat in (("grey", 128), ("white", 255), ("black", 0)):
    png(f"{sys.argv[1]}/{name}.png", 8, 8, lambda x, y: (flat, flat, flat))
PY
for picture in "$work"/pictures/*.png; do
	VIVAC_PICTURE_DECODER=python python3 -I "$maker" "$picture" --dir "$work/gate/data/themes" \
		--data "$repo_root/data" >/dev/null 2>"$work/err" || fail "$(basename -- "$picture"): $(cat "$work/err")"
done
REPO_ROOT="$work/gate" bash "$repo_root/tests/cases/test_theme_catalogue.sh" >"$work/gate.log" 2>&1 ||
	fail "a palette made from a picture fails the catalogue gate: $(cat "$work/gate.log")"
grep -L '^# @verdict: \(affinity\|tension\)$' "$work"/gate/data/themes/random-*.conf | grep -q . &&
	fail 'a palette made from a picture declares a rupture'

# --- the catalogue, outside the checkout -----------------------------------------------------
home="$work/home"
mkdir -p -- "$home/.config/vivac"
run() {
	HOME="$home" XDG_CONFIG_HOME="$home/.config" XDG_STATE_HOME="$home/.state" VIVAC_REPO="$repo_root" \
		SETTINGS_FILE="$home/.config/vivac/settings" VIVAC_LANG=en "$@"
}
picture="$work/pictures/random-3.png"

run "$picker" from-image "$picture" --dry-run >"$work/dry" 2>&1 || fail "the dry run failed: $(cat "$work/dry")"
grep -q $'\e\[48;2;' "$work/dry" || fail 'the dry run shows no truecolour swatch'
[[ ! -e "$home/.config/vivac/themes" ]] || fail 'the dry run wrote something'

name="$(run "$picker" from-image "$picture" --name my-sea 2>/dev/null)" || fail 'from-image failed'
[[ "$name" == my-sea ]] || fail "from-image named the palette $name"
[[ -f "$home/.config/vivac/themes/my-sea.conf" && -f "$home/.config/vivac/themes/my-sea.png" ]] ||
	fail 'the palette and its picture are not in ~/.config/vivac/themes'
run "$picker" --print >"$work/rows"
grep -q '^My Sea — Picture$' "$work/rows" || fail "the picker does not offer the new palette: $(cat "$work/rows")"
[[ "$(tail -1 "$work/rows")" == 'From a picture'* ]] || fail 'the picker has no row to make a palette from a picture'
run "$repo_root/scripts/apply-theme.sh" --list | grep -qx my-sea || fail 'apply-theme does not know the new palette'
run "$picker" from-image "$picture" --name cosmos >/dev/null 2>&1 && fail 'a shipped name was taken'
run "$picker" from-image "$maker" >/dev/null 2>&1 && fail 'a file that is no picture made a palette'

# What came from elsewhere is held to the corpus rule as it is read.
(
	# shellcheck source=lib/kv.sh
	source "$repo_root/lib/kv.sh"
	# shellcheck source=lib/settings.sh
	source "$repo_root/lib/settings.sh"
	# shellcheck source=lib/themes.sh
	source "$repo_root/lib/themes.sh"
	export HOME="$home" XDG_CONFIG_HOME="$home/.config" SETTINGS_FILE="$home/.config/vivac/settings"
	themes="$home/.config/vivac/themes"
	sed 's/^COLOR_BG=.*/COLOR_BG=123456/' "$themes/my-sea.conf" >"$themes/off-corpus.conf"
	sed 's/^# @wallpaper: .*/# @wallpaper: ..\/..\/x.png/' "$themes/my-sea.conf" >"$themes/far-wall.conf"
	cp -- "$themes/my-sea.conf" "$themes/cosmos.conf"
	listed="$(theme_catalogue "$repo_root")"
	grep -qx off-corpus <<<"$listed" && fail 'a palette with a colour outside the corpus is in the catalogue'
	grep -qx far-wall <<<"$listed" && fail 'a palette whose wallpaper is elsewhere is in the catalogue'
	(($(grep -cx cosmos <<<"$listed") == 1)) || fail 'a made palette shadows a shipped name'
	[[ "$(theme_file_for "$repo_root" cosmos)" == "$repo_root/data/themes/cosmos.conf" ]] ||
		fail 'a shipped name does not mean the shipped palette'
	[[ "$(theme_wallpaper_for "$themes/my-sea.conf")" == "$themes/my-sea.png" ]] || fail 'the palette does not wear its picture'

	# With a shared root that is there, new palettes go to its themes/ and are found there.
	mkdir -p -- "$work/share"
	printf 'shared_settings=%s/share/settings\n' "$work" >"$SETTINGS_FILE"
	[[ "$(themes_home)" == "$work/share/themes" ]] || fail "with a shared root, palettes go to $(themes_home)"
	printf 'shared_settings=%s/away/settings\n' "$work" >"$SETTINGS_FILE"
	[[ "$(themes_home)" == "$themes" ]] || fail 'with the shared root away, palettes do not stay home'
)

printf 'theme from a picture: same file as Windows, %d pictures through the catalogue gate, catalogue outside the checkout\n' \
	"$(find "$work/pictures" -name '*.png' | wc -l)"
