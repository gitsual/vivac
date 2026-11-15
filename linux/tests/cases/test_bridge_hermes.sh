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
	"$sandbox/linux/.hermes/hermes-agent/.venv" "$sandbox/linux/.hermes/tools/uv" "$sandbox/linux/.hermes/lsp/bin" "$sandbox/linux/.hermes/cache/uv" "$sandbox/linux/.hermes/installs/oldkey" \
	"$sandbox/win/Users/someone/.hermes/memories" "$sandbox/win/Users/someone/.hermes/bin" \
	"$sandbox/win/Users/someone/.hermes/installs/winkey" "$sandbox/win/Users/someone/.hermes/cache/uv" "$sandbox/systemd" "$sandbox/win/Users/Public/.hermes"
home="$sandbox/linux/.hermes"
win="$sandbox/win/Users/someone/.hermes"
calls="$sandbox/calls"
# The host may have Hermes installed: the tool sees only the fakes and the system.
system_path=/usr/local/bin:/usr/bin:/bin
# This side's home: the one with months of use.
printf 'side: linux\n' >"$home/config.yaml"
printf 'linux memory\n' >"$home/memories/MEMORY.md"
printf 'skill\n' >"$home/skills/one/SKILL.md"
printf 'linux sessions\n' >"$home/state.db"
printf 'code\n' >"$home/hermes-agent/.venv/python"
# The checkout's venv: its launchers carry the checkout's path, so a move must
# have Hermes write them again (a fake that writes down how it was asked).
mkdir -p "$home/hermes-agent/venv/bin"
printf '#!/usr/bin/env bash\nprintf "venv-python %%s\\n" "$*" >>"$CALLS"\n' >"$home/hermes-agent/venv/bin/python"
chmod +x "$home/hermes-agent/venv/bin/python"
# A gateway service Hermes wrote for the checkout's old path.
mkdir -p "$sandbox/linux/.config/systemd/user"
printf '[Service]\nExecStart=/old/path/hermes gateway run\n' >"$sandbox/linux/.config/systemd/user/hermes-gateway.service"
printf 'tool\n' >"$home/tools/uv/uv"
mkdir -p "$home/bin" && printf 'elf\n' >"$home/bin/tirith"
printf 'language server\n' >"$home/lsp/bin/server"
# Caches are per system: uv's entries are symlinks here, path files there.
printf 'linux wheel\n' >"$home/cache/uv/linux-entry"
printf '{}\n' >"$home/installs/oldkey/facts.json"
# Windows' own, fresh from its installer: a config, a few test sessions, a
# memory of its own, and its launchers.
printf 'side: windows\n' >"$win/config.yaml"
printf 'windows sessions\n' >"$win/state.db"
# Windows' journal of its own sessions; this side has none (checkpointed).
printf 'windows journal\n' >"$win/state.db-wal"
printf 'windows user\n' >"$win/memories/USER.md"
printf 'MZ\n' >"$win/bin/hermes.exe"
printf 'C:\\\\cache\\\\archive\n' >"$win/cache/uv/windows-entry"
printf '{}\n' >"$win/installs/winkey/facts.json"
printf 'windows_home=C:\\Users\\someone\\.hermes\nwindows_shared=20261109-200000\n' >"$win/vivac-hermes.conf"
# A terminal that writes down what it was asked to run; no hermes yet.
printf '#!/usr/bin/env bash\nprintf "term %%s\\n" "$*" >>"$CALLS"\n' >"$sandbox/bin/kitty"
printf '#!/usr/bin/env bash\nexit 0\n' >"$sandbox/bin/notify-send"
# No Hermes of the host counts: pgrep finds nothing here.
printf '#!/usr/bin/env bash\nexit 1\n' >"$sandbox/bin/pgrep"
# sudo writes down and runs; systemctl only writes down.
printf '#!/usr/bin/env bash\nprintf "sudo %%s\\n" "$*" >>"$CALLS"\n[[ -z "${SUDO_REFUSES:-}" ]] || exit 1\nexec "$@"\n' >"$sandbox/bin/sudo"
printf '#!/usr/bin/env bash\nprintf "systemctl %%s\\n" "$*" >>"$CALLS"\n' >"$sandbox/bin/systemctl"
chmod +x "$sandbox/bin/"*

hermes() {
	PATH="$sandbox/bin:$system_path" CALLS="$calls" VIVAC_REPO="$repo_root" VIVAC_LANG=en HOME="$sandbox/linux" \
		XDG_DATA_HOME="$sandbox/linux/.local/share" VIVAC_WINDOWS_MOUNT="$sandbox/win" VIVAC_SYSTEMD_DIR="$sandbox/systemd" \
		TERMINAL=kitty "$tool" "$@"
}

# Before anything: a home of this side only, and no Hermes installed.
out="$(hermes --status)"
[[ "$out" == *"$home, this side only"* ]] || fail "status before: $out"
[[ "$out" == *"not installed"* ]] || fail "status should say Hermes is missing: $out"
hermes --available && fail "available without hermes on PATH"
rows="$(PATH="$sandbox/bin:$system_path" VIVAC_REPO="$repo_root" VIVAC_LANG=en HOME="$sandbox/linux" "$bridge" --print)"
[[ "$rows" == *Hermes* ]] && fail "the menu offers Hermes before it is installed: $rows"

# A dry run names the moves and changes nothing.
out="$(hermes --share --dry-run)"
[[ "$out" == *"move $home/hermes-agent to $sandbox/linux/.local/share/hermes/hermes-agent"* ]] || fail "dry run plan: $out"
[[ "$out" == *"set aside Windows' own config.yaml state.db state.db-wal under"* ]] || fail "dry run should name the conflicts, file by file: $out"
[[ "$out" == *"nothing was moved"* ]] || fail "dry run should say so: $out"
[[ "$out" == *"move $home/cache to $sandbox/linux/.local/share/hermes/cache"* ]] || fail "dry run should move the cache aside: $out"
for name in hermes-agent tools lsp cache; do
	[[ "$out" == *"mount $sandbox/linux/.local/share/hermes/$name over $win/$name"* ]] || fail "dry run should mount $name: $out"
done
[[ -z "$(ls -A "$sandbox/systemd")" ]] || fail 'dry run wrote a unit'
[[ -d "$home" && ! -L "$home" ]] || fail "dry run moved the home"
[[ "$(cat "$win/config.yaml")" == 'side: windows' ]] || fail "dry run touched Windows' config"

# A mount that cannot be made (sudo refuses): the cache goes back, nothing moved.
SUDO_REFUSES=1 hermes --share --yes >"$sandbox/refused.out" 2>&1 && fail 'share succeeded without its mount'
[[ -d "$home" && ! -L "$home" && -f "$home/cache/uv/linux-entry" ]] || fail 'a refused mount left the home changed'
[[ ! -e "$sandbox/linux/.local/share/hermes/cache" && -z "$(ls -A "$sandbox/systemd")" ]] || fail 'a refused mount left something behind'
[[ "$(cat "$win/config.yaml")" == 'side: windows' ]] || fail "a refused mount touched Windows' files"
for name in hermes-agent tools lsp installs/"$(printf '%s' "$(readlink -f -- "$win")/hermes-agent" | sha256sum | cut -c1-16)"; do
	[[ ! -e "$win/$name" ]] || fail "a refused mount left an empty $name on the Windows partition"
done
[[ -f "$home/installs/oldkey/facts.json" && -f "$home/hermes-agent/.venv/python" ]] || fail 'a refused mount did not bring the folders back' 
[[ "$(cat "$sandbox/refused.out")" == *"nothing was moved"* ]] || fail "the refusal did not say so: $(cat "$sandbox/refused.out")"
: >"$calls"

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
[[ "$(cat "$backup/state.db-wal")" == 'windows journal' ]] || fail "Windows' journal is not in the backup beside its database"
store="$sandbox/linux/.local/share/hermes"
[[ -d "$store/hermes-agent" && ! -L "$store/hermes-agent" ]] || fail "the checkout did not move to the store"
[[ -f "$store/hermes-agent/.venv/python" ]] || fail "the checkout lost its venv"
# No link of this side's in the Windows partition (Windows can neither follow
# nor copy one): each per-side folder is a real folder there, with this side's
# own mounted over it from the store, on this side only.
[[ -f "$store/lsp/bin/server" ]] || fail "the language servers did not move to the store"
[[ -f "$store/tools/uv/uv" ]] || fail "the tool store did not move to the store"
[[ -z "$(find "$win" -type l)" ]] || fail "links of this side's landed on the Windows partition: $(find "$win" -type l)"
mounted_at() { # mounted_at SRC WHERE — a bind unit for it, enabled
	local unit
	unit="$(systemd-escape --path --suffix=mount "$2")"
	[[ -f "$sandbox/systemd/$unit" ]] || fail "no mount unit for $2: $(ls "$sandbox/systemd")"
	grep -Fxq "What=$(readlink -f -- "$1")" "$sandbox/systemd/$unit" || fail "$unit mounts the wrong source: $(cat "$sandbox/systemd/$unit")"
	grep -Fxq "Where=$2" "$sandbox/systemd/$unit" || fail "$unit mounts on the wrong place"
	grep -Fxq 'Options=bind' "$sandbox/systemd/$unit" || fail "$unit is not a bind mount"
	grep -Fxq "systemctl enable --now $unit" "$calls" || fail "$unit was not enabled: $(cat "$calls")"
	[[ -d "$2" && ! -L "$2" ]] || fail "$2 is not a real folder"
}
for name in hermes-agent tools lsp cache; do mounted_at "$store/$name" "$win/$name"; done
# The cache: this side's in the store, mounted over Windows' own, which stays
# where it is, not set aside and not mixed with this side's.
[[ -f "$store/cache/uv/linux-entry" ]] || fail "this side's cache did not move to the store"
[[ -f "$win/cache/uv/windows-entry" && ! -e "$win/cache/uv/linux-entry" ]] || fail "Windows' cache was not left alone: $(ls -R "$win/cache")"
[[ -f "$win/bin/tirith" && -f "$win/bin/hermes.exe" ]] || fail "the launchers did not join file by file"
# A database travels with its journal: Windows' journal never meets this side's
# database (SQLite would replay it into the wrong file).
[[ ! -e "$win/state.db-wal" ]] || fail "Windows' journal was left beside this side's database"
# The dependency environments: this side's old one in the store, Windows' own
# untouched, and one link in the shared installs/ named as Hermes will name
# this side's next one (sha-256 of the checkout's resolved path, 16 digits).
[[ -f "$store/installs/oldkey/facts.json" ]] || fail "this side's environments did not move to the store"
[[ ! -e "$win/installs/oldkey" ]] || fail "this side's environments landed on the Windows partition"
[[ -f "$win/installs/winkey/facts.json" ]] || fail "Windows' own environment was touched"
key="$(printf '%s' "$(readlink -f -- "$win")/hermes-agent" | sha256sum | cut -c1-16)"
[[ -d "$store/installs/$key" ]] || fail "the store lacks this side's next environment"
mounted_at "$store/installs/$key" "$win/installs/$key"
[[ -f "$home/config.yaml" ]] || fail "the home does not resolve through the link"
grep -q '^linux_shared=' "$win/vivac-hermes.conf" || fail "the marker does not record this side"
grep -q '^windows_home=' "$win/vivac-hermes.conf" || fail "the marker lost Windows' line"
grep -q "^windows_backup=$backup" "$win/vivac-hermes.conf" || fail "the marker does not name the backup"
grep -Fxq "venv-python -m hermes_cli.venv_sync --project-root $home/hermes-agent" "$calls" ||
	fail "Hermes was not asked to rewrite its launchers for the shared place: $(cat "$calls")"
grep -Fxq "venv-python -m hermes_cli.main gateway install --force --no-start-now --start-on-login" "$calls" ||
	fail "Hermes was not asked to rewrite its gateway service for the shared place: $(cat "$calls")"
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
rows="$(PATH="$sandbox/bin:$system_path" VIVAC_REPO="$repo_root" VIVAC_LANG=en HOME="$sandbox/linux" "$bridge" --print)"
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
: >"$calls"
hermes --unshare --yes >"$sandbox/unshare.out" 2>&1 || fail "unshare failed: $(cat "$sandbox/unshare.out")"
[[ -d "$home" && ! -L "$home" ]] || fail "the home is not a real folder again"
[[ "$(cat "$home/config.yaml")" == 'side: linux' ]] || fail "the config did not come back"
[[ -f "$home/memories/USER.md" ]] || fail "Windows' memory did not come along"
[[ -d "$home/hermes-agent" && ! -L "$home/hermes-agent" && -f "$home/hermes-agent/.venv/python" ]] || fail "the checkout is not back in the home"
[[ ! -e "$store/hermes-agent" ]] || fail "the store still holds the checkout"
[[ -f "$home/lsp/bin/server" && ! -L "$home/lsp" ]] || fail "the language servers are not back in the home"
[[ -f "$home/cache/uv/linux-entry" && ! -e "$home/cache/uv/windows-entry" ]] || fail "this side's cache did not come back alone"
grep -Fxq "systemctl disable --now $(systemd-escape --path --suffix=mount "$win/cache")" "$calls" || fail "the mount was not stopped: $(cat "$calls")"
[[ -f "$win/cache/uv/windows-entry" ]] || fail "Windows' cache was damaged by the unshare"
[[ -f "$home/bin/tirith" && ! -e "$home/bin/hermes.exe" ]] || fail "this side's launchers did not come back, or Windows' came along"
[[ ! -e "$home/vivac-hermes.conf" ]] || fail "the marker came along"
[[ -f "$home/installs/oldkey/facts.json" ]] || fail "this side's environments did not come back"
[[ ! -e "$home/installs/winkey" ]] || fail "Windows' environment came along"
[[ -f "$win/installs/winkey/facts.json" ]] || fail "Windows' environment was damaged"
[[ ! -e "$win/installs/$key" ]] || fail "the folder for this side's environment was left in the shared installs/"
[[ -z "$(ls -A "$sandbox/systemd")" ]] || fail "mount units were left behind: $(ls "$sandbox/systemd")"
[[ -f "$win/config.yaml" && -f "$win/bin/hermes.exe" ]] || fail "the Windows copy was damaged"
for name in hermes-agent tools lsp; do
	[[ ! -e "$win/$name" ]] || fail "the empty $name folder made for the mount was left on the Windows partition"
done
grep -q '^linux_shared=none$' "$win/vivac-hermes.conf" || fail "the marker still says this side shares"
grep -Fxq "venv-python -m hermes_cli.venv_sync --project-root $home/hermes-agent" "$calls" ||
	fail "Hermes was not asked to rewrite its launchers back home: $(cat "$calls")"
[[ "$(cat "$sandbox/unshare.out")" == *"Back on this side: $home"* ]] || fail "unshare did not say so"

printf 'ok\n'
