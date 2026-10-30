#!/usr/bin/env bash
# The fakes are shell source written out literally: their $ expands when they run.
# shellcheck disable=SC2016
set -Eeuo pipefail

# The shared mouse: vivac-mouse writes lan-mouse's config.toml from mouse.conf,
# exactly and only from values it checked (a host name or IP, one of four
# sides, a SHA-256 fingerprint, a port); reads this machine's fingerprint out
# of lan-mouse.pem as lan-mouse computes it; starts and stops the user service
# through systemctl and nothing else; and a dry run writes nothing. lan-mouse
# and systemctl are fakes here: nothing listens and nothing is captured.

repo_root="${REPO_ROOT:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)}"
tool="$repo_root/dotfiles/bridge/.local/bin/vivac-mouse"

fail() {
	printf '%s\n' "$1" >&2
	exit 1
}
sandbox="$(mktemp -d "${TMPDIR:-/tmp}/vivac-mouse.XXXXXX")"
trap 'rm -rf -- "$sandbox"' EXIT
mkdir -p "$sandbox/bin" "$sandbox/user/.config/lan-mouse"
calls="$sandbox/calls"
: >"$calls"
printf '#!/usr/bin/env bash\nprintf "lan-mouse %%s\\n" "$*" >>"$CALLS"\n' >"$sandbox/bin/lan-mouse"
printf '#!/usr/bin/env bash\nprintf "systemctl %%s\\n" "$*" >>"$CALLS"\n' >"$sandbox/bin/systemctl"
chmod +x "$sandbox/bin/"*

# WL is the display the session would have; every other display variable is cleared.
mouse() {
	env -u WAYLAND_DISPLAY -u XDG_CURRENT_DESKTOP -u HYPRLAND_INSTANCE_SIGNATURE ${WL:+WAYLAND_DISPLAY="$WL"} PATH="$sandbox/bin:$PATH" CALLS="$calls" \
		HOME="$sandbox/user" XDG_CONFIG_HOME="$sandbox/user/.config" XDG_STATE_HOME="$sandbox/user/.local/state" \
		VIVAC_REPO="$repo_root" VIVAC_LANG=en python3 "$tool" "$@"
}
conf="$sandbox/user/.local/state/vivac/mouse.conf"
toml="$sandbox/user/.config/lan-mouse/config.toml"
pem="$sandbox/user/.config/lan-mouse/lan-mouse.pem"

# --- the fingerprint ----------------------------------------------------------------------------------------------
# The DER bytes are a sentence; their SHA-256 is fixed here, and the Windows half
# (Mouse.Tests.ps1) checks the same file against the same value.
hex=15f4f310adea63bc5bf152d7a5e95456dddd33a106cb4283336e6176f0c8f03e
colons() { sed 's/../&:/g; s/:$//' <<<"$1"; }
if mouse fingerprint 2>/dev/null; then fail 'a fingerprint was printed with no certificate'; fi
printf '%s\n' '-----BEGIN PRIVATE_KEY-----' 'bm90IGEga2V5' '-----END PRIVATE_KEY-----' \
	'-----BEGIN CERTIFICATE-----' 'dml2YWMgbW91c2U6IGEgdGVz' 'dCBjZXJ0aWZpY2F0ZSwgbm90IERFUg==' '-----END CERTIFICATE-----' >"$pem"
mine="$(mouse fingerprint)" || fail 'vivac-mouse fingerprint failed'
[[ "$mine" == "$(colons "$hex")" ]] || fail "the fingerprint is not SHA-256 of the certificate, in colon pairs: $mine"

# --- config: a dry run writes nothing ---------------------------------------------------------------------------
peer_hex=00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff
out="$(mouse config --peer other-pc --side right --fingerprint "${peer_hex^^}" --dry-run)" || fail 'config --dry-run failed'
[[ "$out" == *'[[clients]]'* ]] || fail "the dry run did not show the config: $out"
[[ ! -e "$conf" && ! -e "$toml" && ! -s "$calls" ]] || fail 'the dry run wrote or ran something'

# --- config: exactly this file, from checked values only ---------------------------------------------------------
printf '# what lan-mouse writes on its first start\nport = 4242\n' >"$toml"
mouse config --peer other-pc --side right --fingerprint "${peer_hex^^}" >/dev/null || fail 'config failed'
expected="# lan-mouse, as vivac-mouse writes it from ~/.local/state/vivac/mouse.conf.
# vivac-mouse config and vivac-mouse trust change it; edits here are replaced.

port = 4242

# the only certificate accepted for incoming input
[authorized_fingerprints]
\"$(colons "$peer_hex")\" = \"other-pc\"

# the other machine, and the edge of this screen it sits beyond
[[clients]]
position = \"right\"
hostname = \"other-pc\"
port = 4242
activate_on_startup = true"
[[ "$(cat "$toml")" == "$expected" ]] || fail "config.toml is not the expected one: $(cat "$toml")"
python3 -c 'import sys, tomllib; tomllib.load(open(sys.argv[1], "rb"))' "$toml" || fail 'config.toml is not valid TOML'
grep -q 'first start' "$toml.vivac-backup" || fail 'the config.toml vivac did not write was not kept'
[[ "$(stat -c %a "$conf")" == 600 ]] || fail "mouse.conf is not mode 600: $(stat -c %a "$conf")"
grep -qx 'enabled=no' "$conf" || fail 'config turned the mouse on'
[[ ! -s "$calls" ]] || fail "config of a disabled mouse ran something: $(cat "$calls")"

# An IP address goes in ips, a new port in both places; a second write keeps the backup as it was.
mouse config --peer 198.51.100.7 --side top --port 4300 >/dev/null || fail 'config with an IP failed'
grep -qx 'ips = \["198.51.100.7"\]' "$toml" || fail "the IP is not in ips: $(cat "$toml")"
[[ "$(grep -c '^port = 4300$' "$toml")" == 2 ]] || fail 'the port is not in both places'
grep -q "$(colons "$peer_hex")" "$toml" || fail 'a config without --fingerprint forgot the trusted one'
grep -q 'first start' "$toml.vivac-backup" || fail 'the backup was replaced'

# Nothing that could break out of a TOML string, or is not a side or a fingerprint, gets in.
before="$(cat "$toml")"
for bad in '--peer a"b --side left' '--peer other-pc --side middle' '--peer other-pc --side left --fingerprint aa:bb' \
	'--peer other-pc --side left --port 70000' '--peer x]y --side left'; do
	read -r -a words <<<"$bad"
	if mouse config "${words[@]}" 2>/dev/null; then fail "config accepted: $bad"; fi
done
[[ "$(cat "$toml")" == "$before" ]] || fail 'a refused config changed config.toml'

# --- trust ------------------------------------------------------------------------------------------------------------
trusted_hex=ffeeddccbbaa99887766554433221100ffeeddccbbaa99887766554433221100
mouse trust "$(colons "$trusted_hex")" >/dev/null || fail 'trust failed'
grep -q "^\"$(colons "$trusted_hex")\" = " "$toml" || fail "trust did not replace the fingerprint: $(cat "$toml")"
if mouse trust 'not-hex' 2>/dev/null; then fail 'trust accepted a non-fingerprint'; fi

# --- pair: what the other machine types -----------------------------------------------------------------------------
out="$(mouse pair)" || fail 'pair failed'
grep -q -- "--side bottom --fingerprint $(colons "$hex")" <<<"$out" || fail "pair did not give the opposite side and this fingerprint: $out"
grep -q -- "-Side bottom -Fingerprint $(colons "$hex")" <<<"$out" || fail "pair did not give the Windows command: $out"

# --- enable, disable, resume: systemctl and nothing else --------------------------------------------------------------
if LAN_MOUSE="$sandbox/none" mouse enable 2>/dev/null; then fail 'enabled without lan-mouse'; fi
grep -qx 'enabled=no' "$conf" || fail 'a failed enable turned the mouse on'
: >"$calls"
mouse enable --dry-run >/dev/null || fail 'enable --dry-run failed'
[[ ! -s "$calls" ]] || fail "enable --dry-run ran something: $(cat "$calls")"
grep -qx 'enabled=no' "$conf" || fail 'enable --dry-run turned the mouse on'
WL=wayland-1 mouse enable >/dev/null || fail 'enable failed'
[[ "$(cat "$calls")" == $'systemctl --user import-environment WAYLAND_DISPLAY\nsystemctl --user restart vivac-mouse.service' ]] ||
	fail "enable did not hand over the display and start the service: $(cat "$calls")"
grep -qx 'enabled=yes' "$conf" || fail 'enable did not record it'
: >"$calls"
mouse resume || fail 'resume failed'
grep -q 'restart vivac-mouse.service' "$calls" || fail 'resume did not start an enabled mouse'
: >"$calls"
mouse toggle >/dev/null || fail 'toggle failed'
[[ "$(cat "$calls")" == 'systemctl --user stop vivac-mouse.service' ]] || fail "toggle of an enabled mouse did not stop it: $(cat "$calls")"
grep -qx 'enabled=no' "$conf" || fail 'disable did not record it'
: >"$calls"
mouse resume || fail 'resume of a disabled mouse failed'
[[ ! -s "$calls" ]] || fail "resume started a disabled mouse: $(cat "$calls")"
grep -q 'lan-mouse' "$calls" && fail 'lan-mouse itself was run'

# --- the bridge menu and the firewall ---------------------------------------------------------------------------------
menu() { PATH="$sandbox/bin:$PATH" HOME="$sandbox/user" XDG_STATE_HOME="$sandbox/user/.local/state" VIVAC_LANG=en \
	VIVAC_REPO="$repo_root" "$repo_root/dotfiles/bridge/.local/bin/vivac-bridge" --print; }
grep -qx 'Shared mouse: off' <<<"$(menu)" || fail "the menu has no shared mouse row: $(menu)"
grep -q 'Shared mouse' <<<"$(LAN_MOUSE="$sandbox/none" menu)" && fail 'the menu offers the mouse without lan-mouse'
cat >"$sandbox/bin/ip" <<'FAKE'
#!/usr/bin/env bash
printf '2: eth0    inet 198.51.100.20/24 brd 198.51.100.255 scope global dynamic eth0\n'
FAKE
chmod +x "$sandbox/bin/ip"
mkdir -p "$sandbox/net/eth0/device"
plan="$(PATH="$sandbox/bin:$PATH" VIVAC_SYS_CLASS_NET="$sandbox/net" HOME="$sandbox/user" "$repo_root/scripts/apply-system.sh" --dry-run --bridge)" ||
	fail 'apply-system.sh --dry-run --bridge failed'
grep -q 'would allow udp 4242 from 198.51.100.0/24 in UFW (vivac mouse)' <<<"$plan" || fail "the mouse port is not opened to the subnet: $plan"
grep -q 'would allow tcp 4242' <<<"$plan" && fail 'the mouse port was opened for TCP'

printf 'shared mouse: config.toml exact and valid, refused values kept out, fingerprint from the pem, systemctl only, dry runs inert, menu row, UDP 4242 to the subnet\n'
