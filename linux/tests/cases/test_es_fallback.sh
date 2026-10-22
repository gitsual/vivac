#!/usr/bin/env bash
set -Eeuo pipefail

# The Spanish table is complete, and stays so because the coverage gate says
# so. This case removes one key on purpose to show what a gap looks like end
# to end: the English text, visibly marked, and a red gate. It then drives
# bootstrap.sh in both languages against a fixture machine.

repo_root="${REPO_ROOT:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)}"
# shellcheck source=lib/kv.sh
source "$repo_root/lib/kv.sh"
# shellcheck source=lib/i18n.sh
source "$repo_root/lib/i18n.sh"

sandbox="$(mktemp -d "${TMPDIR:-/tmp}/vivac-es.XXXXXX")"
trap 'rm -rf -- "$sandbox"' EXIT
cp -r -- "$repo_root/i18n" "$sandbox/i18n"

fail() {
	printf '%s\n' "$1" >&2
	exit 1
}
gate() { I18N_DIR="$sandbox/i18n" I18N_DATA_DIR="$repo_root/data" bash "$repo_root/scripts/check-i18n-coverage.sh" >/dev/null 2>&1; }

# --- complete table: every key translated, none falls back --------------------------
gate || fail 'the committed Spanish table does not pass the coverage gate'
i18n_load es "$sandbox/i18n"
while IFS= read -r key; do
	[[ "$(i18n_get "$key")" != '[en]'* ]] || fail "es: $key falls back to English"
done < <(awk -F= '!/^#/ && NF { print $1 }' "$repo_root/i18n/en.conf")
[[ "$(i18n_get selector.vm)" == 'Integración con invitado QEMU/SPICE' ]] || fail 'es: selector.vm is not the Spanish text'

# --- a deliberate gap: English shows through, marked, and the gate goes red ------------
sed -i '/^selector.vm=/d; s/^# keys: 6/# keys: 5/' "$sandbox/i18n/es.conf"
i18n_load es "$sandbox/i18n"
[[ "$(i18n_get selector.vm)" == '[en] QEMU/SPICE guest integration' ]] || fail "gap: expected marked English, got '$(i18n_get selector.vm)'"
[[ "$(i18n_get selector.desktop_login)" == 'Inicio de sesión gráfico (greetd y tuigreet)' ]] || fail 'gap: an unrelated key lost its translation'
gate && fail 'gate: accepted a Spanish table missing a key'

# --- bootstrap speaks the session language ---------------------------------------------
run_bootstrap() { SYSROOT="$repo_root/tests/fixtures/$1/sysroot" LSPCI_CMD=false PACMAN_CMD=false bash "$repo_root/scripts/bootstrap.sh" "${@:2}"; }
out="$(LANG=es_ES.UTF-8 run_bootstrap vm-virtio --list-selectors)"
grep -q 'esta máquina: chasis=vm' <<<"$out" || fail "es: machine line not translated: $out"
grep -q 'se aplica: Integración con invitado QEMU/SPICE' <<<"$out" || fail "es: applicable selector not translated: $out"
out="$(LANG=C run_bootstrap vm-virtio --list-selectors)"
grep -q 'this machine: chassis=vm' <<<"$out" || fail "C: expected English: $out"
out="$(VIVAC_LANG=es LANG=C run_bootstrap vm-virtio --list-selectors)"
grep -q 'esta máquina' <<<"$out" || fail 'VIVAC_LANG did not override LANG'
out="$(LANG=xx_XX.UTF-8 run_bootstrap vm-virtio --list-selectors 2>/dev/null)"
grep -q 'this machine' <<<"$out" || fail 'an unknown language must fall back to English'

# --- the refusal for an inapplicable selector is translated too, and still exits 3 ---------
status=0
out="$(LANG=es_ES.UTF-8 run_bootstrap desktop-nvidia --dry-run --vm 2>&1)" || status=$?
[[ "$status" -eq 3 ]] || fail "inapplicable selector exited $status, expected 3"
grep -q -- '--vm no se aplica a esta máquina: necesita' <<<"$out" || fail "es: refusal not translated: $out"

printf 'es: complete table, marked gap, bootstrap in two languages\n'
