#!/usr/bin/env bash
# The fakes are shell source written out literally: their $ expands when they run.
# shellcheck disable=SC2016
set -Eeuo pipefail

# Bluetooth pairings taken from Windows: Windows' keys, read from a .reg export
# or from the SYSTEM hive, land in BlueZ's info files with the byte order the
# ArchWiki gives, every other line kept byte for byte. A dry run writes
# nothing; --apply backs up each file it changes and stops bluetoothd around
# the writes; a hive Windows did not finish writing, or a hibernated Windows,
# is refused. No key value is ever printed.

repo_root="${REPO_ROOT:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)}"
tool="$repo_root/dotfiles/bridge/.local/bin/vivac-bt-sync"
fixtures="$repo_root/tests/data/bt-sync"

fail() {
	printf '%s\n' "$1" >&2
	exit 1
}
sandbox="$(mktemp -d "${TMPDIR:-/tmp}/vivac-bt-sync.XXXXXX")"
trap 'rm -rf -- "$sandbox"' EXIT
mkdir -p "$sandbox/bin"
calls="$sandbox/calls"
for fake in systemctl sudo kitty; do
	printf '#!/usr/bin/env bash\nprintf "%s %%s\\n" "$*" >>"$CALLS"\n' "$fake" >"$sandbox/bin/$fake"
done
chmod +x "$sandbox/bin/"*

# colon 0011220000A1 -> the address with colons. The fixtures name directories
# without them (they would not check out on Windows) and spell no address in
# full, so the privacy scan stays meaningful.
colon() { sed -E 's/(..)(..)(..)(..)(..)(..)/\1:\2:\3:\4:\5:\6/' <<<"$1"; }

# fresh — a BlueZ tree in the sandbox, from the fixture, as bluetoothd names it.
fresh() {
	rm -rf -- "$sandbox/bt"
	cp -r -- "$fixtures/bluez" "$sandbox/bt"
	local dir
	while IFS= read -r dir; do
		mv -- "$dir" "$(dirname -- "$dir")/$(colon "$(basename -- "$dir")")"
	done < <(find "$sandbox/bt" -depth -mindepth 1 -type d -regextype posix-extended -regex '.*/[0-9A-F]{12}')
}

run() {
	: >"$calls"
	PATH="$sandbox/bin:$PATH" CALLS="$calls" VIVAC_BT_DIR="$sandbox/bt" VIVAC_REPO="$repo_root" VIVAC_LANG=en \
		VIVAC_MOUNTS="$sandbox/mounts" HOME="$sandbox" "$tool" "$@" </dev/null
}
snapshot() { (cd "$sandbox/bt" && find . -type f -exec sha256sum {} + | LC_ALL=C sort); }

adapter="$(colon 001122334455)"
device() { printf '%s/%s/%s/info' "$sandbox/bt" "$adapter" "$(colon "$1")"; }
: >"$sandbox/mounts"

# --- the byte order, against the ArchWiki's worked example ----------------------------------------------------
python3 - "$tool" <<'PY' || fail 'a byte-order conversion is wrong'
import importlib.machinery, importlib.util, sys
sys.dont_write_bytecode = True  # no __pycache__ beside the tool in the checkout
loader = importlib.machinery.SourceFileLoader("btsync", sys.argv[1])
spec = importlib.util.spec_from_loader("btsync", loader)
m = sys.modules["btsync"] = importlib.util.module_from_spec(spec)
loader.exec_module(m)
# ERand 63 02 84 B8 5D 40 44 DF (REG_QWORD) is Rand=16088054540146049635.
assert m.number(bytes.fromhex("630284B85D4044DF")) == "16088054540146049635"
# EDIV 37520 (REG_DWORD 0x9290, stored little-endian) is EDiv=37520.
assert m.number(bytes.fromhex("90920000")) == "37520"
assert m.reg_data("dword:00009290") == (4, bytes.fromhex("90920000"))
assert m.reg_data("hex(b):63,02,84,b8,5d,40,44,df") == (11, bytes.fromhex("630284B85D4044DF"))
# An LTK of 48 4D AF CD ... 8B 94 is Key=484DAFCD0F9222880A529AF476DA8B94: no reversal.
assert m.key_hex(bytes.fromhex("484DAFCD0F9222880A529AF476DA8B94")) == "484DAFCD0F9222880A529AF476DA8B94"
assert m.mac_of("0011220000a1") == ":".join(["00", "11", "22", "00", "00", "A1"])
# A line of an info file is changed in place; one the section lacks goes under its header.
text = "[A]\nKey=1\nX=y\n\n[B]\nKey=2\n"
assert m.edit_info(text, [("B", "Key", "3"), ("A", "New", "4")]) == "[A]\nNew=4\nKey=1\nX=y\n\n[B]\nKey=3\n"
PY

# --- a dry run: the plan, and nothing written -----------------------------------------------------------------
fresh
before="$(snapshot)"
out="$(run --reg "$fixtures/windows.reg")" || fail "the dry run failed: $out"
[[ "$(snapshot)" == "$before" ]] || fail 'the dry run changed a file'
[[ ! -s "$calls" ]] || fail "the dry run called something: $(cat "$calls")"
expect() { grep -Fq -- "$1" <<<"$out" || fail "the plan lacks '$1': $out"; }
expect "$(colon 0011220000A1)  Fake headphones: update LinkKey.Key"
expect "$(colon 0011220000A2)  Fake keyboard: already the same on both systems"
expect "$(colon 0011220000A3)  Fake mouse: update LongTermKey.Key, LongTermKey.EncSize, LongTermKey.EDiv, LongTermKey.Rand"
expect "$(colon 0011220000A5)  Fake trackball: known here as $(colon 0011220000A4)"
expect "update PeripheralLongTermKey.Key, SlaveLongTermKey.Key"
expect "$(colon 0011220000A6)  Fake speaker: only in Windows"
expect "$(colon 0011220000A7)  Fake pen: paired differently on each system"
expect "$(colon 0011220000A9)  Fake remote: update IdentityResolvingKey.Key, LocalSignatureKey.Key"
expect "Adapter $(colon 001122334466) has pairings in Windows, but Linux has never used it"
expect '4 devices would change; nothing was written'
grep -q "$(colon 0011220000A8)" <<<"$out" && fail 'a device Windows does not have was listed'
grep -Eiq '00112233445566778899AABBCCDDEE|FFEEDDCCBBAA9988' <<<"$out" && fail "a key value was printed: $out"

# A regedit export (UTF-16 with a byte order mark, CRLF) reads the same.
python3 -c 'import sys; t=open(sys.argv[1],encoding="utf-8").read(); open(sys.argv[2],"wb").write(b"\xff\xfe"+t.replace("\n","\r\n").encode("utf-16-le"))' \
	"$fixtures/windows.reg" "$sandbox/regedit.reg"
[[ "$(run --reg "$sandbox/regedit.reg" | tail -n +2)" == "$(tail -n +2 <<<"$out")" ]] ||
	fail 'a UTF-16 regedit export read differently'

# --- --apply: the files, byte for byte; backups; bluetoothd stopped around it ---------------------------------
chmod 600 "$(device 0011220000A1)"
out="$(run --reg "$fixtures/windows.reg" --apply)" || fail "the apply failed: $out"
[[ "$(cat "$calls")" == $'systemctl stop bluetooth.service\nsystemctl start bluetooth.service' ]] ||
	fail "bluetoothd was not stopped and started around the writes: $(cat "$calls")"
for mac in 0011220000A1 0011220000A3 0011220000A5 0011220000A9; do
	cmp -s -- "$fixtures/expected/001122334455/$mac/info" "$(device $mac)" ||
		fail "$mac: $(diff -- "$fixtures/expected/001122334455/$mac/info" "$(device $mac)" || true)"
done
for mac in 0011220000A2 0011220000A7 0011220000A8; do
	cmp -s -- "$fixtures/bluez/001122334455/$mac/info" "$(device $mac)" || fail "$mac changed though it needed nothing"
done
[[ ! -e "$(dirname -- "$(device 0011220000A4)")" ]] || fail 'the device that took a new address was not moved'
for mac in 0011220000A1 0011220000A3 0011220000A9; do
	backups=("$(dirname -- "$(device $mac)")"/info.vivac-bak-*)
	if [[ ${#backups[@]} != 1 ]] || ! cmp -s -- "${backups[0]}" "$fixtures/bluez/001122334455/$mac/info"; then
		fail "$mac: no backup of the previous file"
	fi
done
cmp -s -- "$(dirname -- "$(device 0011220000A5)")"/info.vivac-bak-* "$fixtures/bluez/001122334455/0011220000A4/info" ||
	fail 'the moved device has no backup of its previous file'
[[ "$(stat -c %a "$(device 0011220000A1)")" == 600 ]] || fail 'the file mode was not kept'
[[ -z "$(find "$sandbox/bt" -name 'info.vivac-new')" ]] || fail 'a temporary file was left behind'

# A second run finds nothing to do and touches nothing.
out="$(run --reg "$fixtures/windows.reg" --apply)" || fail 'the second apply failed'
grep -q 'Nothing to change' <<<"$out" || fail "the second run still had changes: $out"
[[ ! -s "$calls" ]] || fail 'the second run restarted bluetoothd for nothing'

# --- the hive itself, through python-hivex ---------------------------------------------------------------------
if python3 -c 'import hivex' 2>/dev/null; then
	python3 "$fixtures/make-hive.py" "$tool" "$fixtures/windows.reg" "$sandbox/SYSTEM" || fail 'the test hive could not be made'
	fresh
	reg_plan="$(run --reg "$fixtures/windows.reg" | tail -n +2)"
	out="$(run --hive "$sandbox/SYSTEM")" || fail "reading the hive failed: $out"
	grep -q '(ControlSet002)' <<<"$out" || fail "the control set was not taken from Select\\Current: $out"
	[[ "$(tail -n +2 <<<"$out")" == "$reg_plan" ]] || fail "the hive and the export gave different plans: $out"

	# Found among the mounts; refused while Windows is hibernated or the hive half-written.
	mkdir -p "$sandbox/win/Windows/System32/config"
	cp -- "$sandbox/SYSTEM" "$sandbox/win/Windows/System32/config/SYSTEM"
	printf '/dev/fake3 %s ntfs3 rw,relatime 0 0\n' "${sandbox// /\\040}/win" >"$sandbox/mounts"
	run --available || fail '--available did not find the mounted Windows'
	printf 'HIBR' >"$sandbox/win/hiberfil.sys"
	before="$(snapshot)"
	if run --apply >/dev/null 2>&1; then fail 'applied from a hibernated Windows'; fi
	[[ "$(snapshot)" == "$before" && ! -s "$calls" ]] || fail 'a refused apply changed something'
	printf 'wake' >"$sandbox/win/hiberfil.sys"
	python3 "$fixtures/make-hive.py" "$tool" "$fixtures/windows.reg" "$sandbox/win/Windows/System32/config/SYSTEM" --dirty
	out="$(run --apply 2>&1)" && fail 'applied from a hive Windows did not finish writing'
	grep -q 'not closed cleanly' <<<"$out" || fail "the half-written hive was not named: $out"
	[[ "$(snapshot)" == "$before" ]] || fail 'a refused apply changed something'
	cp -- "$sandbox/SYSTEM" "$sandbox/win/Windows/System32/config/SYSTEM"
	run --apply >/dev/null || fail 'the apply from a cleanly shut down Windows failed'
	cmp -s -- "$fixtures/expected/001122334455/0011220000A1/info" "$(device 0011220000A1)" || fail 'the hive apply wrote the wrong key'
	hive='hive read through hivex'
else
	hive='hivex not installed, the hive path not exercised'
fi

# --- the menu row, the terminal it asks in, and the sudo hop ---------------------------------------------------
printf '/dev/fake3 %s ntfs3 rw 0 0\n' "$sandbox/win" >"$sandbox/mounts"
mkdir -p "$sandbox/win/Windows/System32/config" && : >>"$sandbox/win/Windows/System32/config/SYSTEM"
menu="$(PATH="$sandbox/bin:$PATH" VIVAC_REPO="$repo_root" VIVAC_LANG=en VIVAC_MOUNTS="$sandbox/mounts" HOME="$sandbox" \
	"$repo_root/dotfiles/bridge/.local/bin/vivac-bridge" --print)"
grep -Fxq 'Bluetooth: take pairings from Windows' <<<"$menu" || fail "the bridge menu has no Bluetooth row: $menu"
: >"$sandbox/mounts"
if run --available; then fail '--available said yes with no Windows mounted'; fi
menu="$(PATH="$sandbox/bin:$PATH" VIVAC_REPO="$repo_root" VIVAC_LANG=en VIVAC_MOUNTS="$sandbox/mounts" HOME="$sandbox" \
	"$repo_root/dotfiles/bridge/.local/bin/vivac-bridge" --print)"
grep -q Bluetooth <<<"$menu" && fail 'the Bluetooth row shows with no Windows mounted'

run --ask --reg "$fixtures/windows.reg" >/dev/null || true
grep -q '^kitty --hold --title .* --ask --reg' "$calls" || fail "--ask from a menu did not open a terminal: $(cat "$calls")"

if ((EUID != 0)); then
	: >"$calls"
	PATH="$sandbox/bin:$PATH" CALLS="$calls" VIVAC_LANG=es HOME="$sandbox" "$tool" --reg "$fixtures/windows.reg" </dev/null || true
	grep -q "^sudo -- .*vivac-bt-sync --reg .* --lang es$" "$calls" || fail "it did not ask sudo for itself: $(cat "$calls")"
fi

printf 'bluetooth from Windows: byte order per the ArchWiki, 4 devices written byte for byte, backups, refusals (%s)\n' "$hive"
