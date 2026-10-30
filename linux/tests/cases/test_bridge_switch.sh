#!/usr/bin/env bash
# The fakes are shell source written out literally: their $ expands when they run.
# shellcheck disable=SC2016
set -Eeuo pipefail

# Switching between the two systems (docs/bridge.md, "Reboot into the other
# system"): a restart that the other side opens straight into the desktop,
# once, without asking for a password, and only when it came from a switch.
#
#   Windows -> Linux: Windows leaves a token on the EFI partition; at boot
#   vivac-switch-arrive takes it (always removing it) and, when it is fresh,
#   arms one automatic sign-in on tty1; vivac-getty spends it on the first
#   getty and never again; the login profile starts the desktop once.
#   Linux -> Windows: Restart in Windows leaves the token in vivac's state
#   folder of each Windows profile, before BootNext is set.

repo_root="${REPO_ROOT:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)}"
arrive="$repo_root/system/usr/local/lib/vivac/vivac-switch-arrive"
getty="$repo_root/system/usr/local/lib/vivac/vivac-getty"
login="$repo_root/dotfiles/bridge/.local/share/vivac/switch-login.sh"
tool="$repo_root/dotfiles/bridge/.local/bin/vivac-reboot-other"
unit="$repo_root/system/etc/systemd/system/vivac-switch-arrive.service"
dropin="$repo_root/system/etc/systemd/system/getty@tty1.service.d/vivac-switch.conf"

fail() {
	printf '%s\n' "$1" >&2
	exit 1
}
sandbox="$(mktemp -d "${TMPDIR:-/tmp}/vivac-switch.XXXXXX")"
trap 'rm -rf -- "$sandbox"' EXIT
mkdir -p "$sandbox/bin" "$sandbox/esp/EFI" "$sandbox/run" "$sandbox/etc"
calls="$sandbox/calls"
now=1800000000
arrival="$sandbox/esp/EFI/vivac/switch-to-linux"
flag="$sandbox/run/autologin-once"
me="$(id -un)"
printf 'user=%s\n' "$me" >"$sandbox/etc/switch.conf"

run_arrive() {
	VIVAC_ESP="$sandbox/esp" VIVAC_SWITCH_RUN="$sandbox/run" VIVAC_NOW="$1" "$arrive"
}
leave_token() {
	mkdir -p "${arrival%/*}"
	printf '%s\n' "$1" >"$arrival"
}

# --- Windows -> Linux: the token on the EFI partition ------------------------------------------------------
run_arrive "$now" || fail 'arrive failed with no token'
[[ ! -e "$flag" ]] || fail 'an automatic sign-in was armed with no token'

leave_token "vivac-switch 1 $((now - 60))"
run_arrive "$now" || fail 'arrive failed with a fresh token'
[[ -e "$flag" ]] || fail 'a fresh token armed no automatic sign-in'
[[ ! -e "$arrival" ]] || fail 'the token was left on the EFI partition'
[[ "$(stat -c %a "$flag")" == 600 ]] || fail "the armed flag is readable by others: $(stat -c %a "$flag")"
rm -f -- "$flag"

for stale in "vivac-switch 1 $((now - 3600))" "vivac-switch 1 $((now + 3600))" 'vivac-switch 1 soon' \
	"vivac-switch 2 $now" "user=root vivac-switch 1 $now" ''; do
	leave_token "$stale"
	run_arrive "$now" || fail "arrive failed on the token '$stale'"
	[[ ! -e "$flag" ]] || fail "the token '$stale' armed an automatic sign-in"
	[[ ! -e "$arrival" ]] || fail "the token '$stale' was not removed"
done

# --- the getty: one automatic sign-in, then the password as always -----------------------------------------
cat >"$sandbox/bin/agetty" <<'FAKE'
#!/usr/bin/env bash
printf 'agetty %s\n' "$*" >>"$CALLS"
FAKE
chmod +x "$sandbox/bin/agetty"
run_getty() {
	: >"$calls"
	PATH="$sandbox/bin:$PATH" CALLS="$calls" AGETTY="$sandbox/bin/agetty" VIVAC_SWITCH_RUN="$sandbox/run" \
		VIVAC_SWITCH_CONF="$sandbox/etc/switch.conf" VIVAC_SWITCH_HANDOVER="$sandbox/handover" "$getty" linux
}
plain='agetty --noreset --noclear - linux'

run_getty || fail 'the getty failed with nothing armed'
[[ "$(cat "$calls")" == "$plain" ]] || fail "the plain getty changed: $(cat "$calls")"

: >"$flag"
run_getty || fail 'the armed getty failed'
[[ "$(cat "$calls")" == "agetty --autologin $me --noreset --noclear - linux" ]] ||
	fail "the armed getty did not sign $me in: $(cat "$calls")"
[[ ! -e "$flag" ]] || fail 'the automatic sign-in can be spent twice'
[[ -O "$sandbox/handover/desktop-once" ]] || fail 'the desktop was not handed over to the login profile'
run_getty
[[ "$(cat "$calls")" == "$plain" ]] || fail "the second getty signed in by itself: $(cat "$calls")"

# The user comes from root's file, never from the token, and is never root.
for conf in 'user=root' 'user=nobody-here-xyz' 'user=$(id)' ''; do
	printf '%s\n' "$conf" >"$sandbox/etc/switch.conf"
	: >"$flag"
	run_getty || fail "the getty failed with '$conf'"
	[[ "$(cat "$calls")" == "$plain" ]] || fail "'$conf' signed someone in: $(cat "$calls")"
	[[ ! -e "$flag" ]] || fail "'$conf' left the flag armed"
done
printf 'user=%s\n' "$me" >"$sandbox/etc/switch.conf"
rm -f -- "$sandbox/etc/switch.conf"
: >"$flag"
run_getty
[[ "$(cat "$calls")" == "$plain" ]] || fail "no switch.conf still signed in: $(cat "$calls")"

# --- the login profile: the desktop once, on tty1, outside a desktop -------------------------------------
desktop() {
	: >"$calls"
	PATH="$sandbox/bin:$PATH" CALLS="$calls" VIVAC_SWITCH_HANDOVER="$sandbox/handover" VIVAC_TTY="$1" \
		WAYLAND_DISPLAY="${2:-}" bash -c ". '$login'; printf 'profile went on\n' >>\"\$CALLS\""
}
printf '#!/usr/bin/env bash\nprintf "start-hyprland\\n" >>"$CALLS"\n' >"$sandbox/bin/start-hyprland"
chmod +x "$sandbox/bin/start-hyprland"
mkdir -p "$sandbox/handover" && : >"$sandbox/handover/desktop-once"
desktop /dev/tty2
[[ "$(cat "$calls")" == 'profile went on' ]] || fail "the desktop started on tty2: $(cat "$calls")"
desktop /dev/tty1 wayland-1
[[ "$(cat "$calls")" == 'profile went on' ]] || fail "the desktop started inside a desktop: $(cat "$calls")"
desktop /dev/tty1
[[ "$(cat "$calls")" == 'start-hyprland' ]] || fail "the handed-over sign-in did not start the desktop: $(cat "$calls")"
[[ ! -e "$sandbox/handover/desktop-once" ]] || fail 'the desktop hand-over can be spent twice'
desktop /dev/tty1
[[ "$(cat "$calls")" == 'profile went on' ]] || fail "a normal sign-in started the desktop: $(cat "$calls")"

# --- Linux -> Windows: Restart in Windows leaves the token first ------------------------------------------
cat >"$sandbox/bin/efibootmgr" <<'FAKE'
#!/usr/bin/env bash
if (($#)); then printf 'efibootmgr %s\n' "$*" >>"$CALLS"; exit 0; fi
printf 'Boot0000* Windows Boot Manager\tHD(1,GPT,x)\n'
FAKE
cat >"$sandbox/bin/sudo" <<'FAKE'
#!/usr/bin/env bash
[[ "$1" == -n ]] && shift
for f in "$WINDOWS"/Users/*/AppData/Local/vivac/switch-arrival; do [[ -e "$f" ]] && printf 'token before bootnext\n' >>"$CALLS"; done
exec "$@"
FAKE
printf '#!/usr/bin/env bash\nprintf "systemctl %%s\\n" "$*" >>"$CALLS"\n' >"$sandbox/bin/systemctl"
printf '#!/usr/bin/env bash\nexit 0\n' >"$sandbox/bin/notify-send"
printf '#!/usr/bin/env bash\nexit 1\n' >"$sandbox/bin/rofi"
chmod +x "$sandbox/bin/"*
win="$sandbox/win"
mkdir -p "$win/Windows/System32" "$win/Users/ada/AppData/Local/vivac" "$win/Users/Public/AppData/Local"
reboot_other() {
	: >"$calls"
	env -u WAYLAND_DISPLAY -u DISPLAY PATH="$sandbox/bin:$PATH" CALLS="$calls" WINDOWS="$win" VIVAC_WINDOWS="$win" VIVAC_NOW="$now" \
		VIVAC_REPO="$repo_root" VIVAC_LANG=en HOME="$sandbox" "$tool" "$@" </dev/null
}
reboot_other --dry-run >/dev/null
[[ ! -e "$win/Users/ada/AppData/Local/vivac/switch-arrival" ]] || fail 'the dry run left a token for Windows'
reboot_other --yes || fail 'Restart in Windows failed'
[[ "$(cat "$win/Users/ada/AppData/Local/vivac/switch-arrival")" == "vivac-switch 1 $now" ]] ||
	fail "the token for Windows is wrong: $(cat "$win/Users/ada/AppData/Local/vivac/switch-arrival" 2>&1)"
[[ ! -e "$win/Users/Public/AppData/Local/vivac" ]] || fail 'a token went to a profile without vivac'
[[ "$(cat "$calls")" == $'token before bootnext\nefibootmgr --bootnext 0000\nsystemctl reboot' ]] ||
	fail "the token was not left before BootNext: $(cat "$calls")"
# No Windows partition mounted: the restart still happens, the greeter just shows.
rm -rf -- "$win/Windows"
reboot_other --yes 2>/dev/null || fail 'Restart in Windows failed without a mounted Windows'
grep -q 'systemctl reboot' "$calls" || fail 'no Windows mount stopped the restart'

# --- the units and the host deploy -----------------------------------------------------------------------
grep -qx 'Before=getty@tty1.service' "$unit" || fail 'the arrival runs after the getty it arms'
grep -qx 'RequiresMountsFor=/boot/efi' "$unit" || fail 'the arrival may run before the EFI partition is mounted'
grep -qx 'ExecStart=' "$dropin" || fail "the getty drop-in does not clear the stock ExecStart"
grep -qx 'ExecStart=-/usr/local/lib/vivac/vivac-getty ${TERM}' "$dropin" || fail 'the getty drop-in does not run vivac-getty'
plan="$(PATH="$sandbox/bin:$PATH" HOME="$sandbox" USER="$me" "$repo_root/scripts/apply-system.sh" --dry-run --switch)" ||
	fail 'apply-system.sh --dry-run --switch failed'
for expected in 'vivac-switch-arrive -> /usr/local/lib/vivac/vivac-switch-arrive' 'vivac-getty -> /usr/local/lib/vivac/vivac-getty' \
	'vivac-switch-arrive.service -> /etc/systemd/system/vivac-switch-arrive.service' \
	'vivac-switch.conf -> /etc/systemd/system/getty@tty1.service.d/vivac-switch.conf' "would write /etc/vivac/switch.conf: user=$me"; do
	grep -qF "$expected" <<<"$plan" || fail "the switch plan misses '$expected': $plan"
done
grep -Eq 'clamav|ufw|bluetooth' <<<"$plan" && fail "--switch alone pulled in other profiles: $plan"

printf 'switch: fresh token only, consumed always, one automatic sign-in for the configured user, desktop once, token for Windows before BootNext\n'
