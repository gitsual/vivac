#!/usr/bin/env bash
# shellcheck disable=SC2016  # literal $(...) and backticks are the point of this test
set -Eeuo pipefail

# A description is text. A translation that looks like a command is printed
# character for character and nothing runs: no eval anywhere in the help
# path, no i18n value in a command position.

repo_root="${REPO_ROOT:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)}"
pane="$repo_root/dotfiles/hypr/.config/hypr/scripts/help-pane.sh"
sandbox="$(mktemp -d "${TMPDIR:-/tmp}/vivac-helpexec.XXXXXX")"
trap 'rm -rf -- "$sandbox"' EXIT

fail() {
	printf '%s\n' "$1" >&2
	exit 1
}

grep -En '(^|[^a-z_])eval[ (]' "$repo_root/lib/help.sh" "$pane" "$repo_root/scripts/check-help-registry.sh" && fail 'eval in the help path'

# A hostile table and registry: the description is a command substitution and
# the id carries a semicolon. Both must come out as the literal characters.
mkdir -p -- "$sandbox/i18n"
marker="$sandbox/executed"
printf '# keys: 1\nhelp.shell.evil=$(touch %s); `touch %s`\n' "$marker" "$marker" >"$sandbox/i18n/en.conf"
printf 'Ctrl+X; touch %s\tshell\tdoc\tdocs/keys.md#shell\thelp.shell.evil\n' "$marker" >"$sandbox/registry.tsv"
out="$(HELP_REPO_ROOT="$repo_root" I18N_DIR="$sandbox/i18n" HELP_REGISTRY="$sandbox/registry.tsv" bash "$pane" --pane shell --lang en --plain)"
[[ ! -e "$marker" ]] || fail 'a description was executed'
[[ "$out" == *'$(touch '* && "$out" == *'`touch '* ]] || fail "the hostile description was not printed literally: $out"
[[ "$out" == 'Ctrl+X; touch '* ]] || fail "the id was not printed literally: $out"

# The interactive branch only ever acts on the registry's action columns.
grep -Fq 'HELP_VALUE["$key"]' "$pane" || fail 'the pane does not act through the registry value'
grep -E 'hyprctl.*I18N|xdg-open.*I18N|hyprctl.*label|xdg-open.*label' "$pane" && fail 'a description reaches a command'

printf 'help: nothing in a description is executed; actions come from the registry only\n'
