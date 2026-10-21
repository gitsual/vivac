#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
sandbox="$(mktemp -d "${TMPDIR:-/tmp}/vivac-nvim.XXXXXX")"
keep=false
[[ "${KEEP_TEST_SANDBOX:-0}" == 1 ]] && keep=true
cleanup() {
	if $keep; then
		printf 'Neovim test sandbox kept at %s\n' "$sandbox"
		return
	fi
	# A plugin build is spawned asynchronously and can outlive the editor that
	# started it: a `make` or a `cargo` still writing into lazy/ turns a single
	# removal into "Directory not empty", and the trap then fails a run whose
	# test had already passed. Give the build a moment to finish instead.
	local attempt
	for attempt in 1 2 3 4 5; do
		rm -rf -- "$sandbox" 2>/dev/null && return
		sleep "$attempt"
	done
	printf 'Neovim test sandbox could not be removed; left at %s\n' "$sandbox" >&2
}
trap cleanup EXIT

config_home="$sandbox/config"
data_home="$sandbox/data"
state_home="$sandbox/state"
cache_home="$sandbox/cache"
mkdir -p -- "$config_home" "$data_home" "$state_home" "$cache_home"
cp -a -- "$repo_root/dotfiles/nvim/.config/nvim" "$config_home/nvim"
source_lock="$repo_root/dotfiles/nvim/.config/nvim/lazy-lock.json"
source_lock_hash="$(sha256sum "$source_lock" | cut -d' ' -f1)"

run_nvim() {
	HOME="$sandbox/home" \
	XDG_CONFIG_HOME="$config_home" \
	XDG_DATA_HOME="$data_home" \
	XDG_STATE_HOME="$state_home" \
	XDG_CACHE_HOME="$cache_home" \
	AVANTE_PROVIDER=codexcli \
	nvim --headless "$@"
}

sync_log="$sandbox/lazy-sync.log"
startup_log="$sandbox/startup.log"
error_pattern='(^|[^[:alpha:]])(error|failed|fatal|E[0-9]{3}:)|HTTP 504|codeberg\.org'
sync_ok=false
sync_attempt=0
for sync_attempt in 1 2 3; do
	if run_nvim '+Lazy! sync' +qa! >"$sync_log" 2>&1 && ! grep -Eiq "$error_pattern" "$sync_log"; then
		sync_ok=true
		break
	fi
	mv -- "$sync_log" "$sandbox/lazy-sync.attempt-$sync_attempt.log"
	# Every attempt reuses this sandbox, which is what makes the retry cheap --
	# and what made it useless. A build killed part way through leaves a
	# truncated shared library behind, `make` sees the file and rebuilds
	# nothing, and the next attempt maps the same corpse and dies on it before
	# it reaches any work: attempt 1 failed a thousand log lines in, attempts 2
	# and 3 failed after two hundred. Drop the compiled artefacts so a retry
	# retries the build; the cargo target directories survive, so it relinks
	# rather than starting over.
	find "$data_home/nvim/lazy" -name '*.so' -type f -delete 2>/dev/null || true
	sleep "$((sync_attempt * 5))"
done
if ! $sync_ok; then
	printf '%s\n' 'Neovim sync failed after 3 bounded attempts:' >&2
	grep -Ein "$error_pattern" "$sandbox"/lazy-sync.attempt-*.log >&2 || true
	exit 1
fi

run_nvim \
	-c 'lua local function loaded(name) local ok, value = pcall(require, name); assert(ok, value) end; loaded("nvchad"); loaded("nvim-treesitter.configs"); loaded("avante"); loaded("cmp"); local plugin = require("lazy.core.config").plugins["cmp-async-path"]; assert(plugin and vim.uv.fs_stat(plugin.dir), "cmp-async-path is not installed")' \
	-c 'qa!' >"$startup_log" 2>&1

if grep -Eiq "$error_pattern" "$sync_log" "$startup_log"; then
	printf '%s\n' 'Neovim logs contain an error marker:' >&2
	grep -Ein "$error_pattern" "$sync_log" "$startup_log" >&2
	exit 1
fi

# The editor's colours are rendered from the palette like every other themed
# surface, and "it started without erroring" does not prove that arrived: a
# base46 theme that fails to resolve falls back rather than shouting. So ask
# the running editor what colour it actually painted, and compare it with the
# palette this tree ships.
theme_bg="$(sed -nE 's/^TERMINAL_BG=(.*)$/\1/p' "$repo_root/data/theme.conf")"
[[ -n "$theme_bg" ]] || {
	printf 'the palette carries no TERMINAL_BG to check the editor against\n' >&2
	exit 1
}
# The answer goes to its own file rather than to stdout: a headless run still
# prints plugin chatter (treesitter announcing a download, for one), and that
# noise arrives glued to the hex.
probe="$sandbox/normal-bg.txt"
run_nvim \
	-c "lua local hl = vim.api.nvim_get_hl(0, { name = 'Normal' }); assert(hl.bg, 'Normal has no background: no theme was applied'); local out = assert(io.open('$probe', 'w')); out:write(string.format('%06X', hl.bg)); out:close()" \
	-c 'qa!' >"$sandbox/normal-bg.log" 2>&1
[[ -s "$probe" ]] || {
	printf 'the editor never reported a Normal background:\n%s\n' "$(tail -5 "$sandbox/normal-bg.log")" >&2
	exit 1
}
painted="$(tr -d '[:space:]' <"$probe")"
[[ "$painted" == "$theme_bg" ]] || {
	printf 'the editor painted Normal on %s, but the palette says %s\n' "$painted" "$theme_bg" >&2
	exit 1
}

origin="$(git -C "$data_home/nvim/lazy/cmp-async-path" remote get-url origin)"
[[ "$origin" == 'https://github.com/FelipeLema/cmp-async-path.git' ]]
python - "$config_home/nvim/lazy-lock.json" <<'PY'
import json
import sys
with open(sys.argv[1], encoding="utf-8") as stream:
    lock = json.load(stream)
assert "cmp-async-path" in lock, "cmp-async-path missing from lockfile"
assert "cmp-path" not in lock, "obsolete cmp-path still present in lockfile"
PY
[[ "$(sha256sum "$source_lock" | cut -d' ' -f1)" == "$source_lock_hash" ]]

printf 'Neovim clean install: passed in %d sync attempt(s); Normal painted on #%s from the palette; cmp-async-path origin=%s\n' "$sync_attempt" "$painted" "$origin"
