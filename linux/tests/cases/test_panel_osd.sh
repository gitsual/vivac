#!/usr/bin/env bash
# The fakes are shell source written out literally: their $ expands when they run.
# shellcheck disable=SC2016
set -Eeuo pipefail

# vivac-panel osd volume, the backend without a screen: up and down move the
# default output by one step and stop at 100%, down stops at 0, mute toggles,
# a raise while muted unmutes, and the result read back is what the indicator
# draws. wpctl is used when present, pactl otherwise; neither is a reason to
# fail loudly (no level, no indicator).

repo_root="${REPO_ROOT:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)}"
fail() {
	printf '%s\n' "$1" >&2
	exit 1
}
sandbox="$(mktemp -d "${TMPDIR:-/tmp}/vivac-osd.XXXXXX")"
trap 'rm -rf -- "$sandbox"' EXIT
mkdir -p "$sandbox/w" "$sandbox/p"

# wpctl: state is "percent muted" in $SANDBOX/state; every call is logged.
cat >"$sandbox/w/wpctl" <<'FAKE'
#!/usr/bin/env bash
echo "$*" >>"$SANDBOX/calls"
read -r vol mute <"$SANDBOX/state"
case "$1" in
get-volume) printf 'Volume: %d.%02d%s\n' $((vol / 100)) $((vol % 100)) "$([[ $mute == 1 ]] && echo ' [MUTED]')" ;;
set-volume)
	shift
	limit=150
	if [[ "$1" == -l ]]; then limit=$(awk -v l="$2" 'BEGIN{printf "%d", l*100}'); shift 2; fi
	[[ "$1" == @DEFAULT_AUDIO_SINK@ ]] || exit 1
	case "$2" in
	*%+) vol=$((vol + ${2%\%+})) ;;
	*%-) vol=$((vol - ${2%\%-})) ;;
	esac
	((vol > limit)) && vol=$limit
	((vol < 0)) && vol=0
	echo "$vol $mute" >"$SANDBOX/state" ;;
set-mute)
	[[ "$2" == @DEFAULT_AUDIO_SINK@ ]] || exit 1
	case "$3" in toggle) mute=$((1 - mute)) ;; 0 | 1) mute=$3 ;; esac
	echo "$vol $mute" >"$SANDBOX/state" ;;
esac
FAKE
# pactl: the same state, in pactl's words.
cat >"$sandbox/p/pactl" <<'FAKE'
#!/usr/bin/env bash
echo "$*" >>"$SANDBOX/calls"
read -r vol mute <"$SANDBOX/state"
case "$1" in
get-sink-volume) printf 'Volume: front-left: 1 / %d%% / 0 dB,   front-right: 1 / %d%% / 0 dB\n        balance 0.00\n' "$vol" "$vol" ;;
get-sink-mute) printf 'Mute: %s\n' "$([[ $mute == 1 ]] && echo yes || echo no)" ;;
set-sink-volume) vol=${3%\%}; ((vol < 0)) && vol=0; echo "$vol $mute" >"$SANDBOX/state" ;;
set-sink-mute) case "$3" in toggle) mute=$((1 - mute)) ;; 0 | 1) mute=$3 ;; esac; echo "$vol $mute" >"$SANDBOX/state" ;;
esac
FAKE
chmod +x "$sandbox/w/wpctl" "$sandbox/p/pactl"

run() { # path-dir python-body
	VIVAC_WPCTL="$1/wpctl" VIVAC_PACTL="$1/pactl" SANDBOX="$sandbox" VIVAC_LANG=en /usr/bin/python3 -I -c "import sys; sys.path.insert(0, '$repo_root/lib'); from vivacpanel import osd
$2"
}
state() { cat "$sandbox/state"; }

for backend in w p; do
	label=wpctl
	[[ $backend == p ]] && label=pactl
	echo '50 0' >"$sandbox/state"
	: >"$sandbox/calls"
	out="$(run "$sandbox/$backend" 'v = osd.change("up"); print(v.percent, v.muted)')" || fail "$label up failed: $out"
	[[ "$out" == '55 False' ]] || fail "$label up: $out"
	out="$(run "$sandbox/$backend" 'v = osd.change("down"); v = osd.change("down"); print(v.percent, v.muted)')"
	[[ "$out" == '45 False' ]] || fail "$label down twice: $out"
	echo '98 0' >"$sandbox/state"
	out="$(run "$sandbox/$backend" 'v = osd.change("up"); print(v.percent)')"
	[[ "$out" == 100 && "$(state)" == '100 0' ]] || fail "$label up past 100 was not capped: $out / $(state)"
	out="$(run "$sandbox/$backend" 'v = osd.change("up"); print(v.percent)')"
	[[ "$out" == 100 ]] || fail "$label up at 100 moved: $out"
	echo '3 0' >"$sandbox/state"
	out="$(run "$sandbox/$backend" 'print(osd.change("down").percent)')"
	[[ "$out" == 0 ]] || fail "$label down below 0: $out"
	echo '40 0' >"$sandbox/state"
	out="$(run "$sandbox/$backend" 'v = osd.change("mute"); print(v.percent, v.muted)')"
	[[ "$out" == '40 True' ]] || fail "$label mute: $out"
	out="$(run "$sandbox/$backend" 'v = osd.change("mute"); print(v.percent, v.muted)')"
	[[ "$out" == '40 False' ]] || fail "$label unmute: $out"
	echo '40 1' >"$sandbox/state"
	out="$(run "$sandbox/$backend" 'v = osd.change("up"); print(v.percent, v.muted)')"
	[[ "$out" == '45 False' ]] || fail "$label up while muted should unmute: $out"
	echo '120 0' >"$sandbox/state"
	out="$(run "$sandbox/$backend" 'print(osd.change("up").percent, osd.change("down").percent)')"
	[[ "$out" == '100 95' ]] || fail "$label up from a level above 100 should land on 100: $out"
	out="$(run "$sandbox/$backend" 'v = osd.read(); print(v.percent, v.muted)')"
	[[ "$out" == '95 False' ]] || fail "$label read: $out"
	run "$sandbox/$backend" 'osd.change("sideways")' >/dev/null 2>&1 && fail "$label took an unknown action"
done

# wpctl is asked for the limit itself, never for more than 100% by up.
grep -q -- 'set-volume -l 1.0 @DEFAULT_AUDIO_SINK@ 5%+' "$sandbox/calls" && fail 'pactl run called wpctl'
: >"$sandbox/calls"
echo '50 0' >"$sandbox/state"
run "$sandbox/w" 'osd.change("up")' >/dev/null
grep -q -- 'set-volume -l 1.0 @DEFAULT_AUDIO_SINK@ 5%+' "$sandbox/calls" || fail "wpctl up call: $(cat "$sandbox/calls")"

# --- nothing to drive: no level, no crash ---------------------------------------------------------------------
out="$(run "$sandbox/none" 'print(osd.read(), osd.change("up"))')" || fail "no audio tools: $out"
[[ "$out" == 'None None' ]] || fail "no audio tools gave a level: $out"

# --- glyph and label follow the level --------------------------------------------------------------------------
out="$(run "$sandbox/w" 'print(len({osd.glyph(0, False), osd.glyph(20, False), osd.glyph(50, False), osd.glyph(90, False), osd.glyph(50, True)}))')"
[[ "$out" == 5 ]] || fail "the glyph does not tell the levels and mute apart: $out"

# --- the capsule names the output it controls (short, no "· Analog" tail) -------------------------------------
mkdir -p "$sandbox/n"
cat >"$sandbox/n/pactl" <<'FAKE'
#!/usr/bin/env bash
case "$*" in
"get-default-sink") echo speakers ;;
"-f json list sinks") echo '[{"name":"speakers","description":"Starship/Matisse HD Audio Controller Analog","volume":{}}]' ;;
esac
FAKE
chmod +x "$sandbox/n/pactl"
out="$(run "$sandbox/n" 'print(osd.output_name())')"
[[ "$out" == 'Starship/Matisse' ]] || fail "output name not shortened: $out"
out="$(run "$sandbox/none" 'print(repr(osd.output_name()))')"
[[ "$out" == "''" ]] || fail "no sound server should give an empty name: $out"

printf 'osd: up/down by 5 on wpctl and pactl, capped at 100 and floored at 0, mute toggles, up unmutes, up from over 100 lands on 100, unknown action refused, no tools = no level, 5 distinct glyphs, output name shortened\n'
