#!/usr/bin/env bash
# shellcheck disable=SC2016
set -Eeuo pipefail

# vivac-panel security, without a screen: the shield's class and tooltip read
# the firewall (ufw, firewalld or nftables, only whether it is installed and
# running), the weekly ClamAV scan (when it last ran, whether it found
# something or failed, whether the timer is on and when it fires next) and the
# audit script; it never needs root, answers fast and survives missing tools.
# The scan and the audit start where they should: the user service, and kitty.
# systemctl, pacman, kitty and the audit script are fakes.

repo_root="${REPO_ROOT:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)}"
fail() {
	printf '%s\n' "$1" >&2
	exit 1
}
sandbox="$(mktemp -d "${TMPDIR:-/tmp}/vivac-security.XXXXXX")"
trap 'rm -rf -- "$sandbox"' EXIT
mkdir -p "$sandbox/bin"
export SANDBOX="$sandbox"
export PATH="$sandbox/bin:$PATH"
export VIVAC_LANG=en

cat >"$sandbox/bin/systemctl" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$SANDBOX/systemctl.log"
args=" $* "
case "$args" in
*" show clamav-home-scan.service "*) cat "$SANDBOX/svc" ;;
*" show clamav-home-scan.timer "*) cat "$SANDBOX/timer" ;;
*" is-active "*)
	rc=0
	for u in "${@:2}"; do
		[[ "$u" == is-active ]] && continue
		state="$(awk -v u="$u" '$1 == u {print $2}' "$SANDBOX/active")"
		printf '%s\n' "${state:-inactive}"
		[[ "$state" == active ]] || rc=3
	done
	exit "$rc"
	;;
esac
FAKE
cat >"$sandbox/bin/pacman" <<'FAKE'
#!/usr/bin/env bash
rc=0
for p in "${@:2}"; do
	if grep -qx "$p" "$SANDBOX/pkgs"; then echo "$p 1.0-1"; else echo "error: package '$p' was not found" >&2; rc=1; fi
done
exit "$rc"
FAKE
cat >"$sandbox/bin/kitty" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$*" >"$SANDBOX/kitty.log"
FAKE
printf '#!/bin/sh\nexit 0\n' >"$sandbox/bin/workstation-security-audit"
chmod +x "$sandbox/bin/"*

now="$(date +%s)"
scenario() { # firewall-state packages timer-active svc-result svc-status svc-ts-offset-or-none
	printf 'ufw.service %s\nclamav-freshclam.service active\nfirewalld.service inactive\nnftables.service inactive\n' "$1" >"$sandbox/active"
	printf '%s\n' $2 >"$sandbox/pkgs"
	cat >"$sandbox/timer" <<T
LoadState=loaded
ActiveState=$3
UnitFileState=enabled
NextElapseUSecRealtime=@$((now + 3 * 86400))
LastTriggerUSec=@$((now - 2 * 86400))
T
	{
		printf 'LoadState=loaded\nActiveState=inactive\nResult=%s\nExecMainStatus=%s\n' "$4" "$5"
		if [[ "$6" == none ]]; then printf 'ExecMainExitTimestamp=\n'; else printf 'ExecMainExitTimestamp=@%s\n' "$((now - $6))"; fi
	} >"$sandbox/svc"
}
py() { /usr/bin/python3 -I -c "import sys; sys.path.insert(0, '$repo_root/lib'); from vivacpanel import security; $1"; }
field() { /usr/bin/python3 -I -c 'import json,sys; print(json.loads(sys.argv[1])[sys.argv[2]])' "$1" "$2"; }
bar() { py 'security.waybar([])'; }
SHIELD=$'\U000F0565'
ALERT=$'\U000F0ECC'

# --- everything in order: ok, shield, the details in the tooltip --------------------------------------------
scenario active 'ufw clamav' active success 0 172800
out="$(bar)"
[[ "$(wc -l <<<"$out")" == 1 ]] || fail "waybar is not one line: $out"
[[ "$(field "$out" class)" == ok ]] || fail "all well, but: $out"
[[ "$(field "$out" text)" == "$SHIELD" ]] || fail "the ok shield: $out"
tip="$(field "$out" tooltip)"
grep -q 'ufw' <<<"$tip" || fail "the firewall is not in the tooltip: $tip"
grep -qi 'clamav\|antivirus' <<<"$tip" || fail "the antivirus is not in the tooltip: $tip"
grep -q '2 days ago' <<<"$tip" || fail "the last scan is not in the tooltip: $tip"

# --- a firewall installed but off is an alert; none installed is a warning ------------------------------------
scenario inactive 'ufw clamav' active success 0 172800
out="$(bar)"
[[ "$(field "$out" class)" == alert && "$(field "$out" text)" == "$ALERT" ]] || fail "ufw off: $out"
scenario active 'clamav' active success 0 172800
printf 'ufw.service inactive\nclamav-freshclam.service active\n' >"$sandbox/active"
[[ "$(field "$(bar)" class)" == warn ]] || fail "no firewall installed: $(bar)"
printf 'ufw.service inactive\nfirewalld.service active\nclamav-freshclam.service active\n' >"$sandbox/active"
printf 'firewalld\nclamav\n' >"$sandbox/pkgs"
[[ "$(field "$(bar)" class)" == ok ]] || fail "firewalld running is a firewall: $(bar)"

# --- the scan: found something (exit 1 counts as success to systemd), failed, never, stale, running, timer off ---
scenario active 'ufw clamav' active success 1 3600
out="$(bar)"
[[ "$(field "$out" class)" == alert ]] || fail "a scan that found something: $out"
grep -qi 'infected\|threat' <<<"$(field "$out" tooltip)" || fail "the finding is not said: $out"
scenario active 'ufw clamav' active exit-code 2 3600
[[ "$(field "$(bar)" class)" == warn ]] || fail "a scan that failed: $(bar)"
scenario active 'ufw clamav' active success 0 none
printf 'LoadState=loaded\nActiveState=active\nLastTriggerUSec=\nNextElapseUSecRealtime=@%s\n' "$((now + 86400))" >"$sandbox/timer"
out="$(bar)"
[[ "$(field "$out" class)" == warn ]] || fail "never scanned: $out"
grep -qi 'never' <<<"$(field "$out" tooltip)" || fail "never is not said: $out"
scenario active 'ufw clamav' active success 0 $((20 * 86400))
[[ "$(field "$(bar)" class)" == warn ]] || fail "a 20-day-old scan: $(bar)"
scenario active 'ufw clamav' inactive success 0 86400
out="$(bar)"
[[ "$(field "$out" class)" == warn ]] || fail "the timer is off: $out"
grep -qi 'off\|not scheduled' <<<"$(field "$out" tooltip)" || fail "the timer being off is not said: $out"
scenario active 'ufw clamav' active success 0 86400
sed -i 's/ActiveState=inactive/ActiveState=activating/' "$sandbox/svc"
out="$(bar)"
[[ "$(field "$out" class)" == ok ]] || fail "a scan running is not a problem: $out"
grep -qi 'scanning' <<<"$(field "$out" tooltip)" || fail "a running scan is not said: $out"
scenario active 'ufw' active success 0 86400
[[ "$(field "$(bar)" class)" == warn ]] || fail "no ClamAV installed: $(bar)"

# --- the panel's data: the rows and what they say -----------------------------------------------------------------
scenario active 'ufw clamav' active success 0 172800
out="$(py 's = security.status(); print(s.level, s.fw_name, s.fw_active, s.last_result, s.timer_active, bool(s.audit))')"
[[ "$out" == 'ok ufw True clean True True' ]] || fail "status(): $out"

# --- the actions ---------------------------------------------------------------------------------------------------
: >"$sandbox/systemctl.log"
py 'security.scan_now()'
grep -qx -- '--user start --no-block clamav-home-scan.service' "$sandbox/systemctl.log" || fail "scan_now: $(cat "$sandbox/systemctl.log")"
: >"$sandbox/systemctl.log"
py 'security.schedule_scan()'
grep -qx -- '--user enable --now clamav-home-scan.timer' "$sandbox/systemctl.log" || fail "schedule_scan: $(cat "$sandbox/systemctl.log")"
py 'security.run_audit()'
sleep 0.3
grep -q -- '--class vivac-audit' "$sandbox/kitty.log" && grep -q 'workstation-security-audit' "$sandbox/kitty.log" || fail "run_audit: $(cat "$sandbox/kitty.log")"

# --- fast, and without the tools nothing breaks -----------------------------------------------------------------------
start="$(date +%s%N)"
bar >/dev/null
elapsed=$((($(date +%s%N) - start) / 1000000))
((elapsed < 300)) || fail "waybar took ${elapsed} ms"
rm "$sandbox/bin/systemctl" "$sandbox/bin/pacman"
out="$(PATH="$sandbox/bin-none" bar)" || fail "waybar raised without systemctl: $out"
[[ "$(wc -l <<<"$out")" == 1 ]] || fail "without systemctl: $out"

printf 'security: shield ok/warn/alert from firewall + scan + timer, finding and failure told apart, actions, fast, no tools survived\n'
