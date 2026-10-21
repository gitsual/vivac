#!/usr/bin/env bash
set -Eeuo pipefail

# The test VM's autologin path (--desktop-login --vm) is byte-identical to the
# copy frozen before the GUI greeter existed, and a run without --greeter
# never mentions the greeter.

repo_root="${REPO_ROOT:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)}"

fail() {
	printf '%s\n' "$1" >&2
	exit 1
}
cmp -s "$repo_root/system/etc/greetd/config-vm.toml" "$repo_root/tests/data/greetd/config-vm.toml" ||
	fail 'system/etc/greetd/config-vm.toml differs from its frozen copy (tests/data/greetd/config-vm.toml)'
out="$(bash "$repo_root/scripts/apply-system.sh" --dry-run --desktop-login --vm)" || fail 'autologin dry run failed'
grep -q 'config-vm.toml -> /etc/greetd/config.toml' <<<"$out" || fail 'the VM autologin config is no longer installed'
grep -Eq 'regreet|cage|LANG=|XKB' <<<"$out" && fail "the autologin path mentions the greeter: $out"
grep -Fxq 'command = "Hyprland"' "$repo_root/system/etc/greetd/config-vm.toml" || fail 'the VM no longer logs straight into Hyprland'

printf 'autologin unchanged: VM greetd config frozen, no greeter on the default path\n'
