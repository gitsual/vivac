#!/usr/bin/env bash
set -Eeuo pipefail

# ime=fcitx5 changes exactly the input fragment, by exactly the environment
# and the daemon start; every other render is byte-identical, the setting is
# validated, and the --ime selector adds exactly its manifest.

repo_root="${REPO_ROOT:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)}"
sandbox="$(mktemp -d "${TMPDIR:-/tmp}/vivac-ime.XXXXXX")"
trap 'rm -rf -- "$sandbox"' EXIT
# shellcheck source=lib/kv.sh
source "$repo_root/lib/kv.sh"
# shellcheck source=lib/settings.sh
source "$repo_root/lib/settings.sh"

fail() {
	printf '%s\n' "$1" >&2
	exit 1
}
render() {
	mkdir -p -- "$sandbox/h-$1"
	printf 'ime=%s\n' "$1" >"$sandbox/$1.settings"
	HOME="$sandbox/h-$1" XDG_CONFIG_HOME="$sandbox/h-$1/.config" XDG_STATE_HOME="$sandbox/state-$1" \
		SETTINGS_FILE="$sandbox/$1.settings" FACTS_FILE="$repo_root/tests/golden/laptop-intel/hardware-facts" \
		FACTS_OVERRIDE="$sandbox/absent" bash "$repo_root/scripts/render-config.sh" --deploy >/dev/null || fail "render with ime=$1 failed"
}
render none
render fcitx5
# diff exits 1 on a difference, which is the expected outcome here.
changed="$(diff -rq "$sandbox/h-none/.config" "$sandbox/h-fcitx5/.config" | sed 's|.*/\.config/||; s| .*||' || true)"
[[ "$changed" == 'hypr/generated/input.conf' ]] || fail "ime changed more than the input fragment: $changed"
added="$(diff "$sandbox/h-none/.config/hypr/generated/input.conf" "$sandbox/h-fcitx5/.config/hypr/generated/input.conf" | grep '^>' | sed 's/^> //' || true)"
expected='env = QT_IM_MODULE,fcitx
env = XMODIFIERS,@im=fcitx
env = SDL_IM_MODULE,fcitx
exec-once = fcitx5 -d'
[[ "$added" == "$expected" ]] || fail "ime=fcitx5 added other lines: $added"
grep -v '^#' "$sandbox/h-none/.config/hypr/generated/input.conf" | grep -q fcitx && fail 'ime=none still sets up fcitx'

# --- the setting is closed: none or fcitx5 -------------------------------------------------------------
printf 'ime=ibus\n' >"$sandbox/settings"
settings_load "$sandbox/settings" 2>/dev/null && fail 'an unsupported input method was accepted'
settings_load "$repo_root/settings.example" || fail 'settings.example does not load'
[[ "$(settings_get ime)" == none ]] || fail 'the example does not default to no input method'

# --- the selector installs exactly its manifest ----------------------------------------------------------
listing() {
	SYSROOT="$repo_root/tests/fixtures/laptop-intel/sysroot" LSPCI_CMD=false PACMAN_CMD=false \
		bash "$repo_root/scripts/bootstrap.sh" --dry-run "$@" 2>/dev/null | grep '^would install official packages' || true
}
base="$(listing)"
with="$(listing --ime)"
extra="$(LC_ALL=C comm -13 <(tr ' ' '\n' <<<"${base#*: }" | LC_ALL=C sort) <(tr ' ' '\n' <<<"${with#*: }" | LC_ALL=C sort))"
[[ "$extra" == "$(grep -Ev '^[[:space:]]*(#|$)' "$repo_root/packages/ime.txt")" ]] || fail "--ime added something outside its manifest: $extra"
grep -q fcitx <<<"$base" && fail 'the default bootstrap installs the input method'

printf 'ime: env and daemon lines only, in input.conf only; setting closed; selector adds its manifest\n'
