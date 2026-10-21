#!/usr/bin/env bash
# The fakes are shell source written out literally: their $ expands when they run.
# shellcheck disable=SC2016
set -Eeuo pipefail

# The phone through KDE Connect (vivac-phone). Against a fake kdeconnect-cli,
# busctl and rofi: the bar gets valid JSON with the battery, and nothing at
# all without KDE Connect, its daemon or a reachable phone; the menu offers
# what a paired phone can do and runs it on that phone only; the Run command
# presets are written in KDE Connect's own format, merged with the user's own
# commands, idempotent, with a dry run that writes nothing; and `run` refuses
# anything but its fixed actions.

repo_root="${REPO_ROOT:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)}"
tool="$repo_root/dotfiles/bridge/.local/bin/vivac-phone"
bridge="$repo_root/dotfiles/bridge/.local/bin/vivac-bridge"

fail() {
	printf '%s\n' "$1" >&2
	exit 1
}
sandbox="$(mktemp -d "${TMPDIR:-/tmp}/vivac-phone.XXXXXX")"
trap 'rm -rf -- "$sandbox"' EXIT
mkdir -p "$sandbox/bin" "$sandbox/me" "$sandbox/cfg/kdeconnect" "$sandbox/state"
calls="$sandbox/calls"

# kdeconnect-cli: the reachable devices are the lines of $DEVICES ("id name");
# everything else it is asked is written down, and fails when FAIL is set.
cat >"$sandbox/bin/kdeconnect-cli" <<'FAKE'
#!/usr/bin/env bash
if [[ "$*" == '--list-available --id-name-only' ]]; then
	[[ -s "$DEVICES" ]] && cat "$DEVICES"
	exit 0
fi
printf 'cli %s\n' "$*" >>"$CALLS"
[[ -z "${FAIL:-}" ]] || exit 1
[[ "$*" == *--get-mount-point ]] && printf '%s\n' "$MOUNT"
exit 0
FAKE
# busctl: the battery from CHARGE and CHARGING, as busctl prints it; an emit
# is written down.
cat >"$sandbox/bin/busctl" <<'FAKE'
#!/usr/bin/env bash
case "$*" in
*' charge') [[ -n "${CHARGE:-}" ]] && printf 'i %s\n' "$CHARGE" ;;
*' isCharging') printf 'b %s\n' "${CHARGING:-false}" ;;
*emit*) printf 'busctl %s\n' "$*" >>"$CALLS" ;;
esac
exit 0
FAKE
# pgrep answers for the daemon: running unless DAEMON=no.
printf '#!/usr/bin/env bash\n[[ "${DAEMON:-yes}" == yes ]]\n' >"$sandbox/bin/pgrep"
# rofi answers PICKS, one line per question asked, and writes down the rows it
# was shown.
cat >"$sandbox/bin/rofi" <<'FAKE'
#!/usr/bin/env bash
printf 'rofi %s\n' "$*" >>"$CALLS"
while IFS= read -r row; do printf 'row %s\n' "$row" >>"$CALLS"; done
n="$(grep -c '^rofi ' "$CALLS")"
answer="$(sed -n "${n}p" "$PICKS")"
[[ -n "$answer" ]] || exit 1
printf '%s\n' "$answer"
FAKE
printf '#!/usr/bin/env bash\nprintf "notify %%s\\n" "$*" >>"$CALLS"\n' >"$sandbox/bin/notify-send"
printf '#!/usr/bin/env bash\nprintf "open %%s\\n" "$*" >>"$CALLS"\n' >"$sandbox/bin/xdg-open"
printf '#!/usr/bin/env bash\nprintf "%%s" "$CLIP"\n' >"$sandbox/bin/wl-paste"
printf '#!/usr/bin/env bash\nprintf "app\\n" >>"$CALLS"\n' >"$sandbox/bin/kdeconnect-app"
printf '#!/usr/bin/env bash\nexit 0\n' >"$sandbox/bin/sshfs"
# The firmware has a Windows entry, for the reboot preset.
printf '#!/usr/bin/env bash\nprintf "Boot0001* Windows Boot Manager\\tHD(1)\\n"\n' >"$sandbox/bin/efibootmgr"
chmod +x "$sandbox/bin/"*

devices="$sandbox/devices"
picks="$sandbox/picks"
: >"$devices"
phone() {
	PATH="$sandbox/bin:$PATH" CALLS="$calls" DEVICES="$devices" PICKS="$picks" VIVAC_REPO="$repo_root" \
		VIVAC_LANG="${PHONE_LANG:-en}" HOME="$sandbox/me" XDG_CONFIG_HOME="$sandbox/cfg" XDG_STATE_HOME="$sandbox/state" \
		VIVAC_KDECONNECT_CLI="${CLI:-$sandbox/bin/kdeconnect-cli}" VIVAC_KDECONNECT_APP="$sandbox/bin/kdeconnect-app" \
		"$tool" "$@"
}
json_ok() { python3 -c 'import json, sys; json.loads(sys.argv[1])' "$1" 2>/dev/null; }
field() { python3 -c 'import json, sys; print(json.loads(sys.argv[1])[sys.argv[2]])' "$1" "$2"; }
absent='{"text":"","class":"absent"}'
# A name a bar or a shell could stumble on: quotes, markup, an ampersand.
name='Phone "A" <b>&'
printf 'a1b2c3d4e5f60718_29 %s\n' "$name" >"$devices"

# --- the bar ---------------------------------------------------------------------------------------------------------
out="$(CLI=vivac-no-such-cli phone waybar)"
[[ "$out" == "$absent" ]] || fail "without KDE Connect the bar module is not empty: $out"
out="$(DAEMON=no phone waybar)"
[[ "$out" == "$absent" ]] || fail "without the daemon the bar module is not empty: $out"
out="$(CHARGE=87 phone waybar)"
json_ok "$out" || fail "the bar output is not JSON: $out"
[[ "$(field "$out" text)" == *' 87%' ]] || fail "the battery is not on the bar: $out"
[[ "$(field "$out" class)" == normal ]] || fail "87% is not the normal class: $out"
[[ "$(field "$out" tooltip)" == 'Phone "A" &lt;b&gt;&amp;: 87%' ]] || fail "the tooltip is not the escaped name and battery: $out"
out="$(CHARGE=12 phone waybar)"
[[ "$(field "$out" class)" == low ]] || fail "12% is not low: $out"
out="$(CHARGE=12 CHARGING=true phone waybar)"
[[ "$(field "$out" class)" == charging ]] || fail "charging is not its own class: $out"
[[ "$(field "$out" tooltip)" == *'12%, charging' ]] || fail "the tooltip does not say charging: $out"
out="$(phone waybar)"
json_ok "$out" || fail "a phone with no battery reading did not give JSON: $out"
[[ "$(field "$out" tooltip)" == *': reachable' && "$(field "$out" text)" != *%* ]] || fail "an unknown battery was shown as a number: $out"
out="$(CHARGE=250 phone waybar)"
[[ "$(field "$out" text)" != *250* ]] || fail "an impossible charge reached the bar: $out"
: >"$devices"
out="$(CHARGE=50 phone waybar)"
[[ "$out" == "$absent" ]] || fail "with no reachable phone the bar module is not empty: $out"
# A device id that could name another folder or D-Bus path is ignored.
printf '../../etc x\n' >"$devices"
[[ "$(CHARGE=50 phone waybar)" == "$absent" ]] || fail 'a device id with a path in it was used'

# --- the bridge menu row ----------------------------------------------------------------------------------------------
bridge_rows() {
	PATH="$sandbox/bin:$PATH" CALLS="$calls" VIVAC_REPO="$repo_root" VIVAC_LANG=en HOME="$sandbox/me" \
		VIVAC_KDECONNECT_CLI="${CLI:-$sandbox/bin/kdeconnect-cli}" "$bridge" --print
}
grep -Fxq 'Phone…' <<<"$(bridge_rows)" || fail 'the bridge menu has no Phone row with KDE Connect installed'
grep -Fq 'Phone' <<<"$(CLI=vivac-no-such-cli bridge_rows)" && fail 'the bridge menu offers the phone without KDE Connect'
[[ -z "$(CLI=vivac-no-such-cli phone --print)" ]] || fail 'the phone menu has rows without KDE Connect'
if CLI=vivac-no-such-cli phone --available; then fail '--available says yes without KDE Connect'; fi

# --- the phone menu ---------------------------------------------------------------------------------------------------
printf 'a1b2c3d4e5f60718_29 Test phone\n' >"$devices"
rows="$(phone --print)"
for row in 'Ring the phone' 'Send a file to the phone' 'Send the clipboard to the phone' \
	'Open the link on the clipboard on the phone' "Browse the phone's files" 'Pair or unpair a phone (KDE Connect)'; do
	grep -Fxq "$row" <<<"$rows" || fail "the menu has no row: $row"
done
: >"$devices"
[[ "$(phone --print)" == 'Pair or unpair a phone (KDE Connect)' ]] || fail "with no phone the menu offers more than pairing: $(phone --print)"

# menu ROW... — open the menu with rofi answering ROW, then each later answer.
menu() {
	printf '%s\n' "$@" >"$picks"
	: >"$calls"
	phone menu 2>/dev/null
}
printf 'a1b2c3d4e5f60718_29 Test phone\n' >"$devices"
menu 0
grep -Fxq 'cli -d a1b2c3d4e5f60718_29 --ring' "$calls" || fail "Ring did not ring that phone: $(cat "$calls")"
grep -q '^notify .*Test phone is ringing' "$calls" || fail 'ringing was not said'
FAIL=1 menu 0
grep -q '^notify .*could not reach Test phone' "$calls" || fail 'a failed ring was not said'

mkdir -p "$sandbox/me/Documents"
printf 'x\n' >"$sandbox/me/Documents/notes 1.txt"
menu 1 'Documents/notes 1.txt'
grep -Fxq "cli -d a1b2c3d4e5f60718_29 --share $sandbox/me/Documents/notes 1.txt" "$calls" || fail "the file was not shared: $(cat "$calls")"
menu 1 'Documents/missing.txt'
grep -q -- '--share' "$calls" && fail 'a file that is not there was shared'
menu 1
grep -q -- '--share' "$calls" && fail 'an abandoned file choice still shared something'

menu 2
grep -Fxq 'cli -d a1b2c3d4e5f60718_29 --send-clipboard' "$calls" || fail 'the clipboard was not sent'

CLIP='https://example.org/a?b=c' menu 3
grep -Fxq 'cli -d a1b2c3d4e5f60718_29 --share https://example.org/a?b=c' "$calls" || fail "the link was not shared: $(cat "$calls")"
for clip in 'file:///etc/passwd' 'javascript:alert(1)' $'https://a.example\nhttps://b.example' 'just text'; do
	CLIP="$clip" menu 3
	grep -q -- '--share' "$calls" && fail "something that is not one http(s) link was sent: $clip"
	grep -q '^notify .*no http or https link' "$calls" || fail "a clipboard without a link was not said: $clip"
done

mkdir -p "$sandbox/mnt"
MOUNT="$sandbox/mnt" menu 4
grep -Fxq 'cli -d a1b2c3d4e5f60718_29 --mount' "$calls" || fail 'the files were not mounted'
for _ in 1 2 3 4 5 6 7 8 9 10; do
	grep -Fxq "open $sandbox/mnt" "$calls" && break
	sleep 0.2
done
grep -Fxq "open $sandbox/mnt" "$calls" || fail "the mount point was not opened: $(cat "$calls")"

menu 5
for _ in 1 2 3 4 5 6 7 8 9 10; do
	grep -Fxq app "$calls" && break
	sleep 0.2
done
grep -Fxq app "$calls" || fail 'Pair or unpair did not open KDE Connect'
menu 9
grep -q '^cli ' "$calls" && fail 'a row past the end ran something'

# Two phones: the one chosen first is the one acted on.
printf 'aaaa1111 First\nbbbb2222 Second\n' >"$devices"
menu 1 0
grep -Fxq 'row Second' "$calls" || fail 'two phones were not offered to choose from'
grep -Fxq 'cli -d bbbb2222 --ring' "$calls" || fail "the chosen phone was not the one rung: $(cat "$calls")"
menu ''
grep -q '^cli ' "$calls" && fail 'leaving the phone choice still did something'

# --- Run command presets ------------------------------------------------------------------------------------------------
config="$sandbox/cfg/kdeconnect/a1b2c3d4e5f60718_29/kdeconnect_runcommand/config"
: >"$calls"
if phone commands >/dev/null 2>&1; then fail 'commands succeeded with no paired device'; fi
printf '[a1b2c3d4e5f60718_29]\nname=Test phone\ntype=phone\n\n[../evil]\nname=x\n' >"$sandbox/cfg/kdeconnect/trusted_devices"
mkdir -p "$(dirname -- "$config")" "$sandbox/state/vivac"
: >"$sandbox/state/vivac/link.conf"
# The user's own command and a stale vivac one, as KDE Connect's settings
# page writes them: the first stays, the second goes.
cat >"$config" <<'CONF'
[General]
commands="@ByteArray({\"0f1e2d\":{\"command\":\"echo \\\"hi\\\" > /tmp/x\",\"name\":\"Mine\"},\"vivac-old\":{\"command\":\"true\",\"name\":\"Old\"}})"
CONF
before="$(cat "$config")"
out="$(phone commands --dry-run)" || fail "the dry run failed: $out"
[[ "$(cat "$config")" == "$before" ]] || fail 'the dry run changed the config'
grep -q '^Would write .*kdeconnect_runcommand/config' <<<"$out" || fail "the dry run does not say what it would write: $out"
grep -q 'busctl' "$calls" && fail 'the dry run signalled the daemon'
[[ ! -e "$sandbox/cfg/kdeconnect/evil" && ! -e "$sandbox/cfg/evil" ]] || fail 'a device id with a path in it was written to'

out="$(phone commands)" || fail "commands failed: $out"
expected="$sandbox/expected"
cat >"$expected" <<'CONF'
[General]
commands="@ByteArray({\"0f1e2d\":{\"command\":\"echo \\\"hi\\\" > /tmp/x\",\"name\":\"Mine\"},\"vivac-clip-other\":{\"command\":\"\\\"$HOME/.local/bin/vivac-phone\\\" run clip-other\",\"name\":\"Send the clipboard to the other machine\"},\"vivac-lock\":{\"command\":\"\\\"$HOME/.local/bin/vivac-phone\\\" run lock\",\"name\":\"Lock the screen\"},\"vivac-reboot-windows\":{\"command\":\"\\\"$HOME/.local/bin/vivac-phone\\\" run reboot-windows\",\"name\":\"Restart in Windows\"},\"vivac-suspend\":{\"command\":\"\\\"$HOME/.local/bin/vivac-phone\\\" run suspend\",\"name\":\"Suspend\"}})"
CONF
diff -u "$expected" "$config" >&2 || fail 'the runcommand config is not the expected one'
grep -Fxq 'busctl --user emit /kdeconnect/a1b2c3d4e5f60718_29/kdeconnect_runcommand org.kde.kdeconnect.config configChanged' "$calls" ||
	fail "the daemon was not told the config changed: $(cat "$calls")"
grep -q 'vivac-clip-other vivac-lock vivac-reboot-windows vivac-suspend' <<<"$out" || fail "what was written is not said: $out"

# Read back as QSettings and QJsonDocument would: every command is one of
# the fixed actions, or the user's own, untouched.
python3 - "$config" <<'PY' || fail 'the config does not read back as the fixed list'
import json, re, sys
line = [l for l in open(sys.argv[1]) if l.startswith("commands=")][0].strip()[len("commands="):]
value = re.sub(r'\\(.)', r'\1', line[1:-1])
blob = json.loads(value[len("@ByteArray("):-1])
assert blob["0f1e2d"] == {"command": 'echo "hi" > /tmp/x', "name": "Mine"}, blob["0f1e2d"]
ours = {k: v for k, v in blob.items() if k.startswith("vivac-")}
assert set(ours) == {"vivac-lock", "vivac-suspend", "vivac-clip-other", "vivac-reboot-windows"}, ours
for v in ours.values():
    assert re.fullmatch(r'"\$HOME/\.local/bin/vivac-phone" run (lock|suspend|clip-other|reboot-windows)', v["command"]), v
PY

# Idempotent: a second run changes nothing and says so.
sum="$(sha256sum "$config")"
: >"$calls"
out="$(phone commands)" || fail "a second run failed: $out"
[[ "$(sha256sum "$config")" == "$sum" ]] || fail 'a second run changed the file'
grep -q 'already up to date' <<<"$out" || fail "a second run did not say it was up to date: $out"

# Spanish names, \u-escaped so the INI line stays ASCII; a fresh device gets a
# fresh file; without vivac link and a Windows entry those presets are left out.
rm -f "$sandbox/state/vivac/link.conf"
printf '#!/usr/bin/env bash\nexit 0\n' >"$sandbox/bin/efibootmgr"
printf '[ffff0000]\nname=Other\n' >>"$sandbox/cfg/kdeconnect/trusted_devices"
PHONE_LANG=es phone commands --device ffff0000 >/dev/null || fail 'commands for one device failed'
fresh="$sandbox/cfg/kdeconnect/ffff0000/kdeconnect_runcommand/config"
[[ "$(head -n 1 "$fresh")" == '[General]' ]] || fail 'a fresh config has no [General] group'
LC_ALL=C grep -q '[^[:print:]]' "$fresh" && fail 'the config is not plain ASCII'
grep -Fq 'Bloquear la pantalla' "$fresh" || fail 'the names are not in the session language'
grep -q 'clip-other\|reboot-windows' "$fresh" && fail 'presets for what is not set up were written'
[[ "$(sha256sum "$config")" == "$sum" ]] || fail '--device touched another device'

# A config it cannot read is left alone.
printf '[General]\ncommands="@ByteArray({not json)"\n' >"$config"
if phone commands --device a1b2c3d4e5f60718_29 >/dev/null 2>&1; then fail 'an unreadable config was overwritten'; fi
grep -q 'not json' "$config" || fail 'an unreadable config was changed'

# --- run: the fixed actions and nothing else --------------------------------------------------------------------------
for action in '' 'rm -rf ~' 'lock; true' '../vivac-link' 'sh'; do
	if phone run "$action" >/dev/null 2>&1; then fail "run accepted: $action"; fi
done
grep -q '^\(cli\|open\)' "$calls" && fail 'a refused action ran something'

printf 'phone: bar JSON and silence, menu actions on the chosen phone, runcommand presets merged and idempotent, run refuses the rest\n'
