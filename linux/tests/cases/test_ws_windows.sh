#!/usr/bin/env bash
# shellcheck disable=SC2016
set -Eeuo pipefail

# ws-windows.sh: only the asked workspace's windows, most recent first; one
# window is focused without a picker, none goes to the workspace, the
# picker's choice is focused by address, and a bad number is refused.

repo_root="${REPO_ROOT:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)}"
tool="$repo_root/dotfiles/waybar/.config/waybar/scripts/ws-windows.sh"
fail() {
	printf '%s\n' "$1" >&2
	exit 1
}
sandbox="$(mktemp -d "${TMPDIR:-/tmp}/ws-windows.XXXXXX")"
trap 'rm -rf -- "$sandbox"' EXIT
mkdir -p "$sandbox/bin"
cat >"$sandbox/bin/hyprctl" <<'FAKE'
#!/usr/bin/env bash
if [[ "$1" == clients ]]; then
	echo '[{"address":"0xa","class":"kitty","title":"shell","workspace":{"id":2},"focusHistoryID":3},
	       {"address":"0xb","class":"firefox","title":"News","workspace":{"id":2},"focusHistoryID":1},
	       {"address":"0xc","class":"Steam","title":"Steam","workspace":{"id":5},"focusHistoryID":2}]'
fi
FAKE
cat >"$sandbox/bin/dispatch.sh" <<'FAKE'
#!/usr/bin/env bash
printf 'dispatch %s\n' "$*" >>"$SANDBOX/calls"
FAKE
cat >"$sandbox/bin/rofi" <<'FAKE'
#!/usr/bin/env bash
cat >"$SANDBOX/rofi-in"
echo 1
FAKE
chmod +x "$sandbox/bin/"*
export PATH="$sandbox/bin:$PATH" SANDBOX="$sandbox" WS_DISPATCH="$sandbox/bin/dispatch.sh"

[[ "$("$tool" 2 --print)" == $'firefox — News\nkitty — shell' ]] || fail "rows: $("$tool" 2 --print)"
"$tool" 2
grep -qxF 'dispatch focuswindow address:0xa' "$sandbox/calls" || fail "picked row not focused: $(<"$sandbox/calls")"
grep -qF 'News' "$sandbox/rofi-in" || fail "picker did not list the workspace's windows"
: >"$sandbox/calls"
"$tool" 5
grep -qxF 'dispatch focuswindow address:0xc' "$sandbox/calls" || fail "a lone window should be focused directly"
: >"$sandbox/calls"
"$tool" 7
grep -qxF 'dispatch workspace 7' "$sandbox/calls" || fail "an empty workspace should be gone to"
if "$tool" 11 2>/dev/null; then fail "workspace 11 accepted"; fi
printf 'ok: ws-windows\n'
