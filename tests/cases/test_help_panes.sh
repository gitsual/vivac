#!/usr/bin/env bash
set -Eeuo pipefail

# The help panes render the registry in both languages byte-for-byte as the
# goldens say; the Hyprland pane merges the live bind list and marks a bind
# the registry lacks as UNREGISTERED; and the parity gate refuses a bind added
# to the template without its help line.

repo_root="${REPO_ROOT:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)}"
pane="$repo_root/dotfiles/hypr/.config/hypr/scripts/help-pane.sh"
data="$repo_root/tests/data/help"
sandbox="$(mktemp -d "${TMPDIR:-/tmp}/vivac-help.XXXXXX")"
trap 'rm -rf -- "$sandbox"' EXIT

fail() {
	printf '%s\n' "$1" >&2
	exit 1
}
# No session leaks in: the live list comes only from the fixture when given.
render() { HYPRLAND_INSTANCE_SIGNATURE='' HELP_REPO_ROOT="$repo_root" bash "$pane" --pane "$1" --lang "$2" --plain; }

# --- goldens: F2..F5 in English and Spanish -------------------------------------------------------------
for p in browser shell editor system; do
	for lang in en es; do
		out="$(render "$p" "$lang")"
		[[ "$out" == "$(<"$data/golden/$p.$lang.txt")" ]] || {
			diff <(printf '%s\n' "$out") "$data/golden/$p.$lang.txt" >&2 || true
			fail "pane $p ($lang) differs from its golden (tests/update-golden.sh if intended)"
		}
		((5 == $(wc -l <<<"$out"))) || fail "pane $p ($lang): expected 5 rows"
	done
done
grep -q $'^Ctrl+R\tBuscar' "$data/golden/shell.es.txt" || fail 'the Spanish golden is not Spanish'

# --- the Hyprland pane: registry rows, then live binds the registry lacks, marked -----------------------
out="$(HELP_BINDS_JSON="$data/binds.json" render hypr en)"
grep -q $'^SUPER+Return\tOpen a terminal$' <<<"$out" || fail 'hypr pane: registered bind missing or mislabelled'
grep -q $'^SUPER+CTRL+Q\tUNREGISTERED$' <<<"$out" || fail "hypr pane: the overlay's bind is not marked UNREGISTERED: $out"
grep -c 'UNREGISTERED' <<<"$out" | grep -qx 1 || fail 'hypr pane: registered live binds were marked too'
registry_rows="$(grep -c $'\thypr\t' "$repo_root/data/help-registry.tsv")"
((registry_rows == $(grep -Ec '^bind[lmer]* = ' "$repo_root/templates/hypr/.config/hypr/hyprland.conf.in"))) || fail 'registry hypr rows and template binds differ in count'
((registry_rows == $(grep -Ec '^hl\.bind\("' "$repo_root/templates/hypr/.config/hypr/hyprland.lua.in"))) || fail 'registry hypr rows and Lua template binds differ in count'
# Without a live list the pane is the registry alone, never empty.
out="$(render hypr es)"
((registry_rows == $(wc -l <<<"$out"))) || fail 'hypr pane without a session: expected one row per registry entry'
grep -q UNREGISTERED <<<"$out" && fail 'hypr pane without a session marked something UNREGISTERED'

# --- the gate catches a bind added without its help line ----------------------------------------------------
copy="$sandbox/template.conf.in"
cp -- "$repo_root/templates/hypr/.config/hypr/hyprland.conf.in" "$copy"
printf 'bind = SUPER, Z, exec, something-new\n' >>"$copy"
if HELP_TEMPLATE="$copy" bash "$repo_root/scripts/check-help-registry.sh" >/dev/null 2>"$sandbox/err"; then
	fail 'gate accepted a bind with no help line'
fi
grep -q 'SUPER+Z has no' "$sandbox/err" || fail "gate did not name the bind: $(<"$sandbox/err")"
# ...and a help line whose key vanished from the template.
copy2="$sandbox/template2.conf.in"
grep -v '^bind = SUPER, M, exit' "$repo_root/templates/hypr/.config/hypr/hyprland.conf.in" >"$copy2"
if HELP_TEMPLATE="$copy2" bash "$repo_root/scripts/check-help-registry.sh" >/dev/null 2>"$sandbox/err"; then
	fail 'gate accepted a registry row for a bind the template lost'
fi
grep -q 'hypr/SUPER+M' "$sandbox/err" || fail "gate did not name the orphan row: $(<"$sandbox/err")"

printf 'help panes: goldens in en and es, live merge marks UNREGISTERED, gate catches drift both ways\n'
