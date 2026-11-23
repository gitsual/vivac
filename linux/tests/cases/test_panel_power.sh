#!/usr/bin/env bash
set -Eeuo pipefail

# vivac-panel power, without a screen: six tiles in the order of the design
# (lock, log out, suspend, reboot, power off, restart in Windows), Windows only
# where vivac-reboot-other says the firmware has an entry, the destructive
# ones asking for a second confirmation, and the commands being literals.

repo_root="${REPO_ROOT:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)}"
fail() { printf '%s\n' "$1" >&2; exit 1; }
sandbox="$(mktemp -d "${TMPDIR:-/tmp}/vivac-power.XXXXXX")"
trap 'rm -rf -- "$sandbox"' EXIT
home="$sandbox/home"
mkdir -p "$home/.local/bin" "$home/.config/hypr/scripts"
export HOME="$home" VIVAC_LANG=en
printf '#!/usr/bin/env bash\nexit 0\n' >"$home/.local/bin/vivac-reboot-other"
chmod +x "$home/.local/bin/vivac-reboot-other"

py() { /usr/bin/python3 -I -c "import sys; sys.path.insert(0, '$repo_root/lib'); from vivacpanel import power; $1"; }

out="$(py 'print(",".join(e.key for e in power.entries()))')"
[[ "$out" == "lock,logout,suspend,reboot,poweroff,windows" ]] || fail "order with Windows available: $out"

printf '#!/usr/bin/env bash\nexit 1\n' >"$home/.local/bin/vivac-reboot-other"
out="$(py 'print(",".join(e.key for e in power.entries()))')"
[[ "$out" == "lock,logout,suspend,reboot,poweroff" ]] || fail "Windows must be absent without a firmware entry: $out"

out="$(py 'print(",".join(e.key for e in power.entries() if e.destructive))')"
[[ "$out" == "reboot,poweroff" ]] || fail "only reboot and power off are destructive: $out"

out="$(py 'print(power.command("poweroff"))')"
[[ "$out" == "['systemctl', 'poweroff']" ]] || fail "poweroff command: $out"
out="$(py 'print(power.command("lock"))')"
[[ "$out" == "['hyprlock']" ]] || fail "lock command: $out"
out="$(py 'print(power.command("logout"))')"
[[ "$out" == *"dispatch.sh', 'exit']" ]] || fail "logout command: $out"

out="$(py 'print(power.confirm_text("poweroff"))')"
[[ "$out" == "Power off the computer?" ]] || fail "confirm text: $out"
out="$(py 'print(power.step(0, 1, 6), power.step(5, 1, 6), power.step(0, 3, 6), power.step(4, 3, 6), power.step(5, -3, 6), power.step(2, -1, 6))')"
[[ "$out" == "1 5 3 5 2 1" ]] || fail "movement: $out"
printf 'power panel: order, Windows availability, confirmation, commands and movement\n'
