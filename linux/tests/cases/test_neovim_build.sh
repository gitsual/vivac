#!/usr/bin/env bash
set -Eeuo pipefail

# A plugin that compiles itself has to be allowed to finish.
#
# avante.nvim builds four Rust crates from source. lazy.nvim spawns that build
# with the timeout from `git.timeout` -- manage/process.lua falls back to it
# for every process, not only git -- and the default two minutes is less than
# the build takes on a four-core machine. The kill would be survivable if the
# Makefile installed its libraries atomically, but it uses `cp`, which
# truncates the destination before rewriting it. What is left is a shared
# object shorter than its own headers claim, and the next `ffi.load` maps a
# page past its end: SIGBUS, with a backtrace that names dlopen and says
# nothing whatsoever about a build having been cut short.
#
# Neither half of that is visible from the repository checks -- the crash only
# happens in a real install -- so both are pinned here by the shape of the
# configuration instead.

repo_root="${REPO_ROOT:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)}"
lazy_config="$repo_root/dotfiles/nvim/.config/nvim/lua/configs/lazy.lua"
plugins="$repo_root/dotfiles/nvim/.config/nvim/lua/plugins/init.lua"
harness="$repo_root/scripts/test-neovim.sh"

fail() {
	printf '%s\n' "$1" >&2
	exit 1
}

for file in "$lazy_config" "$plugins" "$harness"; do
	[[ -f "$file" ]] || fail "$file is missing"
done

# Only a plugin that compiles needs the longer rope. If none does any more,
# this whole case is pinning a problem the configuration no longer has.
grep -Eq '^[[:space:]]*build = ' "$plugins" ||
	fail 'no plugin builds anything; this test guards a timeout nothing needs'

timeout="$(sed -nE 's/^[[:space:]]*git = \{ timeout = ([0-9]+) \},?[[:space:]]*$/\1/p' "$lazy_config")"
[[ -n "$timeout" ]] ||
	fail 'lazy.nvim has no explicit process timeout, so a source build is killed at the default two minutes'
((timeout > 120)) ||
	fail "lazy.nvim allows a build ${timeout}s, which is not more than the default it is there to raise"

# And the retry has to retry something. Every attempt shares one sandbox, so a
# half-written library from the first one is still there for the second: make
# finds the file, rebuilds nothing, and the attempt dies on load before it
# reaches any work. Compiled artefacts go; the cargo target directories stay,
# so the retry relinks rather than starting from nothing.
retry_block="$(sed -n '/^for sync_attempt in/,/^done$/p' "$harness")"
grep -Fq "name '*.so' -type f -delete" <<<"$retry_block" ||
	fail 'a failed attempt leaves its compiled artefacts behind, so the retries inherit the crash'
grep -Fq 'rm -rf' <<<"$retry_block" &&
	fail 'the retry throws the whole plugin tree away; the next attempt then hits the same timeout'

printf 'neovim: source builds get %ss and a failed attempt drops what it half-built\n' "$timeout"
