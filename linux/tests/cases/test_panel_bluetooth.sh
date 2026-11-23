#!/usr/bin/env bash
set -Eeuo pipefail
# vivac-panel bluetooth, without a screen: bluetoothctl is a fake and the
# adapter is looked for in a fake /sys/class/bluetooth. No adapter (this
# machine's real state) must be said as such and never hang on bluetoothctl;
# with one, devices fall in connected / paired / nearby, battery is read,
# and the Waybar line is hidden without an adapter.
repo_root="${REPO_ROOT:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)}"
fail() { printf '%s\n' "$1" >&2; exit 1; }
sandbox="$(mktemp -d "${TMPDIR:-/tmp}/vivac-bt.XXXXXX")"
trap 'rm -rf -- "$sandbox"' EXIT
mkdir -p "$sandbox/bin" "$sandbox/sys"
export SANDBOX="$sandbox" VIVAC_LANG=en VIVAC_BTCTL="$sandbox/bin/bluetoothctl" VIVAC_BT_SYS="$sandbox/sys"
cat >"$sandbox/bin/bluetoothctl" <<'FAKE'
#!/usr/bin/env bash
echo "$*" >>"$SANDBOX/calls"
case "$*" in
show) printf 'Controller 00:11 (public)\n\tPowered: yes\n\tDiscovering: no\n' ;;
"devices Paired") printf 'Device AA:AA Auriculares\nDevice BB:BB Mando\n' ;;
devices) printf 'Device AA:AA Auriculares\nDevice BB:BB Mando\nDevice CC:CC Altavoz\n' ;;
"info AA:AA") printf 'Device AA:AA\n\tName: Auriculares\n\tIcon: audio-headset\n\tPaired: yes\n\tConnected: yes\n\tBattery Percentage: 0x50 (80)\n' ;;
"info BB:BB") printf 'Device BB:BB\n\tName: Mando\n\tIcon: input-gaming\n\tPaired: yes\n\tConnected: no\n' ;;
"info CC:CC") printf 'Device CC:CC\n\tName: Altavoz\n\tIcon: audio-speakers\n\tPaired: no\n\tConnected: no\n\tRSSI: -60\n' ;;
esac
FAKE
chmod +x "$sandbox/bin/bluetoothctl"
py() { /usr/bin/python3 -I -c "import sys; sys.path.insert(0,'$repo_root/lib'); from vivacpanel import bluetooth as b; $1"; }

[[ "$(py 'print(b.adapter_present())')" == "False" ]] || fail "no adapter in sys"
[[ "$(py 'print(b.snapshot().state)')" == "no_adapter" ]] || fail "state without adapter"
[[ ! -e "$sandbox/calls" ]] || fail "bluetoothctl must not be asked without an adapter"
line="$(/usr/bin/python3 -I -c "import sys; sys.path.insert(0,'$repo_root/lib'); from vivacpanel import bluetooth as b; b.waybar([])")"
/usr/bin/python3 -c 'import json,sys; d=json.loads(sys.argv[1]); assert d["text"]=="", d' "$line" || fail "waybar hidden: $line"

mkdir "$sandbox/sys/hci0"
out="$(py 's=b.snapshot(); print(s.state, s.powered); [print(d.mac,d.group,d.battery) for d in s.devices]')"
[[ "$(sed -n 1p <<<"$out")" == "on True" ]] || fail "adapter on: $out"
rg -q '^AA:AA connected 80$' <<<"$out" || fail "connected with battery: $out"
rg -q '^BB:BB paired None$' <<<"$out" || fail "paired: $out"
rg -q '^CC:CC nearby None$' <<<"$out" || fail "nearby: $out"
: >"$sandbox/calls"
py 'b.pair("CC:CC")'
rg -q 'pair CC:CC' "$sandbox/calls" && rg -q 'trust CC:CC' "$sandbox/calls" && rg -q 'connect CC:CC' "$sandbox/calls" || fail "pair flow: $(<"$sandbox/calls")"
py 'b.set_power(False)'; rg -q 'power off' "$sandbox/calls" || fail "power off"
line="$(/usr/bin/python3 -I -c "import sys; sys.path.insert(0,'$repo_root/lib'); from vivacpanel import bluetooth as b; b.waybar([])")"
/usr/bin/python3 -c 'import json,sys; d=json.loads(sys.argv[1]); assert "1" in d["text"], d' "$line" || fail "waybar count: $line"
echo ok
