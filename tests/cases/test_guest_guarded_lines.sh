#!/usr/bin/env bash
# shellcheck disable=SC2016  # the needles are the guest's own shell text
set -Eeuo pipefail

# The VM gate matches lines of the rendered input.lua that the template guards
# with "@?setting_ime=fcitx5@ ": the renderer keeps ONE leading space on them.
# Run the gate's own matching lines against a real render, so a mismatch is
# found here and not in the VM.

repo_root="${REPO_ROOT:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)}"
acceptance="$repo_root/tests/guest-acceptance.sh"
sandbox="$(mktemp -d "${TMPDIR:-/tmp}/vivac-guarded.XXXXXX")"
trap 'rm -rf -- "$sandbox"' EXIT
fail() {
	printf '%s\n' "$1" >&2
	exit 1
}

home="$sandbox/home"
mkdir -p -- "$home/.config/vivac"
printf 'xkb_layout=fr\nime=fcitx5\n' >"$home/.config/vivac/settings"
HOME="$home" XDG_CONFIG_HOME="$home/.config" XDG_STATE_HOME="$sandbox/state" \
	FACTS_FILE="$repo_root/tests/golden/desktop-nvidia/hardware-facts" FACTS_OVERRIDE="$sandbox/none" \
	bash "$repo_root/scripts/render-config.sh" --deploy >/dev/null || fail 'could not render the fragments'
input="$home/.config/hypr/generated/input.lua"
grep -Fq 'hl.env("QT_IM_MODULE", "fcitx")' "$input" || fail 'the render has no input-method line'

# The gate's matching code: the helper and every check on input.lua.
script="$sandbox/gate-lines.sh"
{
	printf 'set -Eeuo pipefail\n'
	grep -E '^fragment_has\(\)' "$acceptance" || true
	grep -E '^(grep|fragment_has) .*generated/input\.lua' "$acceptance"
} >"$script"
grep -q 'generated/input.lua' "$script" || fail 'no check on input.lua found in the gate'
HOME="$home" bash "$script" || fail 'the gate does not match the rendered input.lua'

# And the helper must not be a loose substring match.
grep -E '^fragment_has\(\)' "$acceptance" >/dev/null || fail 'the gate has no fragment_has helper'
{
	grep -E '^fragment_has\(\)' "$acceptance"
	printf 'fragment_has "$1" %q\n' 'hl.env("QT_IM_MODULE", "fcitx")'
} >"$sandbox/neg.sh"
printf -- '-- hl.env("QT_IM_MODULE", "fcitx") trailing\n' >"$sandbox/other.lua"
bash "$sandbox/neg.sh" "$sandbox/other.lua" 2>/dev/null && fail 'the helper matched a non-line'

printf 'guest guarded lines: the gate matches the rendered input.lua\n'
