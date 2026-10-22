#!/usr/bin/env bash
set -Eeuo pipefail

# vivac's nvim config loads an optional owner overlay, lua/local/init.lua, as
# its very last step, guarded: a missing overlay is silent, a broken one never
# stops the editor. vivac itself never ships that file.
#
# The full init.lua needs the plugin manager and network, so the hook is
# exercised on its own: the last statement of init.lua is run headless with the
# config directory on the runtime path, with and without the overlay.

repo_root="${REPO_ROOT:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)}"
conf="$repo_root/dotfiles/nvim/.config/nvim"
init="$conf/init.lua"
sandbox="$(mktemp -d "${TMPDIR:-/tmp}/vivac-nvim-overlay.XXXXXX")"
trap 'rm -rf -- "$sandbox"' EXIT

fail() {
	printf '%s\n' "$1" >&2
	exit 1
}

nvim -l /dev/stdin "$init" <<'LUA' || fail 'init.lua does not parse'
assert(loadfile(_G.arg[1]))
LUA
[[ ! -e "$conf/lua/local" && ! -e "$conf/lua/local.lua" ]] || fail 'vivac ships an nvim overlay; it belongs to the owner'

# The hook is the last code line of init.lua.
hook="$(grep -v -e '^[[:space:]]*$' -e '^[[:space:]]*--' "$init" | tail -n 1)"
[[ "$hook" == 'pcall(require, "local")' ]] || fail "the last statement of init.lua is not the guarded overlay load: $hook"

# run_hook CONFIG_DIR — run that statement with CONFIG_DIR/lua on the path.
run_hook() {
	local dir="$1"
	printf 'package.path = "%s/lua/?.lua;%s/lua/?/init.lua;" .. package.path\n%s\nio.write(package.loaded["local"] and "loaded" or "absent")\n' \
		"$dir" "$dir" "$hook" >"$sandbox/hook.lua"
	nvim --headless -u NONE -l "$sandbox/hook.lua" 2>"$sandbox/err" || fail "the hook failed: $(<"$sandbox/err")"
	[[ ! -s "$sandbox/err" ]] || fail "the hook wrote to stderr: $(<"$sandbox/err")"
}

# --- no overlay: no error, nothing loaded ---------------------------------------------------------------------------
mkdir -p -- "$sandbox/none/lua"
out="$(run_hook "$sandbox/none")"
[[ "$out" == absent ]] || fail "expected no overlay, got: $out"

# --- an overlay: loaded ---------------------------------------------------------------------------------------------
mkdir -p -- "$sandbox/with/lua/local"
printf 'return { owner = true }\n' >"$sandbox/with/lua/local/init.lua"
out="$(run_hook "$sandbox/with")"
[[ "$out" == loaded ]] || fail "the overlay was not loaded: $out"

# --- a broken overlay: the editor still starts ----------------------------------------------------------------------
mkdir -p -- "$sandbox/broken/lua/local"
printf 'error("owner mistake")\n' >"$sandbox/broken/lua/local/init.lua"
run_hook "$sandbox/broken" >/dev/null
printf 'this is = not lua (\n' >"$sandbox/broken/lua/local/init.lua"
run_hook "$sandbox/broken" >/dev/null

printf 'nvim overlay: guarded hook is the last statement; absent, present and broken overlays all start\n'
