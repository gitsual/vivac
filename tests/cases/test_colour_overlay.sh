#!/usr/bin/env bash
set -Eeuo pipefail

# Owner-structured configs get the palette's colours and nothing else.
#
# The fixtures are shaped like real owner files (CSS, kitty, dunst, rasi) but
# are synthetic: their colours are read out of the catalogue, never typed here,
# so the test follows a palette edit instead of hiding one.

repo_root="${REPO_ROOT:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)}"
overlay="$repo_root/scripts/colour-overlay.sh"
fail() {
	printf '%s\n' "$1" >&2
	exit 1
}
[[ -x "$overlay" ]] || fail 'scripts/colour-overlay.sh is missing or not executable'

sandbox="$(mktemp -d "${TMPDIR:-/tmp}/vivac-colour.XXXXXX")"
trap 'rm -rf -- "$sandbox"' EXIT
cfg="$sandbox/config" state="$sandbox/state"

tok() { sed -nE "s/^$2=(.*)$/\1/p" "$1"; }
rgb() { printf '%d, %d, %d' "0x${1:0:2}" "0x${1:2:2}" "0x${1:4:2}"; }
lower() { tr 'A-F' 'a-f' <<<"$1"; }
sha() { sha256sum -- "$1" | cut -d' ' -f1; }
run() { XDG_STATE_HOME="$state" "$overlay" --apply "$1" --config-dir "$cfg" >/dev/null 2>"$sandbox/err"; }
# A file with every colour literal replaced by a marker: what is left is the
# structure, which must not move.
skeleton() { sed -E 's/#[0-9a-fA-F]{6}([0-9a-fA-F]{2})?/C/g; s/rgba?\([0-9]+, [0-9]+, [0-9]+/rgb(C/g' "$1"; }

d="$repo_root/data/theme.conf" c="$repo_root/data/themes/carmen.conf" g="$repo_root/data/themes/gatsby.conf"
bg="$(tok "$d" COLOR_BG)" ac="$(tok "$d" COLOR_ACCENT)" fg="$(tok "$d" COLOR_FG)"
tbg="$(tok "$d" TERMINAL_BG)" tfg="$(tok "$d" TERMINAL_FG)"
cbg="$(tok "$c" COLOR_BG)" cac="$(tok "$c" COLOR_ACCENT)" gbg="$(tok "$g" COLOR_BG)"
[[ "$bg" != "$cbg" && "$bg" != "$gbg" && "$cbg" != "$gbg" ]] || fail 'fixture themes do not differ in background'

mkdir -p "$cfg"/{waybar,kitty,dunst,rofi,wofi}
cat >"$cfg/waybar/style.css" <<CSS
* { font-family: "Sans"; font-size: 13px; }
window#waybar { background: rgba($(rgb "$bg"), 0.95); border-bottom: 3px solid #$ac; color: #$fg; }
#clock { color: #$(lower "$fg"); padding: 0 8px; }
#odd { color: #123456; margin: 2px; }
CSS
cat >"$cfg/kitty/kitty.conf" <<CONF
font_size 11
foreground #$(lower "$tfg")
background #$tbg
color4 #123456
CONF
cat >"$cfg/dunst/dunstrc" <<CONF
[global]
    font = Mono 10
    frame_color = "#$ac"
    background = "#$bg"
CONF
cat >"$cfg/rofi/config.rasi" <<CONF
* { bg0: #${bg}f2; fg0: #$(lower "$fg"); sel: rgba($(rgb "$ac"), 0.5); odd: #123456; }
CONF
cat >"$cfg/wofi/style.css" <<CSS
window { border: 2px solid #$ac; background-color: #$bg; }
CSS
files=(waybar/style.css kitty/kitty.conf dunst/dunstrc rofi/config.rasi wofi/style.css)
mkdir -p "$sandbox/orig"
for f in "${files[@]}"; do mkdir -p "$sandbox/orig/$(dirname "$f")" && cp -- "$cfg/$f" "$sandbox/orig/$f"; done

# Colour lines change, every other byte stays; the new colours are the chosen
# palette's, in the notation and case the owner used.
run carmen || fail 'applying a palette failed'
for f in "${files[@]}"; do
	[[ "$(skeleton "$cfg/$f")" == "$(skeleton "$sandbox/orig/$f")" ]] || fail "$f changed beyond its colours"
	cmp -s "$cfg/$f" "$sandbox/orig/$f" && fail "$f did not take the palette"
	grep -qiF "$bg" "$cfg/$f" && fail "$f still holds the previous background"
done
grep -qF "#$cbg" "$cfg/dunst/dunstrc" || fail 'dunst did not get the chosen background'
grep -qF "#${cbg}f2" "$cfg/rofi/config.rasi" || fail 'the alpha suffix was not kept'
grep -qF "rgba($(rgb "$cbg"), 0.95)" "$cfg/waybar/style.css" || fail 'rgba() triplet was not remapped with its alpha'
grep -qF "#$(lower "$(tok "$c" COLOR_FG)")" "$cfg/waybar/style.css" || fail 'lower-case notation was not kept'
grep -qF "#$cac" "$cfg/wofi/style.css" || fail 'wofi did not get the chosen accent'
grep -qF '#123456' "$cfg/kitty/kitty.conf" || fail 'an unknown colour was rewritten'
grep -qF '#123456' "$cfg/rofi/config.rasi" || fail 'an unknown colour in rasi was rewritten'
grep -qF "#$(tok "$c" TERMINAL_BG)" "$cfg/kitty/kitty.conf" || fail 'kitty did not get the terminal background'

# Before the first change the original bytes were kept.
for f in "${files[@]}"; do
	found=0
	while IFS= read -r b; do cmp -s "$b" "$sandbox/orig/$f" && found=1; done < <(find "$state/vivac/colour-overlay" -path '*backup-*' -type f 2>/dev/null)
	((found)) || fail "no backup holds the original bytes of $f"
done
backups="$(find "$state" -path '*backup-*' -type f | wc -l)"

# A second run is a no-op: same bytes, no further backup.
declare -A after=()
for f in "${files[@]}"; do after[$f]="$(sha "$cfg/$f")"; done
run carmen || fail 'second apply failed'
for f in "${files[@]}"; do [[ "${after[$f]}" == "$(sha "$cfg/$f")" ]] || fail "$f is not idempotent"; done
[[ "$(find "$state" -path '*backup-*' -type f | wc -l)" == "$backups" ]] || fail 'a no-op run took another backup'

# Palette to palette: nothing of the previous palette is left, and going back
# to the original restores it byte for byte.
run gatsby || fail 'switching palette failed'
for f in "${files[@]}"; do grep -qiF "$cbg" "$cfg/$f" && fail "$f still holds the previous palette's background"; done
grep -qiF "$gbg" "$cfg/dunst/dunstrc" || fail 'switch did not land the new palette'
run bad-romance || fail 'restoring the original palette failed'
for f in "${files[@]}"; do cmp -s "$cfg/$f" "$sandbox/orig/$f" || fail "$f is not byte-identical after returning to the original palette"; done

# An owner edit after the last swap wins: that file is skipped with a warning.
run carmen
printf 'opacity 0.9\n' >>"$cfg/kitty/kitty.conf"
edited="$(sha "$cfg/kitty/kitty.conf")"
run gatsby || fail 'an edited file made the run fail'
[[ "$edited" == "$(sha "$cfg/kitty/kitty.conf")" ]] || fail 'an owner-edited file was modified'
grep -qi 'kitty' "$sandbox/err" || fail 'no warning for the skipped file'
grep -qiF "$gbg" "$cfg/dunst/dunstrc" || fail 'one skipped file stopped the others'

# --rebase: the owner's edited file becomes the new starting point. The edit
# stays, the palette is applied over it, and the guard stops warning.
rm -rf "$sandbox/cfg5" "$sandbox/state5" && cp -a "$sandbox/orig" "$sandbox/cfg5"
rebase() { XDG_STATE_HOME="$sandbox/state5" "$overlay" --apply "$1" --config-dir "$sandbox/cfg5" "${@:2}" >/dev/null 2>"$sandbox/err5"; }
rebase carmen || fail 'rebase fixture: carmen failed'
printf 'opacity 0.9\n' >>"$sandbox/cfg5/kitty/kitty.conf"
rebase gatsby
grep -qi 'edited' "$sandbox/err5" || fail 'rebase fixture: the edit guard did not warn before --rebase'
{ grep -qF 'opacity 0.9' "$sandbox/cfg5/kitty/kitty.conf" && grep -qiF "$(tok "$c" TERMINAL_BG)" "$sandbox/cfg5/kitty/kitty.conf"; } || fail 'rebase fixture: the guard did not skip the edited file'
rebase gatsby --rebase || fail '--rebase failed'
[[ ! -s "$sandbox/err5" ]] || fail "--rebase still warned: $(<"$sandbox/err5")"
grep -qF 'opacity 0.9' "$sandbox/cfg5/kitty/kitty.conf" || fail '--rebase lost the owner edit'
grep -qiF "$(tok "$g" TERMINAL_BG)" "$sandbox/cfg5/kitty/kitty.conf" || fail '--rebase did not apply the palette over the edited file'
rebase carmen || fail 'after --rebase the next switch failed'
{ grep -qF 'opacity 0.9' "$sandbox/cfg5/kitty/kitty.conf" && grep -qiF "$(tok "$c" TERMINAL_BG)" "$sandbox/cfg5/kitty/kitty.conf"; } || fail 'after --rebase the file is not switchable again'

# An interruption between writing `pristine` and `last` must not wedge the file:
# the next run starts over from the file as it is, and one bad file does not
# stop the others; the run still ends non-zero and names the failure.
rm -rf "$sandbox/cfg6" "$sandbox/state6" && cp -a "$sandbox/orig" "$sandbox/cfg6"
one() { XDG_STATE_HOME="$sandbox/state6" "$overlay" --apply "$1" --config-dir "$sandbox/cfg6" >"$sandbox/out6" 2>"$sandbox/err6"; }
one carmen || fail 'interruption fixture: carmen failed'
cp -- "$sandbox/orig/kitty/kitty.conf" "$sandbox/cfg6/kitty/kitty.conf"
rm -f -- "$sandbox/state6/vivac/colour-overlay/kitty__kitty.conf/last"
chmod 000 "$sandbox/cfg6/dunst/dunstrc"
rc=0
one gatsby || rc=$?
chmod 600 "$sandbox/cfg6/dunst/dunstrc"
grep -qiF "$(tok "$g" TERMINAL_BG)" "$sandbox/cfg6/kitty/kitty.conf" || fail "a missing 'last' wedged the file: $(<"$sandbox/err6")"
grep -qiF "$gbg" "$sandbox/cfg6/wofi/style.css" || fail 'files after the failing one were skipped'
((rc != 0)) || fail 'an unreadable file did not make the run fail'
grep -q 'dunst' "$sandbox/err6" || fail 'the failure summary does not name the file'
one gatsby || fail 'the run is not repeatable after the failure was fixed'

# Absent targets are skipped without creating anything; symlinks (a stowed,
# repository-owned file) are not owner files and are never written through.
rm -rf "$sandbox/cfg2" && cp -a "$sandbox/orig" "$sandbox/cfg2" && rm -rf "$sandbox/state2"
rm -f "$sandbox/cfg2/dunst/dunstrc"
mv "$sandbox/cfg2/wofi/style.css" "$sandbox/stowed.css" && ln -s "$sandbox/stowed.css" "$sandbox/cfg2/wofi/style.css"
XDG_STATE_HOME="$sandbox/state2" "$overlay" --apply carmen --config-dir "$sandbox/cfg2" >/dev/null || fail 'missing target made the run fail'
[[ ! -e "$sandbox/cfg2/dunst/dunstrc" ]] || fail 'a missing dunst config was created'
cmp -s "$sandbox/stowed.css" "$sandbox/orig/wofi/style.css" || fail 'a symlinked file was written through'

# A file with no catalogue colour in it is left alone, backup and all.
rm -f "$sandbox/cfg2/wofi/style.css" && printf 'a { color: #123456; }\n' >"$sandbox/cfg2/wofi/style.css"
XDG_STATE_HOME="$sandbox/state3" "$overlay" --apply carmen --config-dir "$sandbox/cfg2" >/dev/null
[[ "$(cat "$sandbox/cfg2/wofi/style.css")" == 'a { color: #123456; }' ]] || fail 'a file without palette colours was changed'
[[ ! -e "$sandbox/state3/vivac/colour-overlay/wofi__style.css" ]] || fail 'a file without palette colours got a backup'

# Ambiguity: two tokens share a colour in the base palette but not in the
# chosen one. Chrome tools follow COLOR_*, kitty follows TERMINAL_*.
data="$sandbox/data" && mkdir -p "$data/themes"
printf 'COLOR_BG=000001\nCOLOR_FG=000002\nCOLOR_FG_DIM=000002\nTERMINAL_FG=000002\n' >"$data/theme.conf"
printf 'COLOR_BG=000011\nCOLOR_FG=000012\nCOLOR_FG_DIM=000012\nTERMINAL_FG=000014\n' >"$data/themes/two.conf"
mkdir -p "$sandbox/cfg4/wofi" "$sandbox/cfg4/kitty"
printf 'a { color: #000002; background: #000001; }\n' >"$sandbox/cfg4/wofi/style.css"
printf 'foreground #000002\nbackground #000001\n' >"$sandbox/cfg4/kitty/kitty.conf"
COLOUR_OVERLAY_DATA="$data" XDG_STATE_HOME="$sandbox/state4" "$overlay" --apply two --config-dir "$sandbox/cfg4" >/dev/null
grep -qF 'color: #000012; background: #000011' "$sandbox/cfg4/wofi/style.css" || fail 'chrome did not follow COLOR_* for a shared colour'
grep -qF 'foreground #000014' "$sandbox/cfg4/kitty/kitty.conf" || fail 'kitty did not follow TERMINAL_*'
printf 'COLOR_BG=000021\nCOLOR_FG=000022\nCOLOR_FG_DIM=000023\nTERMINAL_FG=000024\n' >"$data/themes/amb2.conf"
printf 'a { color: #000002; }\n' >"$sandbox/cfg4/wofi/style.css"
rm -rf "$sandbox/state4"
COLOUR_OVERLAY_DATA="$data" XDG_STATE_HOME="$sandbox/state4" "$overlay" --apply amb2 --config-dir "$sandbox/cfg4" >/dev/null
grep -qF '#000002' "$sandbox/cfg4/wofi/style.css" || fail 'ambiguity inside COLOR_* was resolved by guessing'

# The tooling holds no palette literal of its own.
if grep -nE '#?\b[0-9A-Fa-f]{6}\b' "$repo_root/scripts/colour-overlay.sh" "$repo_root/scripts/colour-overlay.py" "$repo_root/data/colour-overlay.tsv" | grep -v 'sha256'; then
	fail 'a palette literal lives in the overlay tooling'
fi
bash "$repo_root/tests/cases/test_axis_single_writer.sh" >/dev/null || fail 'the single-writer test no longer passes'
printf 'colour overlay: colours only, idempotent, reversible, guarded\n'
