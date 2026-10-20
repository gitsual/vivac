#!/usr/bin/env bash
# shellcheck disable=SC2016  # the bash -c programs are single-quoted on purpose
set -Eeuo pipefail

# lib/hypr-ipc.sh: a classic dispatcher goes to `hyprctl dispatch` unchanged in
# a hyprlang session and, in a Lua session, becomes the matching hl.dsp.*
# expression from a closed table. An unknown dispatcher or a malformed argument
# fails with rc 2 and never reaches the compositor, and exec_raw is never the
# way out. The mode is probed once per Hyprland instance.

repo_root="${REPO_ROOT:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)}"
lib="$repo_root/lib/hypr-ipc.sh"
stub_bin="$repo_root/tests/data/hypr-ipc/bin"
bash="$(command -v bash)"
sandbox="$(mktemp -d "${TMPDIR:-/tmp}/vivac-hypripc.XXXXXX")"
trap 'rm -rf -- "$sandbox"' EXIT

fail() {
	printf '%s\n' "$1" >&2
	exit 1
}

[[ -f "$lib" ]] || fail 'lib/hypr-ipc.sh does not exist'

# Run one helper call in a clean subshell: stub hyprctl first on PATH, a private
# runtime dir (the mode cache), and no session leaking in.
unset VIVAC_HYPR_IPC_MODE HYPRLAND_INSTANCE_SIGNATURE
export HYPR_STUB_DIR="$sandbox/stub"
export XDG_RUNTIME_DIR="$sandbox/run"
mkdir -p "$HYPR_STUB_DIR" "$XDG_RUNTIME_DIR"
reset_stub() {
	rm -rf -- "$HYPR_STUB_DIR" "$XDG_RUNTIME_DIR"
	mkdir -p "$HYPR_STUB_DIR" "$XDG_RUNTIME_DIR"
	: >"$HYPR_STUB_DIR/calls"
}
call() { # call FUNCTION ARGS...
	env PATH="$stub_bin:$PATH" bash -c 'source "$1"; shift; "$@"' _ "$lib" "$@"
}

# --- sourcing is silent and needs no hyprctl ----------------------------------------------------------------
out="$(env PATH=/nonexistent "$bash" -c 'source "$1" && type -t hypr_dispatch hypr_dispatch_expr hypr_ipc_mode' _ "$lib" 2>&1)" ||
	fail "sourcing the helper without hyprctl failed: $out"
[[ "$out" == $'function\nfunction\nfunction' ]] || fail "sourcing printed or defined the wrong things: $out"

# --- the translation table, one dispatcher at a time -------------------------------------------------------
expect_expr() { # expect_expr EXPECTED DISPATCHER ARGS...
	local want="$1" got
	shift
	got="$(call hypr_dispatch_expr "$@")" || fail "no translation for: $*"
	[[ "$got" == "$want" ]] || fail "translation of '$*': wanted $want, got $got"
}
expect_expr 'hl.dsp.window.close()' killactive
expect_expr 'hl.dsp.exit()' exit
expect_expr 'hl.dsp.window.float({ action = "toggle" })' togglefloating
expect_expr 'hl.dsp.window.fullscreen()' fullscreen
expect_expr 'hl.dsp.layout("togglesplit")' layoutmsg togglesplit
expect_expr 'hl.dsp.focus({ direction = "left" })' movefocus l
expect_expr 'hl.dsp.focus({ direction = "down" })' movefocus d
expect_expr 'hl.dsp.window.move({ direction = "right" })' movewindow r
expect_expr 'hl.dsp.window.resize({ x = -10, y = 0, relative = true })' resizeactive -10 0
expect_expr 'hl.dsp.window.resize({ x = 0, y = 10, relative = true })' resizeactive 0 10
expect_expr 'hl.dsp.focus({ workspace = 3 })' workspace 3
expect_expr 'hl.dsp.focus({ workspace = "e+1" })' workspace e+1
expect_expr 'hl.dsp.focus({ workspace = "e-1" })' workspace e-1
expect_expr 'hl.dsp.window.move({ workspace = 10 })' movetoworkspace 10
expect_expr 'hl.dsp.dpms({ action = "on" })' dpms on
expect_expr 'hl.dsp.dpms({ action = "off" })' dpms off
expect_expr 'hl.dsp.focus({ window = "address:0x5581f2a0" })' focuswindow address:0x5581f2a0
expect_expr 'hl.dsp.exec_cmd([==[kitty --hold]==])' exec kitty --hold
expect_expr 'hl.dsp.exec_cmd([==[kitty --hold /tmp/pane.sh]==])' exec -- kitty --hold /tmp/pane.sh

# --- every dispatcher the registry binds translates (none left untranslated) ---------------------------
checked=0
while IFS=$'\t' read -r _ pane type value _; do
	[[ "$pane" == hypr && "$type" == dispatch ]] || continue
	# shellcheck disable=SC2086  # the value is "dispatcher args"
	[[ "$(call hypr_dispatch_expr $value)" == hl.dsp.* ]] || fail "registry dispatcher has no hl.dsp translation: $value"
	checked=$((checked + 1))
done < <(grep -v '^#' "$repo_root/data/help-registry.tsv")
((checked >= 30)) || fail "expected to check the registry's dispatcher rows, checked $checked"

# --- quoting: a command can never close its own long bracket ------------------------------------------------
quote_roundtrip() { # the command must come back byte for byte out of the Lua string
	local command="$1" expr
	expr="$(call hypr_dispatch_expr exec "$command")" || fail "exec refused: $command"
	COMMAND="$command" EXPR="$expr" nvim -l /dev/stdin <<'LUA' || fail "the command did not survive the Lua string: $command"
local expr = os.getenv("EXPR")
local want = os.getenv("COMMAND")
local env = { hl = { dsp = { exec_cmd = function(s) return s end } } }
local chunk = assert(load("return " .. expr, "=expr", "t", env))
local got = chunk()
if got ~= want then
  io.stderr:write("got: " .. vim.inspect(got) .. "\nwant: " .. vim.inspect(want) .. "\n")
  os.exit(1)
end
LUA
}
quote_roundtrip 'echo ]] done'
quote_roundtrip 'echo ]=] and ]==] and ]===]'
quote_roundtrip "printf '%s' \"quoted\" \\ back"
quote_roundtrip $'line one\nline two'
quote_roundtrip $'\nleading newline'
quote_roundtrip 'tail ]'

# --- rc 2: unknown dispatcher or malformed argument, nothing reaches hyprctl --------------------------------
reset_stub
for bad in 'frobnicate 1' 'workspace' 'workspace foo' 'workspace 3; rm -rf x' 'movefocus x' 'dpms toggle' \
	'resizeactive 1' 'resizeactive a b' 'focuswindow 0x12' 'killactive now' 'exit 1' 'exec' 'exec --'; do
	rc=0
	# shellcheck disable=SC2086  # word splitting is the point: "dispatcher args"
	err="$(VIVAC_HYPR_IPC_MODE=lua call hypr_dispatch $bad 2>&1 >/dev/null)" || rc=$?
	((rc == 2)) || fail "'$bad' should exit 2, exited $rc"
	[[ -n "$err" ]] || fail "'$bad' failed silently"
done
rc=0
VIVAC_HYPR_IPC_MODE=lua call hypr_dispatch frobnicate 1 2>/dev/null || rc=$?
((rc == 2)) || fail 'unknown dispatcher is not rc 2'
[[ ! -s "$HYPR_STUB_DIR/calls" ]] || fail "a rejected dispatcher reached hyprctl: $(<"$HYPR_STUB_DIR/calls")"

# --- Lua mode: dispatch carries the hl.dsp expression, never the classic words ------------------------------
reset_stub
HYPR_STUB_LUA=1 HYPRLAND_INSTANCE_SIGNATURE=aaa call hypr_dispatch workspace e+1 >/dev/null || fail 'Lua-mode dispatch failed'
grep -q "^dispatch hl.dsp.focus" "$HYPR_STUB_DIR/calls" || fail "no hl.dsp dispatch in Lua mode: $(<"$HYPR_STUB_DIR/calls")"
[[ "$(<"$HYPR_STUB_DIR/last_dispatch")" == 'hl.dsp.focus({ workspace = "e+1" })' ]] || fail 'wrong expression dispatched'
grep -Eq '^dispatch (workspace|exec_raw)|exec_raw' "$HYPR_STUB_DIR/calls" && fail 'classic words or exec_raw reached the Lua compositor'

# --- hyprlang mode: exactly the classic call ------------------------------------------------------------------
reset_stub
HYPR_STUB_LUA=0 HYPRLAND_INSTANCE_SIGNATURE=bbb call hypr_dispatch workspace e+1 >/dev/null || fail 'classic dispatch failed'
[[ "$(grep -c '^dispatch' "$HYPR_STUB_DIR/calls")" == 1 ]] || fail 'classic mode: expected one dispatch'
grep -qx 'dispatch workspace e+1 ' "$HYPR_STUB_DIR/calls" || fail "classic mode did not pass the dispatcher through unchanged: $(<"$HYPR_STUB_DIR/calls")"
grep -q 'hl.dsp' "$HYPR_STUB_DIR/calls" && fail 'classic mode sent Lua'
# classic mode passes even a dispatcher the Lua table does not know
HYPR_STUB_LUA=0 HYPRLAND_INSTANCE_SIGNATURE=bbb call hypr_dispatch frobnicate 1 >/dev/null || fail 'classic passthrough refused an unknown dispatcher'

# --- the mode is probed once per instance, and keyed by it ----------------------------------------------------
reset_stub
for _ in 1 2 3; do HYPR_STUB_LUA=1 HYPRLAND_INSTANCE_SIGNATURE=inst1 call hypr_dispatch exit >/dev/null; done
[[ "$(grep -c '^eval' "$HYPR_STUB_DIR/calls")" == 1 ]] || fail "the mode probe ran more than once for one instance: $(<"$HYPR_STUB_DIR/calls")"
HYPR_STUB_LUA=0 HYPRLAND_INSTANCE_SIGNATURE=inst2 call hypr_dispatch exit >/dev/null
[[ "$(grep -c '^eval' "$HYPR_STUB_DIR/calls")" == 2 ]] || fail 'a new instance did not trigger a new probe'
[[ "$(HYPR_STUB_LUA=0 HYPRLAND_INSTANCE_SIGNATURE=inst1 call hypr_ipc_mode)" == lua ]] || fail 'the cache for inst1 was lost'
[[ "$(HYPR_STUB_LUA=1 HYPRLAND_INSTANCE_SIGNATURE=inst2 call hypr_ipc_mode)" == classic ]] || fail 'inst2 was not cached as classic'
# the override skips the probe entirely
reset_stub
[[ "$(VIVAC_HYPR_IPC_MODE=lua bash -c 'source "$1"; hypr_ipc_mode' _ "$lib")" == lua ]] || fail 'VIVAC_HYPR_IPC_MODE=lua is ignored'
[[ "$(VIVAC_HYPR_IPC_MODE=classic bash -c 'source "$1"; hypr_ipc_mode' _ "$lib")" == classic ]] || fail 'VIVAC_HYPR_IPC_MODE=classic is ignored'

# --- no hyprctl: fails fast with a message ------------------------------------------------------------------------
start=$SECONDS
rc=0
err="$(env PATH=/nonexistent "$bash" -c 'source "$1"; hypr_dispatch exit' _ "$lib" 2>&1)" || rc=$?
((rc != 0)) || fail 'hypr_dispatch succeeded with no hyprctl'
[[ -n "$err" ]] || fail 'hypr_dispatch without hyprctl printed nothing'
((SECONDS - start <= 5)) || fail 'hypr_dispatch without hyprctl hung'

printf 'hypr-ipc: closed table, safe quoting, rc 2 on unknown, per-instance mode cache, classic passthrough\n'
