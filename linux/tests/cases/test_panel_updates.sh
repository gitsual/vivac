#!/usr/bin/env bash
# The fakes are shell source written out literally: their $ expands when they run.
# shellcheck disable=SC2016
set -Eeuo pipefail

# vivac-panel updates, its backend and the bar's line without a display: what
# checkupdates, yay, uv and npm say becomes one list per origin, an AUR
# package blocked for that very version is shown but not counted, the
# kernel/firmware/mesa/nvidia ones are marked as needing a restart, a restart
# is wanted when the running kernel's modules are gone, the bar line is
# pending / security / empty, a cache answers until pacman's database changes,
# and no tools at all is an empty answer, not an error.

repo_root="${REPO_ROOT:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)}"
fail() {
	printf '%s\n' "$1" >&2
	exit 1
}
sandbox="$(mktemp -d "${TMPDIR:-/tmp}/vivac-updates.XXXXXX")"
trap 'rm -rf -- "$sandbox"' EXIT
mkdir -p "$sandbox/bin" "$sandbox/empty" "$sandbox/state/waybar-updates" "$sandbox/cache" "$sandbox/modules/7.3.5-arch1-1" "$sandbox/pacman-local"

cat >"$sandbox/bin/checkupdates" <<'FAKE'
#!/usr/bin/env bash
printf 'x\n' >>"$SANDBOX/checkupdates-calls"
printf '%s\n' 'linux 7.3.5.arch1-1 -> 7.3.6.arch1-1' 'mesa 26.0.1-1 -> 26.0.2-1' 'bash 5.2-1 -> 5.3-1'
exit 0
FAKE
cat >"$sandbox/bin/yay" <<'FAKE'
#!/usr/bin/env bash
[[ "$*" == "-Qua" ]] || exit 1
printf '%s\n' 'foo 1.0-1 -> 2.0-1' 'bar 1.0-1 -> 3.0-1'
FAKE
cat >"$sandbox/bin/uv" <<'FAKE'
#!/usr/bin/env bash
[[ "$*" == "tool list --outdated" ]] || exit 1
printf '%s\n' 'aider-chat v0.86.2 [latest: v0.87.0]' '- aider'
FAKE
cat >"$sandbox/bin/npm" <<'FAKE'
#!/usr/bin/env bash
[[ "$*" == "outdated -g --json" ]] || exit 1
echo '{"typescript":{"current":"5.0.0","wanted":"5.0.4","latest":"5.4.0"}}'
exit 1
FAKE
cat >"$sandbox/bin/uname" <<'FAKE'
#!/usr/bin/bash
echo 7.3.5-arch1-1
FAKE
chmod +x "$sandbox/bin/"*
mkdir -p "$sandbox/i18n"
printf '%s\n' 'updates.repo=System' 'updates.aur=AUR' 'updates.uv=uv' 'updates.npm=npm' 'updates.blocked_tip=Blocked: {1}' \
	'updates.reboot_tip=Restart needed' 'updates.click=Click' >"$sandbox/i18n/en.conf"
echo 'bar 3.0-1' >"$sandbox/state/waybar-updates/aur-blocked"

export SANDBOX="$sandbox" I18N_DIR="$sandbox/i18n" VIVAC_LANG=en XDG_STATE_HOME="$sandbox/state" XDG_CACHE_HOME="$sandbox/cache" \
	VIVAC_MODULES="$sandbox/modules" VIVAC_PACMAN_LOCAL="$sandbox/pacman-local" \
	PATH="$sandbox/bin:$PATH"

out="$(/usr/bin/python3 - "$repo_root/lib" <<'PY'
import sys
sys.path.insert(0, sys.argv[1])
from vivacpanel import updates
r = updates.collect(use_cache=False)
for source, pkgs in r.groups.items():
    print(source, [(p.name, p.old, p.new, p.restart) for p in pkgs])
print("blocked", [p.name for p in r.blocked])
print("total", r.total, "reboot", r.reboot, "restart", r.restart)
PY
)"
grep -qF "repo [('linux', '7.3.5.arch1-1', '7.3.6.arch1-1', True), ('mesa', '26.0.1-1', '26.0.2-1', True), ('bash', '5.2-1', '5.3-1', False)]" <<<"$out" || fail "repo: $out"
grep -qF "aur [('foo', '1.0-1', '2.0-1', False)]" <<<"$out" || fail "aur: $out"
grep -qF "blocked ['bar']" <<<"$out" || fail "blocked: $out"
grep -qF "uv [('aider-chat', '0.86.2', '0.87.0', False)]" <<<"$out" || fail "uv: $out"
grep -qF "npm [('typescript', '5.0.0', '5.4.0', False)]" <<<"$out" || fail "npm: $out"
grep -qF "total 6 reboot False restart True" <<<"$out" || fail "totals: $out"

# The running kernel's modules are gone (a new kernel replaced it): restart wanted.
rmdir "$sandbox/modules/7.3.5-arch1-1"
line="$(/usr/bin/python3 "$repo_root/dotfiles/ricer/.local/bin/vivac-panel" waybar updates)"
/usr/bin/python3 -c 'import json,sys; d=json.loads(sys.argv[1]); assert d["text"]=="6", d; assert d["class"]=="security", d; assert "AUR" in d["tooltip"] and "bar" in d["tooltip"], d; assert d["tooltip"].count("\n")>=3, d' "$line" || fail "bar line: $line"
mkdir "$sandbox/modules/7.3.5-arch1-1"

# A cache answers until pacman's database changes.
calls_before="$(wc -l <"$sandbox/checkupdates-calls")"
/usr/bin/python3 "$repo_root/dotfiles/ricer/.local/bin/vivac-panel" waybar updates >/dev/null
[[ "$(wc -l <"$sandbox/checkupdates-calls")" == "$calls_before" ]] || fail 'the cache was not used'
touch -d '+1 minute' "$sandbox/pacman-local"
/usr/bin/python3 "$repo_root/dotfiles/ricer/.local/bin/vivac-panel" waybar updates >/dev/null
[[ "$(wc -l <"$sandbox/checkupdates-calls")" == "$((calls_before + 1))" ]] || fail 'a changed pacman database did not refresh the cache'

# Nothing pending and no tools: an empty line, never an error.
rm -rf "$sandbox/cache"/*
line="$(PATH="$sandbox/empty" /usr/bin/python3 "$repo_root/dotfiles/ricer/.local/bin/vivac-panel" waybar updates)" || fail 'no tools: the bar line failed'
/usr/bin/python3 -c 'import json,sys; d=json.loads(sys.argv[1]); assert d["text"]=="0" and d["class"]=="none", d' "$line" || fail "nothing pending must still be a button (0): $line"

# Only a restart waiting: still shown, as pending.
mkdir "$sandbox/uname-only"
cp "$sandbox/bin/uname" "$sandbox/uname-only/"
rmdir "$sandbox/modules/7.3.5-arch1-1"
rm -rf "$sandbox/cache"/*
line="$(PATH="$sandbox/uname-only" /usr/bin/python3 "$repo_root/dotfiles/ricer/.local/bin/vivac-panel" waybar updates)"
/usr/bin/python3 -c 'import json,sys; d=json.loads(sys.argv[1]); assert d["text"]!="" and d["class"]=="pending", d' "$line" || fail "restart only: $line"
printf 'ok: updates backend (4 origins, blocked, restart marks, bar line, cache, no tools)\n'
