#!/usr/bin/env bash
# shellcheck disable=SC2016
set -Eeuo pipefail

# vivac-panel usb, without a screen: removable drives are read from lsblk (an
# internal disk never is one), the Waybar line is empty with none and carries
# a glyph, a count and a tooltip with some, opening mounts a drive first,
# ejecting unmounts every partition then powers the disk off and says so, and
# a busy or vanished drive is said as such. lsblk, udisksctl, xdg-open and
# notify-send are fakes.

repo_root="${REPO_ROOT:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)}"
fail() {
	printf '%s\n' "$1" >&2
	exit 1
}
sandbox="$(mktemp -d "${TMPDIR:-/tmp}/vivac-usb.XXXXXX")"
trap 'rm -rf -- "$sandbox"' EXIT
mkdir -p "$sandbox/bin"
export SANDBOX="$sandbox"
export PATH="$sandbox/bin:$PATH"
export VIVAC_LANG=en

cat >"$sandbox/bin/lsblk" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$SANDBOX/lsblk.args"
[[ -e "$SANDBOX/lsblk.json" ]] && cat "$SANDBOX/lsblk.json" || printf '{"blockdevices":[]}\n'
FAKE
cat >"$sandbox/bin/udisksctl" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$SANDBOX/udisks.log"
case "$1" in
mount)
	[[ -e "$SANDBOX/mount.fail" ]] && { echo 'Error mounting: boom' >&2; exit 1; }
	echo "Mounted $3 at /run/media/u/CARD."
	;;
unmount)
	[[ -e "$SANDBOX/busy" ]] && { echo 'Error unmounting /dev/sdb1: GDBus.Error:org.freedesktop.UDisks2.Error.DeviceBusy: target is busy' >&2; exit 1; }
	[[ -e "$SANDBOX/gone" ]] && { echo "Error looking up object for device $3" >&2; exit 1; }
	echo "Unmounted $3."
	;;
power-off) echo "Powered off $3" ;;
esac
FAKE
for t in xdg-open notify-send; do
	cat >"$sandbox/bin/$t" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$SANDBOX/$(basename "$0").log"
FAKE
done
chmod +x "$sandbox/bin/"*

# sda internal (sata, not removable); sdb a USB stick with two partitions, one
# mounted; sdc an SD card with one unmounted partition.
cat >"$sandbox/lsblk.json" <<'JSON'
{"blockdevices":[
 {"name":"sda","path":"/dev/sda","pkname":null,"label":null,"model":"Samsung SSD","size":120034123776,"fsuse%":null,"fstype":null,"mountpoint":null,"rm":false,"hotplug":false,"tran":"sata","type":"disk",
  "children":[{"name":"sda2","path":"/dev/sda2","pkname":"sda","label":null,"model":null,"size":118000000000,"fsuse%":"60%","fstype":"ext4","mountpoint":"/home","rm":false,"hotplug":false,"tran":null,"type":"part"}]},
 {"name":"sdb","path":"/dev/sdb","pkname":null,"label":null,"model":"Cruzer Blade ","size":32000000000,"fsuse%":null,"fstype":null,"mountpoint":null,"rm":true,"hotplug":true,"tran":"usb","type":"disk",
  "children":[{"name":"sdb1","path":"/dev/sdb1","pkname":"sdb","label":"CLAVE","model":null,"size":30000000000,"fsuse%":"41%","fstype":"exfat","mountpoint":"/run/media/u/CLAVE","rm":true,"hotplug":true,"tran":null,"type":"part"},
   {"name":"sdb2","path":"/dev/sdb2","pkname":"sdb","label":"DATOS","model":null,"size":2000000000,"fsuse%":null,"fstype":"ext4","mountpoint":null,"rm":true,"hotplug":true,"tran":null,"type":"part"}]},
 {"name":"sdc","path":"/dev/sdc","pkname":null,"label":null,"model":"SD Reader","size":64000000000,"fsuse%":null,"fstype":null,"mountpoint":null,"rm":"1","hotplug":"1","tran":null,"type":"disk",
  "children":[{"name":"sdc1","path":"/dev/sdc1","pkname":"sdc","label":null,"model":null,"size":64000000000,"fsuse%":null,"fstype":"vfat","mountpoint":null,"rm":"1","hotplug":"1","tran":null,"type":"part"}]},
 {"name":"sdd","path":"/dev/sdd","pkname":null,"label":null,"model":"Storage Device","size":0,"fsuse%":null,"fstype":null,"mountpoint":null,"rm":true,"hotplug":true,"tran":"usb","type":"disk"},
 {"name":"sr0","path":"/dev/sr0","pkname":null,"label":null,"model":"DVD","size":1073741312,"fsuse%":null,"fstype":null,"mountpoint":null,"rm":true,"hotplug":true,"tran":"sata","type":"rom"}
]}
JSON
nodrives='{"blockdevices":[{"name":"sda","path":"/dev/sda","pkname":null,"label":null,"model":"Samsung SSD","size":1,"fsuse%":null,"fstype":null,"mountpoint":null,"rm":false,"hotplug":false,"tran":"sata","type":"disk"}]}'

py() { /usr/bin/python3 -I -c "import sys; sys.path.insert(0, '$repo_root/lib'); from vivacpanel import usb; $1"; }

# --- the drives: removable disks only, one per volume, rm/hotplug as bool or "1" ---------------------------------
out="$(py 'print("|".join(f"{d.path},{d.name},{d.used_pct},{d.mount},{d.fstype}" for d in usb.drives()))')" || fail "drives() failed: $out"
[[ "$out" == '/dev/sdb1,CLAVE,41,/run/media/u/CLAVE,exfat|/dev/sdb2,DATOS,None,None,ext4|/dev/sdc1,SD Reader,None,None,vfat' ]] || fail "drives(): $out"
grep -q -- '-b' "$sandbox/lsblk.args" || fail 'lsblk was not asked for bytes'

# (sdd is a card reader with no card, size 0: not a drive)

# --- Waybar: hidden with none, glyph + count + tooltip with some ------------------------------------------------
printf '%s\n' "$nodrives" >"$sandbox/lsblk.json.none"
mv "$sandbox/lsblk.json" "$sandbox/lsblk.json.full"
mv "$sandbox/lsblk.json.none" "$sandbox/lsblk.json"
out="$(py 'usb.waybar([])')" || fail "waybar() failed: $out"
[[ "$(wc -l <<<"$out")" == 1 ]] || fail "waybar is not one line: $out"
[[ "$(/usr/bin/python3 -I -c 'import json,sys; print(json.loads(sys.argv[1])["text"] == "")' "$out")" == True ]] || fail "no drives, but text: $out"
mv "$sandbox/lsblk.json.full" "$sandbox/lsblk.json"
out="$(py 'usb.waybar([])')"
/usr/bin/python3 -I - "$out" <<'PY' || fail "waybar with drives: $out"
import json, sys
d = json.loads(sys.argv[1])
assert d["text"].startswith("\U000F129E") and d["text"].endswith("3"), d
assert "CLAVE" in d["tooltip"] and "/run/media/u/CLAVE" in d["tooltip"] and "DATOS" in d["tooltip"], d
assert d["class"] == "usb", d
PY

# --- open: a mounted drive is opened as it is, an unmounted one is mounted first --------------------------------
py 'usb.open_drive(usb.drives()[0])' || fail 'open_drive (mounted) failed'
grep -qx '/run/media/u/CLAVE' "$sandbox/xdg-open.log" || fail "xdg-open: $(cat "$sandbox/xdg-open.log")"
[[ ! -e "$sandbox/udisks.log" ]] || fail 'a mounted drive was mounted again'
py 'usb.open_drive(usb.drives()[2])' || fail 'open_drive (unmounted) failed'
grep -qx 'mount -b /dev/sdc1' "$sandbox/udisks.log" || fail "mount: $(cat "$sandbox/udisks.log")"
grep -qx '/run/media/u/CARD' "$sandbox/xdg-open.log" || fail 'the new mount point was not opened'
touch "$sandbox/mount.fail"
out="$(py 'print(usb.open_drive(usb.drives()[2]))')"
[[ "$out" == *boom* ]] || fail "a failed mount did not say why: $out"
rm "$sandbox/mount.fail"

# --- eject: every partition unmounted, then the disk powered off, then told -----------------------------------
rm -f "$sandbox/udisks.log"
out="$(py 'print(usb.eject(usb.drives()[0]))')" || fail "eject failed: $out"
[[ "$out" == done ]] || fail "eject said: $out"
[[ "$(cat "$sandbox/udisks.log")" == $'unmount -b /dev/sdb1\npower-off -b /dev/sdb' ]] \
	|| fail "eject did not unmount (only the mounted one) then power off: $(cat "$sandbox/udisks.log")"
rm -f "$sandbox/udisks.log" "$sandbox/notify-send.log"
py 'usb.eject_and_notify(usb.drives()[0])'
grep -q 'CLAVE can be removed' "$sandbox/notify-send.log" || fail "no 'can be removed' notification: $(cat "$sandbox/notify-send.log" 2>&1)"
touch "$sandbox/busy"
rm -f "$sandbox/udisks.log" "$sandbox/notify-send.log"
out="$(py 'print(usb.eject(usb.drives()[0]))')"
[[ "$out" == busy ]] || fail "busy drive: $out"
grep -q power-off "$sandbox/udisks.log" && fail 'a busy drive was powered off'
py 'usb.eject_and_notify(usb.drives()[0])'
grep -q 'CLAVE is still in use' "$sandbox/notify-send.log" || fail "no busy notification: $(cat "$sandbox/notify-send.log")"
rm "$sandbox/busy"
touch "$sandbox/gone"
out="$(py 'print(usb.eject(usb.drives()[0]))')"
[[ "$out" == gone ]] || fail "vanished drive: $out"
rm "$sandbox/gone"

# --- no udisksctl / no lsblk: nothing to show, never a traceback -----------------------------------------------
rm "$sandbox/bin/lsblk"
out="$(PATH="$sandbox/bin:/usr/bin-none" py 'print(len(usb.drives()))')" || fail "drives() without lsblk raised: $out"
[[ "$out" == 0 ]] || fail "without lsblk: $out"

printf 'usb: removable only, waybar hidden/visible, open mounts first, eject unmounts then powers off, busy and gone said\n'
