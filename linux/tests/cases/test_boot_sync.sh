#!/usr/bin/env bash
set -Eeuo pipefail

# The boot menu follows the theme, and the part that runs as root believes
# nothing it is handed.
#
# scripts/boot-sync.py is the Linux twin of windows/scripts/boot-sync.ps1: it
# reads a stage the user wrote, validates it, and writes only
# grub/themes/vivac/ and EFI/HackBGRT/splash.bmp on the EFI partition. Here
# the partition is a folder in a sandbox; nothing touches /boot.

repo_root="${REPO_ROOT:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)}"
sync_py="$repo_root/scripts/boot-sync.py"
stage_sh="$repo_root/scripts/boot-stage.sh"

fail() {
	printf '%s\n' "$1" >&2
	exit 1
}
[[ -f "$sync_py" ]] || fail 'scripts/boot-sync.py is missing'
[[ -x "$sync_py" ]] || fail 'scripts/boot-sync.py is not executable'
command -v python3 >/dev/null && python3 -c 'import PIL' 2>/dev/null || {
	printf 'boot-sync: skipped, python3 with Pillow is not installed\n'
	exit 0
}

sandbox="$(mktemp -d "${TMPDIR:-/tmp}/vivac-boot-sync.XXXXXX")"
trap 'rm -rf -- "$sandbox"' EXIT
log="$sandbox/boot-sync.log"

# ---------------------------------------------------------------- fixtures

# make_stage DIR THEME -- a good stage: the palette of THEME, a screen of
# 800x600 and two PNGs of another size (they must be redrawn to fit).
make_stage() {
	python3 -I - "$1" "$repo_root/data/themes/$2.conf" "$2" <<'PY'
import sys, os
from PIL import Image
stage, conf, theme = sys.argv[1:4]
keys = ('COLOR_BG','COLOR_FG','COLOR_FG_DIM','COLOR_SURFACE','COLOR_SURFACE_ALT','COLOR_ACCENT','COLOR_MUTED','COLOR_BORDER_INACTIVE')
kv = dict(l.strip().split('=', 1) for l in open(conf) if l[:6] == 'COLOR_')
os.makedirs(stage, exist_ok=True)
open(stage + '/palette.conf', 'w').write('THEME=%s\nWIDTH=800\nHEIGHT=600\n' % theme + ''.join('%s=%s\n' % (k, kv[k]) for k in keys))
Image.new('RGB', (320, 200), (200, 10, 10)).save(stage + '/splash.png')
Image.new('RGBA', (320, 200), (10, 200, 10, 255)).save(stage + '/background.png')
PY
}

# make_fonts ESP -- a starfield with the fonts GRUB ships, as far as the
# theme is concerned: PFF2 files that declare a name.
make_fonts() {
	python3 -I - "$1/grub/themes/starfield" <<'PY'
import sys, os
d = sys.argv[1]
os.makedirs(d, exist_ok=True)
for name, f in (('DejaVu Sans Regular 16','dejavu_16.pf2'),('DejaVu Sans Regular 12','dejavu_12.pf2'),('DejaVu Sans Bold 14','dejavu_bold_14.pf2')):
    n = name.encode() + b'\0'
    open(os.path.join(d, f), 'wb').write(b'FILE' + (4).to_bytes(4, 'big') + b'PFF2' + b'NAME' + len(n).to_bytes(4, 'big') + n + b'DATA' + (0).to_bytes(4, 'big'))
PY
}

# make_esp DIR [hackbgrt|nohackbgrt] -- the shape of the real partition.
make_esp() {
	local esp="$1"
	mkdir -p "$esp/grub/themes/vivac" "$esp/EFI/Microsoft/Boot"
	make_fonts "$esp"
	printf 'menuentry "Windows 11" {}\n' >"$esp/grub/custom.cfg"
	printf 'MZ' >"$esp/EFI/Microsoft/Boot/bootmgfw.efi"
	if [[ "${2:-hackbgrt}" == hackbgrt ]]; then
		mkdir -p "$esp/EFI/HackBGRT"
		printf 'MZ' >"$esp/EFI/HackBGRT/loader.efi"
		printf 'old logo' >"$esp/EFI/HackBGRT/splash.bmp"
	fi
}

# snapshot DIR -- every path with its kind, size and hash, links included.
snapshot() {
	(cd -- "$1" && find . -printf '%p %y %s %l\n' | LC_ALL=C sort && find . -type f -print0 | LC_ALL=C sort -z | xargs -0 -r sha256sum)
}

run_sync() { # run_sync STAGE ESP
	python3 "$sync_py" --stage "$1" --esp "$2" --log "$log" >/dev/null 2>&1
}

# ------------------------------------------------ (a) the theme the same as Windows writes
esp="$sandbox/esp"
make_esp "$esp"
make_stage "$sandbox/stage" metropolis
run_sync "$sandbox/stage" "$esp" || fail "a good stage was refused: $(tail -n 3 "$log")"
theme="$esp/grub/themes/vivac/theme.txt"
[[ -f "$theme" ]] || fail 'no theme.txt was written'
[[ "$(head -n 1 "$theme")" == "# vivac: written by boot-sync from the theme 'metropolis'."* ]] ||
	fail "theme.txt does not carry the boot-sync header: $(head -n 1 "$theme")"
for want in 'desktop-color: "#283536"' 'selected_item_color = "#283536"' 'item_color = "#C9C9C8"' \
	'color = "#AAA875"' 'bg_color = "#302B21"' 'color = "#B9B9B9"' 'color = "#979367"' \
	'terminal-font: "DejaVu Sans Regular 16"' 'font = "DejaVu Sans Bold 14"' 'item_height = 34'; do
	grep -qF -- "$want" "$theme" || fail "theme.txt lacks: $want"
done

# The golden: what the Windows task wrote on the real machine for the same
# palette and the same fonts. Compared when this machine has it.
golden=/boot/efi/grub/themes/vivac/theme.txt
if [[ -r "$golden" && -r /boot/efi/grub/themes/starfield ]] &&
	[[ "$(sed -n '1s/.*theme .\(.*\).\. Rewritten.*/\1/p' "$golden")" == metropolis ]]; then
	rm -rf -- "$sandbox/gesp"
	mkdir -p "$sandbox/gesp/grub/themes" "$sandbox/gesp/EFI"
	cp -r /boot/efi/grub/themes/starfield "$sandbox/gesp/grub/themes/"
	run_sync "$sandbox/stage" "$sandbox/gesp" || fail 'the golden comparison run failed'
	[[ -z "${BOOT_SYNC_TRACE:-}" ]] || echo "golden compared"
	diff <(tail -n +3 "$sandbox/gesp/grub/themes/vivac/theme.txt") <(tail -n +3 "$golden") >/dev/null ||
		fail 'theme.txt differs from what boot-sync.ps1 wrote for metropolis (beyond the two header lines)'
fi

# ------------------------------------------------ (b) the pieces carry the palette
python3 -I - "$esp/grub/themes/vivac" <<'PY' || fail 'a piece of the theme is not what the palette says'
import sys
from PIL import Image
d = sys.argv[1]
def px(f, xy): return Image.open('%s/%s.png' % (d, f)).convert('RGBA').getpixel(xy)
bad = []
def want(label, got, exp):
    # premultiplied alpha costs a colour channel one unit at most (GDI+ too)
    if isinstance(got, tuple) and isinstance(exp, tuple) and len(got) == len(exp) and got[-1] == exp[-1] and all(abs(a - b) <= 1 for a, b in zip(got, exp)): return
    if got != exp: bad.append('%s: %r != %r' % (label, got, exp))
# menu: the surface at 92% in the middle, the inactive border on the outside
want('menu_c', px('menu_c', (0, 0)), (0x30, 0x2B, 0x21, 235))
want('menu_w edge', px('menu_w', (0, 0)), (0x54, 0x4E, 0x40, 255))
want('menu_w inside', px('menu_w', (11, 0)), (0x30, 0x2B, 0x21, 235))
want('menu_n edge', px('menu_n', (0, 0)), (0x54, 0x4E, 0x40, 255))
want('menu_nw outer corner', px('menu_nw', (0, 0))[3], 0)
# select: the accent, no border
want('select_c', px('select_c', (1, 1)), (0xAA, 0xA8, 0x75, 255))
want('select_nw outer corner', px('select_nw', (0, 0))[3], 0)
for n in ('nw','n','ne','w','c','e','sw','s','se'):
    for pre, r in (('menu_', 12), ('select_', 8)):
        sz = Image.open('%s/%s%s.png' % (d, pre, n)).size
        exp = {'nw':(r,r),'ne':(r,r),'sw':(r,r),'se':(r,r),'n':(2,r),'s':(2,r),'w':(r,2),'e':(r,2),'c':(2,2)}[n]
        want(pre + n + ' size', sz, exp)
bg = Image.open(d + '/background.png')
want('background size', bg.size, (800, 600)); want('background mode', bg.mode, 'RGB')
want('background pixel', bg.getpixel((400, 300)), (10, 200, 10))
if bad: print('\n'.join(bad), file=sys.stderr); sys.exit(1)
PY
python3 -I - "$esp/EFI/HackBGRT/splash.bmp" <<'PY' || fail 'splash.bmp is not the 24-bit, 54-byte-header, screen-sized bitmap HackBGRT reads'
import sys, struct
from PIL import Image
b = open(sys.argv[1], 'rb').read()
assert b[:2] == b'BM' and struct.unpack('<I', b[10:14])[0] == 54 and struct.unpack('<H', b[28:30])[0] == 24, 'header'
assert struct.unpack('<ii', b[18:26]) == (800, 600), 'size'
assert Image.open(sys.argv[1]).getpixel((5, 5)) == (200, 10, 10), 'pixel'
PY

# ------------------------------------------------ (c) a hostile stage is refused, and nothing is written
refuse() { # refuse LABEL -- the stage in $sandbox/bad must be rejected with the partition untouched
	local label="$1" before after
	rm -rf -- "$sandbox/besp"
	make_esp "$sandbox/besp"
	before="$(snapshot "$sandbox/besp")"
	: >"$log"
	if run_sync "$sandbox/bad" "$sandbox/besp"; then fail "accepted: $label"; fi
	after="$(snapshot "$sandbox/besp")"
	[[ "$before" == "$after" ]] || fail "refused but still wrote to the partition: $label"
	grep -q "failed:" "$log" || fail "no failure was logged: $label"
	[[ -z "${BOOT_SYNC_TRACE:-}" ]] || printf "%s -> %s\n" "$label" "$(tail -n 1 "$log" | cut -c 22-)"
}
fresh() {
	rm -rf -- "$sandbox/bad"
	make_stage "$sandbox/bad" metropolis
}
fresh
printf 'COLOR_EXTRA=AABBCC\n' >>"$sandbox/bad/palette.conf"
refuse 'an extra key in the palette'
fresh
sed -i 's/^COLOR_ACCENT=.*/COLOR_ACCENT=AAA875;rm -rf \//' "$sandbox/bad/palette.conf"
refuse 'a colour that is not six hex digits'
fresh
sed -i 's/^COLOR_FG=.*/COLOR_FG=ABC/' "$sandbox/bad/palette.conf"
refuse 'a short colour'
fresh
sed -i '/^COLOR_MUTED=/d' "$sandbox/bad/palette.conf"
refuse 'a missing colour'
fresh
printf 'COLOR_BG=000000\n' >>"$sandbox/bad/palette.conf"
refuse 'a repeated key'
fresh
sed -i 's/^WIDTH=.*/WIDTH=9999/' "$sandbox/bad/palette.conf"
refuse 'an absurd screen width'
fresh
sed -i 's/^HEIGHT=.*/HEIGHT=100/' "$sandbox/bad/palette.conf"
refuse 'an absurd screen height'
fresh
sed -i 's/^WIDTH=.*/WIDTH=12345/' "$sandbox/bad/palette.conf"
refuse 'a five-digit width'
fresh
head -c 5000 /dev/zero | tr '\0' '#' >>"$sandbox/bad/palette.conf"
refuse 'an oversized palette'
fresh
rm "$sandbox/bad/splash.png"
printf 'secret' >"$sandbox/target"
ln -s "$sandbox/target" "$sandbox/bad/splash.png"
refuse 'a symlink in place of splash.png'
fresh
rm "$sandbox/bad/palette.conf"
ln -s "$sandbox/stage/palette.conf" "$sandbox/bad/palette.conf"
refuse 'a symlink in place of palette.conf'
fresh
printf 'this is not a picture' >"$sandbox/bad/background.png"
refuse 'a background that is not an image'
fresh
python3 -I -c "
from PIL import Image
import sys
Image.new('RGB', (40, 40), (1, 2, 3)).save(sys.argv[1] + '/background.png', 'JPEG')" "$sandbox/bad"
refuse 'a JPEG renamed to background.png'
fresh
python3 -I -c "
from PIL import Image
import sys
Image.new('1', (30000, 30000)).save(sys.argv[1] + '/splash.png', 'PNG', optimize=True)" "$sandbox/bad"
refuse 'a 900-megapixel splash.png (decompression bomb)'
fresh
head -c 43000000 /dev/urandom >"$sandbox/bad/background.png"
refuse 'a background over 40 MB'
fresh
mkfifo "$sandbox/bad/fifo" && rm "$sandbox/bad/splash.png" && mv "$sandbox/bad/fifo" "$sandbox/bad/splash.png"
refuse 'a fifo in place of splash.png'
rm -rf -- "$sandbox/bad"
mkdir "$sandbox/linkdir"
ln -s "$sandbox/stage" "$sandbox/linkdir/bad-link"
python3 "$sync_py" --stage "$sandbox/linkdir/bad-link" --esp "$sandbox/besp" --log "$log" >/dev/null 2>&1 && fail 'the stage folder itself was followed as a symlink'

# ------------------------------------------------ (d) no HackBGRT, no splash
rm -rf -- "$sandbox/nesp"
make_esp "$sandbox/nesp" nohackbgrt
run_sync "$sandbox/stage" "$sandbox/nesp" || fail 'a partition without HackBGRT was refused'
[[ ! -e "$sandbox/nesp/EFI/HackBGRT" ]] || fail 'EFI/HackBGRT was created on a partition that had none'
[[ -f "$sandbox/nesp/grub/themes/vivac/theme.txt" ]] || fail 'the GRUB theme was not written without HackBGRT'
rm -rf -- "$sandbox/gesp2"
mkdir -p "$sandbox/gesp2/EFI/HackBGRT"
printf 'old' >"$sandbox/gesp2/EFI/HackBGRT/splash.bmp"
run_sync "$sandbox/stage" "$sandbox/gesp2" || fail 'a partition without GRUB was refused'
[[ ! -e "$sandbox/gesp2/grub" ]] || fail 'grub/ was created on a partition that had none'
[[ "$(head -c 2 "$sandbox/gesp2/EFI/HackBGRT/splash.bmp")" == BM ]] || fail 'the splash was not written when GRUB is absent'

# ------------------------------------------------ (e) only the two paths are written
rm -rf -- "$sandbox/wesp"
make_esp "$sandbox/wesp"
mkdir -p "$sandbox/wesp/grub/themes/vivac"
printf 'stale' >"$sandbox/wesp/grub/themes/vivac/stale.png"
before="$(snapshot "$sandbox/wesp")"
run_sync "$sandbox/stage" "$sandbox/wesp" || fail 'the write-scope run failed'
after="$(snapshot "$sandbox/wesp")"
changed="$({ diff <(printf '%s\n' "$before") <(printf '%s\n' "$after") || true; } | sed -n 's/^[<>] [0-9a-f]\{64\}  //p; s/^[<>] \(\.[^ ]*\) .*/\1/p' | LC_ALL=C sort -u)"
while IFS= read -r path; do
	[[ -z "$path" ]] && continue
	case "$path" in
	./grub/themes/vivac | ./grub/themes/vivac/* | ./EFI/HackBGRT/splash.bmp) ;;
	*) fail "boot-sync touched $path" ;;
	esac
done <<<"$changed"
[[ ! -e "$sandbox/wesp/grub/themes/vivac/stale.png" ]] || fail 'a stale file was left in the theme folder'
[[ -z "$(find "$sandbox/wesp/grub/themes/vivac" -name '.new-*')" ]] || fail 'a scratch file was left behind'
[[ "$(find "$sandbox/wesp/grub/themes/vivac" -name '*.pf2' | wc -l)" == 3 ]] || fail 'the fonts were not carried into the theme folder'
# A second run with fonts only in our own folder keeps them.
rm -rf -- "$sandbox/wesp/grub/themes/starfield"
run_sync "$sandbox/stage" "$sandbox/wesp" || fail 'a run with the fonts only in vivac/ failed'
[[ "$(find "$sandbox/wesp/grub/themes/vivac" -name '*.pf2' | wc -l)" == 3 ]] || fail 'the fonts of vivac/ were dropped'
grep -qF 'terminal-font: "DejaVu Sans Regular 16"' "$sandbox/wesp/grub/themes/vivac/theme.txt" || fail 'the fonts of vivac/ are not used'
# Another theme, same partition: the palette moves, the pieces follow.
make_stage "$sandbox/stage2" persephone
run_sync "$sandbox/stage2" "$sandbox/wesp" || fail 'a second theme was refused'
grep -q "theme 'persephone'" "$sandbox/wesp/grub/themes/vivac/theme.txt" || fail 'the header does not name the new theme'

# ------------------------------------------------ boot-stage.sh produces a stage boot-sync accepts
if command -v rsvg-convert >/dev/null && command -v magick >/dev/null && command -v jq >/dev/null; then
	mkdir -p "$sandbox/home/.config/vivac" "$sandbox/ustage"
	rm -rf -- "$sandbox/sesp"
	make_esp "$sandbox/sesp"
	HOME="$sandbox/home" XDG_CONFIG_HOME="$sandbox/home/.config" SETTINGS_FILE="$sandbox/home/.config/vivac/settings" \
		bash "$stage_sh" --stage "$sandbox/ustage" --theme metropolis --size 1280x720 >/dev/null ||
		fail 'boot-stage.sh failed'
	[[ "$(tail -n 1 -- <(grep -c . "$sandbox/ustage/palette.conf"))" == 11 ]] || fail 'boot-stage.sh wrote a palette of the wrong shape'
	run_sync "$sandbox/ustage" "$sandbox/sesp" || fail "boot-sync refused what boot-stage.sh staged: $(tail -n 2 "$log")"
	python3 -I -c "
from PIL import Image
import sys
assert Image.open(sys.argv[1]).size == (1280, 720)" "$sandbox/sesp/EFI/HackBGRT/splash.bmp" || fail 'the boot logo is not the screen size'
	# Without a stage folder it must say so, not create one.
	! bash "$stage_sh" --stage "$sandbox/nowhere" --theme metropolis >/dev/null 2>&1 || fail 'boot-stage.sh made a stage out of nothing'
	[[ ! -e "$sandbox/nowhere" ]] || fail 'boot-stage.sh created the stage folder (that is the installer''s)'
else
	printf 'boot-sync: boot-stage.sh half skipped, rsvg-convert, magick or jq is missing\n'
fi

printf 'boot-sync: theme, pieces, refusals, scope and stage all hold\n'
