#!/usr/bin/env bash
# The fakes are shell source written out literally: their $ expands when they run.
# shellcheck disable=SC2016
set -Eeuo pipefail

# Hermes across the dual boot: --share moves this side's home onto the Windows
# partition and leaves ~/.hermes as a link to it, this side's files winning
# and Windows' own set aside; the code checkout and the tool store stay on
# this side, linked from the shared home; a dry run moves nothing; --unshare
# brings a real home back and leaves the Windows copy alone; the bridge menu
# offers Hermes only once it is installed, and opening it uses the terminal.

repo_root="${REPO_ROOT:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)}"
tool="$repo_root/dotfiles/bridge/.local/bin/vivac-hermes"
bridge="$repo_root/dotfiles/bridge/.local/bin/vivac-bridge"

fail() {
	printf '%s\n' "$1" >&2
	exit 1
}
sandbox="$(mktemp -d "${TMPDIR:-/tmp}/vivac-hermes.XXXXXX")"
trap 'rm -rf -- "$sandbox"' EXIT
mkdir -p "$sandbox/bin" "$sandbox/linux/.hermes/memories" "$sandbox/linux/.hermes/skills/one" \
	"$sandbox/linux/.hermes/hermes-agent/.venv" "$sandbox/linux/.hermes/tools/uv" "$sandbox/linux/.hermes/installs/oldkey" \
	"$sandbox/win/Users/someone/.hermes/memories" "$sandbox/win/Users/someone/.hermes/bin" \
	"$sandbox/win/Users/someone/.hermes/installs/winkey" "$sandbox/win/Users/Public/.hermes"
home="$sandbox/linux/.hermes"
win="$sandbox/win/Users/someone/.hermes"
calls="$sandbox/calls"
# This side's home: the one with months of use.
printf 'side: linux\n' >"$home/config.yaml"
printf 'linux memory\n' >"$home/memories/MEMORY.md"
printf 'skill\n' >"$home/skills/one/SKILL.md"
printf 'linux sessions\n' >"$home/state.db"
printf 'code\n' >"$home/hermes-agent/.venv/python"
printf 'tool\n' >"$home/tools/uv/uv"
printf '{}\n' >"$home/installs/oldkey/facts.json"
# Windows' own, fresh from its installer: a config, a few test sessions, a
# memory of its own, and its launchers.
printf 'side: windows\n' >"$win/config.yaml"
printf 'windows sessions\n' >"$win/state.db"
printf 'windows user\n' >"$win/memories/USER.md"
printf 'MZ\n' >"$win/bin/hermes.exe"
printf '{}\n' >"$win/installs/winkey/facts.json"
printf 'windows_home=C:\\Users\\someone\\.hermes\nwindows_shared=20261109-200000\n' >"$win/vivac-hermes.conf"
# A terminal that writes down what it was asked to run; no hermes yet.
printf '#!/usr/bin/env bash\nprintf "term %%s\\n" "$*" >>"$CALLS"\n' >"$sandbox/bin/kitty"
printf '#!/usr/bin/env bash\nexit 0\n' >"$sandbox/bin/notify-send"
chmod +x "$sandbox/bin/"*

hermes() {
	PATH="$sandbox/bin:$PATH" CALLS="$calls" VIVAC_REPO="$repo_root" VIVAC_LANG=en HOME="$sandbox/linux" \
		XDG_DATA_HOME="$sandbox/linux/.local/share" VIVAC_WINDOWS_MOUNT="$sandbox/win" TERMINAL=kitty "$tool" "$@"
}

# Before anything: a home of this side only, and no Hermes installed.
out="$(hermes --status)"
[[ "$out" == *"$home, this side only"* ]] || fail "status before: $out"
[[ "$out" == *"not installed"* ]] || fail "status should say Hermes is missing: $out"
hermes --available && fail "available without hermes on PATH"
rows="$(PATH="$sandbox/bin:$PATH" VIVAC_REPO="$repo_root" VIVAC_LANG=en HOME="$sandbox/linux" "$bridge" --print)"
[[ "$rows" == *Hermes* ]] && fail "the menu offers Hermes before it is installed: $rows"

# A dry run names the moves and changes nothing.
out="$(hermes --share --dry-run)"
[[ "$out" == *"move $home/hermes-agent to $sandbox/linux/.local/share/hermes/hermes-agent"* ]] || fail "dry run plan: $out"
[[ "$out" == *"set aside Windows' own config.yaml state.db under"* ]] || fail "dry run should name the conflicts, file by file: $out"
[[ "$out" == *"nothing was moved"* ]] || fail "dry run should say so: $out"
[[ -d "$home" && ! -L "$home" ]] || fail "dry run moved the home"
[[ "$(cat "$win/config.yaml")" == 'side: windows' ]] || fail "dry run touched Windows' config"

# The real thing: the Windows home is found alone under the mount (Public is
# not a person), this side's files win, Windows' own are set aside, both
# memories survive, the per-side folders move to the store and are linked.
hermes --share --yes >"$sandbox/share.out" 2>&1 || fail "share failed: $(cat "$sandbox/share.out")"
[[ -L "$home" ]] || fail "the home is not a link"
[[ "$(readlink -- "$home")" == "$win" ]] || fail "the link points at $(readlink -- "$home")"
[[ "$(cat "$win/config.yaml")" == 'side: linux' ]] || fail "this side's config did not win"
[[ "$(cat "$win/state.db")" == 'linux sessions' ]] || fail "this side's sessions did not win"
[[ "$(cat "$win/memories/MEMORY.md")" == 'linux memory' ]] || fail "this side's memory is missing"
[[ "$(cat "$win/memories/USER.md")" == 'windows user' ]] || fail "Windows' own memory was lost"
[[ -f "$win/skills/one/SKILL.md" ]] || fail "skills did not move"
[[ -f "$win/bin/hermes.exe" ]] || fail "Windows' launchers were touched"
backup="$(find "$sandbox/win/Users/someone" -maxdepth 1 -name '.hermes.windows-before-share-*' | head -n1)"
[[ -n "$backup" ]] || fail "no backup of Windows' own files"
[[ "$(cat "$backup/config.yaml")" == 'side: windows' ]] || fail "Windows' config is not in the backup"
[[ "$(cat "$backup/state.db")" == 'windows sessions' ]] || fail "Windows' sessions are not in the backup"
store="$sandbox/linux/.local/share/hermes"
[[ -d "$store/hermes-agent" && ! -L "$store/hermes-agent" ]] || fail "the checkout did not move to the store"
[[ -f "$store/hermes-agent/.venv/python" ]] || fail "the checkout lost its venv"
[[ -L "$win/hermes-agent" && "$(readlink -- "$win/hermes-agent")" == "$store/hermes-agent" ]] || fail "the shared home does not link the checkout"
[[ -L "$win/tools" && "$(readlink -- "$win/tools")" == "$store/tools" ]] || fail "the shared home does not link the tool store"
# The dependency environments: this side's old one in the store, Windows' own
# untouched, and one link in the shared installs/ named as Hermes will name
# this side's next one (sha-256 of the checkout's resolved path, 16 digits).
[[ -f "$store/installs/oldkey/facts.json" ]] || fail "this side's environments did not move to the store"
[[ ! -e "$win/installs/oldkey" ]] || fail "this side's environments landed on the Windows partition"
[[ -f "$win/installs/winkey/facts.json" ]] || fail "Windows' own environment was touched"
key="$(printf '%s' "$(readlink -f -- "$store/hermes-agent")" | sha256sum | cut -c1-16)"
[[ -L "$win/installs/$key" && "$(readlink -- "$win/installs/$key")" == "$store/installs/$key" ]] || fail "no link for this side's next environment: $(ls -la "$win/installs")"
[[ -d "$store/installs/$key" ]] || fail "the store lacks the folder that link points at"
[[ -f "$home/config.yaml" ]] || fail "the home does not resolve through the link"
grep -q '^linux_shared=' "$win/vivac-hermes.conf" || fail "the marker does not record this side"
grep -q '^windows_home=' "$win/vivac-hermes.conf" || fail "the marker lost Windows' line"
grep -q "^windows_backup=$backup" "$win/vivac-hermes.conf" || fail "the marker does not name the backup"
[[ "$(cat "$sandbox/share.out")" == *"Shared: $home points at $win"* ]] || fail "share did not say so: $(cat "$sandbox/share.out")"

out="$(hermes --status)"
[[ "$out" == *"shared with Windows at $win"* ]] || fail "status after: $out"
[[ "$out" == *"Windows set it up on 20261109-200000"* ]] || fail "status should read Windows' line: $out"

# Sharing twice says so and changes nothing.
out="$(hermes --share --yes 2>&1)" || fail "second share failed"
[[ "$out" == *"Already shared"* ]] || fail "second share: $out"

# Once hermes exists, the menu offers it and the row opens it in the terminal.
printf '#!/usr/bin/env bash\nexit 0\n' >"$sandbox/bin/hermes"
chmod +x "$sandbox/bin/hermes"
hermes --available || fail "not available with hermes on PATH"
rows="$(PATH="$sandbox/bin:$PATH" VIVAC_REPO="$repo_root" VIVAC_LANG=en HOME="$sandbox/linux" "$bridge" --print)"
[[ "$rows" == *"Hermes (the agent)"* ]] || fail "the menu does not offer Hermes: $rows"
hermes
grep -Fxq 'term -e hermes' "$calls" || fail "opening did not use the terminal: $(cat "$calls" 2>/dev/null)"

# Several Windows homes and no folder named: refused.
mkdir -p "$sandbox/win/Users/other/.hermes"
rm -f -- "$home"
mkdir -p "$home"
printf 'side: linux\n' >"$home/config.yaml"
out="$(hermes --share --yes 2>&1)" && fail "share with two Windows homes should refuse"
[[ "$out" == *"Several Windows homes"* ]] || fail "two homes: $out"
rm -rf -- "$sandbox/win/Users/other" "$home"
ln -s -- "$win" "$home"

# Back to this side: a real home with everything, the per-side folders back
# in place, Windows' launchers and marker left to Windows, its copy intact.
out="$(hermes --unshare --dry-run)"
[[ "$out" == *"copy everything from $win into $home"* && "$out" == *"nothing was moved"* ]] || fail "unshare dry run: $out"
[[ -L "$home" ]] || fail "unshare dry run moved the home"
hermes --unshare --yes >"$sandbox/unshare.out" 2>&1 || fail "unshare failed: $(cat "$sandbox/unshare.out")"
[[ -d "$home" && ! -L "$home" ]] || fail "the home is not a real folder again"
[[ "$(cat "$home/config.yaml")" == 'side: linux' ]] || fail "the config did not come back"
[[ -f "$home/memories/USER.md" ]] || fail "Windows' memory did not come along"
[[ -d "$home/hermes-agent" && ! -L "$home/hermes-agent" && -f "$home/hermes-agent/.venv/python" ]] || fail "the checkout is not back in the home"
[[ ! -e "$store/hermes-agent" ]] || fail "the store still holds the checkout"
[[ ! -e "$home/bin" ]] || fail "Windows' launchers came along"
[[ ! -e "$home/vivac-hermes.conf" ]] || fail "the marker came along"
[[ -f "$home/installs/oldkey/facts.json" ]] || fail "this side's environments did not come back"
[[ ! -e "$home/installs/winkey" ]] || fail "Windows' environment came along"
[[ -f "$win/installs/winkey/facts.json" ]] || fail "Windows' environment was damaged"
[[ -z "$(find "$win/installs" -maxdepth 1 -type l)" ]] || fail "a link into this side's store was left in the shared installs/"
[[ -f "$win/config.yaml" && -f "$win/bin/hermes.exe" ]] || fail "the Windows copy was damaged"
[[ ! -e "$win/hermes-agent" ]] || fail "the shared home still links a checkout that left"
grep -q '^linux_shared=none$' "$win/vivac-hermes.conf" || fail "the marker still says this side shares"
[[ "$(cat "$sandbox/unshare.out")" == *"Back on this side: $home"* ]] || fail "unshare did not say so"

printf 'ok\n'
