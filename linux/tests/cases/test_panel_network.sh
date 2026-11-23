#!/usr/bin/env bash
set -Eeuo pipefail
# vivac-panel network, without a screen: nmcli is a fake. Wi-Fi lists dedupe by
# SSID (strongest wins, the one in use first), a secured unknown network needs
# a password, the dual-adapter setup is read from wifi-dual.conf, the primary
# is the lower route metric, and the Waybar line says what carries traffic.
repo_root="${REPO_ROOT:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)}"
fail() { printf '%s\n' "$1" >&2; exit 1; }
sandbox="$(mktemp -d "${TMPDIR:-/tmp}/vivac-net.XXXXXX")"
trap 'rm -rf -- "$sandbox"' EXIT
mkdir -p "$sandbox/bin"
export PATH="$sandbox/bin:$PATH" VIVAC_LANG=en VIVAC_NMCLI="$sandbox/bin/nmcli" SANDBOX="$sandbox"
cat >"$sandbox/wifi-dual.conf" <<'C'
INT_DEV=wlp5s0
INT_CON=casa-int
ALFA_DEV=wlu4
ALFA_CON=casa-alfa
C
export VIVAC_WIFI_DUAL_CONF="$sandbox/wifi-dual.conf"
cat >"$sandbox/bin/nmcli" <<'FAKE'
#!/usr/bin/env bash
echo "$*" >>"$SANDBOX/calls"
case "$*" in
"-t -f DEVICE,TYPE,STATE,CONNECTION device status")
 printf 'wlu4:wifi:connected:casa-alfa\nenp1:ethernet:connected:cable\nwlp5s0:wifi:unavailable:\nlo:loopback:connected (externally):lo\n' ;;
"-t -f IN-USE,SSID,SECURITY,SIGNAL,CHAN,FREQ device wifi list ifname wlu4 --rescan no")
 printf ' :Library:WPA2:56:6:2437 MHz\n*:casa:WPA2:80:48:5240 MHz\n :casa:WPA2:60:6:2437 MHz\n :Open:--:30:1:2412 MHz\n :Library:WPA2:40:11:2462 MHz\n' ;;
"-t -f NAME,TYPE connection show") printf 'casa-alfa:802-11-wireless\ncable:802-3-ethernet\nLibrary:802-11-wireless\n' ;;
"-g ipv4.route-metric connection show casa-alfa") echo 600 ;;
"-g ipv4.route-metric connection show casa-int") echo 700 ;;
"-g GENERAL.STATE device show wlu4") echo "100 (connected)" ;;
"-g GENERAL.STATE device show wlp5s0") echo "20 (unavailable)" ;;
"-t -f IN-USE,SIGNAL device wifi list ifname wlu4 --rescan no") printf '*:80\n :60\n' ;;
"-g IP4.ADDRESS device show wlu4") echo 192.168.1.5/24 ;;
"-g IP4.ADDRESS device show enp1") echo 192.168.1.9/24 ;;
"-g GENERAL.STATE device show enp1") echo "100 (connected)" ;;
"-g WIFI-PROPERTIES.ENABLED general")  ;;
"radio wifi") echo enabled ;;
*) : ;;
esac
FAKE
chmod +x "$sandbox/bin/nmcli"
py() { /usr/bin/python3 -I -c "import sys; sys.path.insert(0,'$repo_root/lib'); $1"; }

out="$(py 'from vivacpanel import network as n; [print(x.ssid,x.signal,x.security,x.in_use,x.known) for x in n.networks("wlu4")]')"
[[ "$(sed -n 1p <<<"$out")" == "casa 80 WPA2 True False" ]] || fail "in-use network first, strongest: $out"
[[ "$(wc -l <<<"$out")" -eq 3 ]] || fail "dedupe by SSID: $out"
rg -q '^Library 56 WPA2 False True$' <<<"$out" || fail "known profile flagged: $out"
rg -q '^Open 30 None False False$' <<<"$out" || fail "open network has no security: $out"

py 'from vivacpanel import network as n; print(n.needs_password(n.Network("x",50,"WPA2",False,False)), n.needs_password(n.Network("x",50,"",False,False)), n.needs_password(n.Network("x",50,"WPA2",False,True)))' | rg -q '^True False False$' || fail "password rule"

out="$(py 'from vivacpanel import network as n; d=n.dual(); print(d.primary,[(a.label,a.state) for a in d.adapters])')"
[[ "$out" == "alfa [('int', 'unavailable'), ('alfa', 'connected')]" ]] || fail "dual: $out"

: >"$sandbox/calls"
py 'from vivacpanel import network as n; n.connect("Library","wlu4","pw")'
rg -q 'device wifi connect Library password pw ifname wlu4' "$sandbox/calls" || fail "connect with password: $(<"$sandbox/calls")"
: >"$sandbox/calls"
py 'from vivacpanel import network as n; n.set_primary("int")'
rg -q 'connection modify casa-int ipv4.route-metric 600' "$sandbox/calls" || fail "primary int"
rg -q 'connection modify casa-alfa ipv4.route-metric 700' "$sandbox/calls" || fail "backup alfa"
: >"$sandbox/calls"
py 'from vivacpanel import network as n; n.forget("Library")'
rg -q 'connection delete id Library' "$sandbox/calls" || fail "forget"

line="$(/usr/bin/python3 -I -c "import sys; sys.path.insert(0,'$repo_root/lib'); from vivacpanel import network as n; n.waybar([])")"
py 'import json,sys' && /usr/bin/python3 -c 'import json,sys; d=json.loads(sys.argv[1]); assert d["class"]=="wifi" and "casa" in d["tooltip"], d' "$line" || fail "waybar line: $line"
echo ok
