#!/usr/bin/env bash
set -Eeuo pipefail

# The parity gate reads a Lua Hyprland template the way it reads the hyprlang
# one: every literal one-line hl.bind("MODS + KEY", ...) carries a
# "-- @help: <pane> <label_key>" line right above it and matches a registry
# row. A bind whose key is not a literal cannot be read without running Lua, so
# it is refused. The template under test is built from the registry itself, so
# these cases do not depend on the shipped template.

repo_root="${REPO_ROOT:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)}"
gate="$repo_root/scripts/check-help-registry.sh"
registry="$repo_root/data/help-registry.tsv"
sandbox="$(mktemp -d "${TMPDIR:-/tmp}/vivac-helplua.XXXXXX")"
trap 'rm -rf -- "$sandbox"' EXIT

fail() {
	printf '%s\n' "$1" >&2
	exit 1
}

# A complete, valid Lua template: one annotated literal bind per hypr row.
good="$sandbox/good.lua.in"
{
	printf -- '-- generated for the gate test\n'
	while IFS=$'\t' read -r id pane _ _ label; do
		[[ "$pane" == hypr ]] || continue
		printf -- '-- @help: hypr %s\nhl.bind("%s", hl.dsp.no_op())\n' "$label" "${id//+/ + }"
	done < <(grep -v '^#' "$registry")
} >"$good"

run_gate() { HELP_TEMPLATE="$1" bash "$gate" >"$sandbox/out" 2>"$sandbox/err"; }

# --- the valid template passes: a bind per row, each annotated ----------------------------------------------
run_gate "$good" || fail "gate rejected a complete Lua template: $(<"$sandbox/err")"
grep -q 'every Hyprland bind annotated and registered' "$sandbox/out" || fail 'gate did not report success on the Lua template'

# --- an unannotated bind fails and is named -----------------------------------------------------------------
cp -- "$good" "$sandbox/unannotated.lua.in"
printf 'hl.bind("SUPER + Z", hl.dsp.no_op())\n' >>"$sandbox/unannotated.lua.in"
run_gate "$sandbox/unannotated.lua.in" && fail 'gate accepted a Lua bind with no @help line'
grep -q 'SUPER+Z has no' "$sandbox/err" || fail "gate did not name the unannotated bind: $(<"$sandbox/err")"

# --- a blank line or another comment between the annotation and the bind breaks the pairing ----------------
cp -- "$good" "$sandbox/gap.lua.in"
printf -- '-- @help: hypr help.hypr.terminal\n\nhl.bind("SUPER + Y", hl.dsp.no_op())\n' >>"$sandbox/gap.lua.in"
run_gate "$sandbox/gap.lua.in" && fail 'gate accepted an annotation that is not directly above its bind'
grep -q 'SUPER+Y has no' "$sandbox/err" || fail "gate did not name the detached bind: $(<"$sandbox/err")"

# --- a non-literal key is rejected, whichever way it is built ------------------------------------------------
for shape in 'hl.bind(mainMod .. " + Q", hl.dsp.no_op())' \
	'hl.bind("SUPER + " .. key, hl.dsp.no_op())' \
	'  hl.bind("SUPER + 1", hl.dsp.no_op())' \
	'for i = 1, 3 do hl.bind("SUPER + 1", hl.dsp.no_op()) end'; do
	cp -- "$good" "$sandbox/dynamic.lua.in"
	printf -- '-- @help: hypr help.hypr.terminal\n%s\n' "$shape" >>"$sandbox/dynamic.lua.in"
	run_gate "$sandbox/dynamic.lua.in" && fail "gate accepted a non-literal bind: $shape"
	grep -q 'not a literal' "$sandbox/err" || fail "gate did not say the key is not a literal for [$shape]: $(<"$sandbox/err")"
done

# --- a bind named only in a comment is not a bind ------------------------------------------------------------
cp -- "$good" "$sandbox/comment.lua.in"
printf -- '-- hl.bind(mainMod .. " + Q", hl.dsp.no_op()) stays commented out\n' >>"$sandbox/comment.lua.in"
run_gate "$sandbox/comment.lua.in" || fail "gate read a comment as a bind: $(<"$sandbox/err")"

# --- label and registry must agree, and an orphaned registry row is caught ----------------------------------
sed 's/^-- @help: hypr help.hypr.terminal$/-- @help: hypr help.hypr.editor/' "$good" >"$sandbox/mislabel.lua.in"
run_gate "$sandbox/mislabel.lua.in" && fail 'gate accepted a label that disagrees with the registry'
grep -q 'hypr/SUPER+Return' "$sandbox/err" || fail "gate did not name the mislabelled bind: $(<"$sandbox/err")"

grep -v 'hl.bind("SUPER + M",' "$good" | grep -v -- '-- @help: hypr help.hypr.exit' >"$sandbox/orphan.lua.in"
run_gate "$sandbox/orphan.lua.in" && fail 'gate accepted a registry row for a bind the Lua template lost'
grep -q 'hypr/SUPER+M' "$sandbox/err" || fail "gate did not name the orphan row: $(<"$sandbox/err")"

printf 'help lua gate: literal binds paired with @help, non-literal keys refused, drift caught both ways\n'
