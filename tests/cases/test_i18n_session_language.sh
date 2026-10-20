#!/usr/bin/env bash
set -Eeuo pipefail

# One place decides which language the programs speak: VIVAC_LANG for a single
# run, then the `language` setting, then the session LANG, then English.

repo_root="${REPO_ROOT:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)}"
# shellcheck source=lib/kv.sh
source "$repo_root/lib/kv.sh"
# shellcheck source=lib/i18n.sh
source "$repo_root/lib/i18n.sh"

fail() {
	printf '%s\n' "$1" >&2
	exit 1
}
sandbox="$(mktemp -d "${TMPDIR:-/tmp}/vivac-lang.XXXXXX")"
trap 'rm -rf -- "$sandbox"' EXIT
settings="$sandbox/settings"

# shellcheck disable=SC2016  # the script is expanded by the inner bash
pick() { env -u VIVAC_LANG -u LANG "$@" bash -c 'source "$1/lib/kv.sh"; source "$1/lib/i18n.sh"; i18n_session_language "$2"' _ "$repo_root" "$settings"; }
expect() {
	local want="$1" got
	shift
	got="$(pick "$@")" || fail "i18n_session_language failed for: $*"
	[[ "$got" == "$want" ]] || fail "expected $want, got $got for: $* (settings: $(tr '\n' ' ' <"$settings" 2>/dev/null))"
}

rm -f "$settings"
expect en
expect es LANG=es_ES.UTF-8
expect en LANG=C
expect en LANG=POSIX
expect en 'LANG=../../x'
expect en VIVAC_LANG=C LANG=es_ES.UTF-8
printf 'language=auto\n' >"$settings"
expect es LANG=es_ES.UTF-8
printf 'language=en\n' >"$settings"
expect en LANG=es_ES.UTF-8
expect es LANG=es_ES.UTF-8 VIVAC_LANG=es
printf 'language=es\n' >"$settings"
expect es LANG=en_US.UTF-8
expect en LANG=es_ES.UTF-8 VIVAC_LANG=en
# A garbled setting is never fatal and never shadows the session language.
printf 'language=../etc\n' >"$settings"
expect fr LANG=fr_FR.UTF-8
printf 'language=Es;x\n' >"$settings"
expect en
printf '\x00\xff\nnope\n' >"$settings"
expect de LANG=de_DE.UTF-8

# The callers use it instead of their own copy of the order.
for caller in scripts/bootstrap.sh scripts/gpu-setup.sh dotfiles/welcome/.local/bin/vivac-welcome; do
	grep -q 'i18n_session_language' "$repo_root/$caller" || fail "$caller still resolves the language itself"
	grep -q 'VIVAC_LANG:-' "$repo_root/$caller" && fail "$caller keeps its own VIVAC_LANG:-LANG order"
done
printf 'i18n session language: VIVAC_LANG > language > LANG > en\n'
