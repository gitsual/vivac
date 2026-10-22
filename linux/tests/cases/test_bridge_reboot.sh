#!/usr/bin/env bash
# The fakes are shell source written out literally: their $ expands when they run.
# shellcheck disable=SC2016
set -Eeuo pipefail

# Restart in Windows sets BootNext to the Windows Boot Manager entry, found by
# its exact label in efibootmgr's listing, and changes nothing else: a dry run
# names the entry and stops, sudo is asked for exactly `efibootmgr --bootnext
# XXXX` and nothing more, and the sudoers rule that allows that much parses.

repo_root="${REPO_ROOT:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)}"
tool="$repo_root/dotfiles/bridge/.local/bin/vivac-reboot-other"
rule="$repo_root/system/etc/sudoers.d/vivac-bootnext"

fail() {
	printf '%s\n' "$1" >&2
	exit 1
}
sandbox="$(mktemp -d "${TMPDIR:-/tmp}/vivac-reboot.XXXXXX")"
trap 'rm -rf -- "$sandbox"' EXIT
mkdir -p "$sandbox/bin"
calls="$sandbox/calls"
# The fake firmware: efibootmgr prints LISTING; sudo and systemctl write down
# what they were asked and run nothing.
cat >"$sandbox/bin/efibootmgr" <<'FAKE'
#!/usr/bin/env bash
if (($#)); then printf 'efibootmgr %s\n' "$*" >>"$CALLS"; exit 0; fi
cat "$LISTING"
FAKE
cat >"$sandbox/bin/sudo" <<'FAKE'
#!/usr/bin/env bash
printf 'sudo %s\n' "$*" >>"$CALLS"
[[ "$1" == -n ]] && shift
exec "$@"
FAKE
printf '#!/usr/bin/env bash\nprintf "systemctl %%s\\n" "$*" >>"$CALLS"\n' >"$sandbox/bin/systemctl"
printf '#!/usr/bin/env bash\nexit 0\n' >"$sandbox/bin/notify-send"
chmod +x "$sandbox/bin/"*

run() {
	: >"$calls"
	PATH="$sandbox/bin:$PATH" CALLS="$calls" LISTING="$sandbox/listing" VIVAC_REPO="$repo_root" VIVAC_LANG=en \
		HOME="$sandbox" "$tool" "$@" </dev/null
}

# efibootmgr 18 puts the device path after a tab; Windows is not first, and an
# entry whose label only contains the words is not it.
printf '%b' 'BootCurrent: 0002\nTimeout: 1 seconds\nBootOrder: 0002,0000,001A\n' \
	'Boot0000* Old Windows Boot Manager copy\tHD(1,GPT,x)/File(\\EFI\\old.efi)\n' \
	'Boot0002* GRUB\tHD(1,GPT,x)/File(\\EFI\\GRUB\\grubx64.efi)\n' \
	'Boot001A* Windows Boot Manager\tHD(1,GPT,x)/File(\\EFI\\Microsoft\\Boot\\bootmgfw.efi)RC\n' >"$sandbox/listing"
out="$(run --dry-run)" || fail 'the dry run failed with a Windows entry listed'
[[ "$out" == *'Windows Boot Manager'*'Boot001A'* ]] || fail "the dry run did not name Boot001A: $out"
[[ ! -s "$calls" ]] || fail "the dry run changed something: $(cat "$calls")"
run --available || fail '--available said no with a Windows entry listed'

# The real thing, confirmations taken as given: exactly one sudo, one reboot.
run --yes || fail 'the restart failed'
[[ "$(cat "$calls")" == $'sudo -n efibootmgr --bootnext 001A\nefibootmgr --bootnext 001A\nsystemctl reboot' ]] ||
	fail "the restart did not set BootNext and reboot, in that order: $(cat "$calls")"

# Without --yes and with no terminal or menu to ask in, nothing happens.
if run; then fail 'restarted without being asked'; fi
grep -q bootnext "$calls" && fail 'BootNext was set without confirmation'

# An inactive entry is used only when there is no active one; older efibootmgr
# prints no device path.
printf '%b' 'BootOrder: 0003\nBoot0003* Arch Linux\nBoot0004  Windows Boot Manager\n' >"$sandbox/listing"
[[ "$(run --dry-run)" == *Boot0004* ]] || fail 'an inactive Windows entry was not found'
printf '%b' 'Boot0004  Windows Boot Manager\nBoot0005* Windows Boot Manager \n' >"$sandbox/listing"
[[ "$(run --dry-run)" == *Boot0005* ]] || fail 'an inactive entry won over an active one'

# No Windows entry, or no efibootmgr that works: no menu entry, no change.
printf '%b' 'BootOrder: 0003\nBoot0003* GRUB\tHD()\n' >"$sandbox/listing"
if run --available; then fail '--available said yes with no Windows entry'; fi
if run --yes 2>/dev/null; then fail 'a restart without a Windows entry succeeded'; fi
grep -q bootnext "$calls" && fail 'BootNext was set without a Windows entry'

# A sudo that refuses (no rule installed): no reboot either.
printf '%b' 'Boot0001* Windows Boot Manager\tHD()\n' >"$sandbox/listing"
printf '#!/usr/bin/env bash\nprintf "sudo %%s\\n" "$*" >>"$CALLS"\nexit 1\n' >"$sandbox/bin/sudo"
if run --yes 2>/dev/null; then fail 'the restart went on after sudo refused'; fi
grep -q reboot "$calls" && fail 'rebooted although BootNext could not be set'

# --- the sudoers rule -----------------------------------------------------------------------------------------
grep -Fxq '%wheel ALL=(root) NOPASSWD: /usr/bin/efibootmgr ^--bootnext [0-9A-Fa-f]{4}$' "$rule" ||
	fail 'the sudoers rule is not exactly efibootmgr --bootnext and four hex digits for wheel'
[[ "$(grep -cv '^#' "$rule")" == 1 ]] || fail 'the sudoers drop-in allows more than one thing'
if command -v visudo >/dev/null; then
	visudo -cf "$rule" >/dev/null || fail 'visudo refuses the sudoers drop-in'
	checked='visudo -cf passes'
else
	checked='visudo not installed, syntax not checked'
fi

# --- the host deploy installs it and opens the link port to the local subnets only ----------------------------
cat >"$sandbox/bin/ip" <<'FAKE'
#!/usr/bin/env bash
printf '2: eth0    inet 198.51.100.20/24 brd 198.51.100.255 scope global dynamic eth0\n'
printf '3: wlan0    inet 203.0.113.9/20 brd 203.0.127.255 scope global wlan0\n'
FAKE
chmod +x "$sandbox/bin/ip"
plan="$(PATH="$sandbox/bin:$PATH" HOME="$sandbox" "$repo_root/scripts/apply-system.sh" --dry-run --bridge)" ||
	fail 'apply-system.sh --dry-run --bridge failed'
grep -q 'vivac-bootnext -> /etc/sudoers.d/vivac-bootnext (mode 0440' <<<"$plan" || fail "the sudoers rule is not installed: $plan"
for expected in 'tcp 47321 from 198.51.100.0/24' 'udp 47321 from 198.51.100.0/24' 'tcp 47321 from 203.0.112.0/20' 'udp 47321 from 203.0.112.0/20'; do
	grep -q "would allow $expected in UFW" <<<"$plan" || fail "the plan does not open $expected: $plan"
done
grep -q 'would enable the user vivac-link service' <<<"$plan" || fail 'the link service is not enabled'
grep -Eq 'clamav|bluetooth' <<<"$plan" && fail "--bridge alone pulled in other profiles: $plan"

printf 'reboot into Windows: exact label, active first, dry run inert, one sudo call, rule parsed (%s), port to two subnets\n' "$checked"
