#!/usr/bin/env bash
set -Eeuo pipefail

# scripts/verify-hypr-config.sh asks Hyprland itself whether the committed
# hyprland.lua loads, on a staged config directory rendered from fixture facts.
# Without Hyprland it says so and passes. A stub binary stands in for Hyprland
# to pin what is asked of it; when the real one is installed, the same script
# also has to catch a dispatcher that does not exist.

repo_root="${REPO_ROOT:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)}"
verify="$repo_root/scripts/verify-hypr-config.sh"
sandbox="$(mktemp -d "${TMPDIR:-/tmp}/vivac-verify.XXXXXX")"
trap 'rm -rf -- "$sandbox"' EXIT

fail() {
	printf '%s\n' "$1" >&2
	exit 1
}

# --- no Hyprland: a notice, success, nothing rendered -----------------------------------------------------------
out="$(HYPRLAND_BIN="$sandbox/no-such-hyprland" bash "$verify" 2>&1)" || fail "the stage failed without Hyprland: $out"
grep -q 'not installed; skipped' <<<"$out" || fail "no skip notice without Hyprland: $out"

# --- a stub Hyprland records what it is asked ---------------------------------------------------------------------
cat >"$sandbox/hyprland" <<'STUB'
#!/usr/bin/env bash
# Logs one line per call: the arguments, then what sits beside the config.
config="${*: -1}"
dir="$(dirname -- "$config")"
local_state=none
[[ -f "$dir/local.lua" ]] && local_state="$(head -n 1 "$dir/local.lua")"
printf 'call %s | fragments=%s | local=%s\n' "$*" "$(find "$dir/generated" -name '*.lua' | wc -l)" "$local_state" >>"$STUB_LOG"
[[ "${STUB_FAIL_ON:-}" == "" || "$local_state" != *"$STUB_FAIL_ON"* ]] || { printf 'stub: refusing this config\n'; exit 1; }
printf 'config ok\n'
STUB
chmod +x "$sandbox/hyprland"
export STUB_LOG="$sandbox/log"
: >"$STUB_LOG"

out="$(HYPRLAND_BIN="$sandbox/hyprland" bash "$verify" 2>&1)" || fail "the stage failed against an accepting Hyprland: $out"
calls="$(grep -c '^call ' "$STUB_LOG")"
((calls == 8)) || fail "expected 8 verifications (5 archetypes, 2 broken local.lua, 1 owner override), saw $calls"
grep -Eq '^call --verify-config -c .*/hypr/hyprland\.lua \| fragments=3 \| local=none$' "$STUB_LOG" || fail "no clean verification of hyprland.lua with its three fragments: $(<"$STUB_LOG")"
[[ "$(grep -c 'local=none' "$STUB_LOG")" -eq 5 ]] || fail 'the five archetypes must be verified without a local.lua'
grep -q 'local=error("owner mistake")' "$STUB_LOG" || fail 'the runtime-error local.lua was not verified'
grep -q 'local=this is = not lua' "$STUB_LOG" || fail 'the syntax-error local.lua was not verified'
grep -q 'local=hl.unbind("SUPER + R")' "$STUB_LOG" || fail 'the owner-style override was not verified'
grep -q 'hyprland verify: 8 configs accepted' <<<"$out" || fail "no summary: $out"

# --- a Hyprland that refuses one case fails the stage and names it ---------------------------------------------
out="$(STUB_FAIL_ON='unbind' HYPRLAND_BIN="$sandbox/hyprland" bash "$verify" 2>&1)" && fail 'the stage passed while Hyprland refused a config'
grep -q 'owner-override' <<<"$out" || fail "the failure did not name the refused case: $out"
grep -q 'stub: refusing this config' <<<"$out" || fail "Hyprland's own message was swallowed: $out"

# --- the real thing, when it is installed ----------------------------------------------------------------------------
if command -v Hyprland >/dev/null; then
	HYPRLAND_BIN=Hyprland bash "$verify" >/dev/null 2>&1 || fail 'the real Hyprland refused the committed hyprland.lua'
	sed 's/hl\.dsp\.window\.close()/hl.dsp.window.no_such_dispatcher()/' "$repo_root/dotfiles/hypr/.config/hypr/hyprland.lua" >"$sandbox/bad.lua"
	out="$(HYPR_LUA="$sandbox/bad.lua" HYPRLAND_BIN=Hyprland bash "$verify" 2>&1)" && fail 'the real Hyprland accepted a dispatcher that does not exist'
	grep -q 'no_such_dispatcher' <<<"$out" || fail "the failure does not name the dispatcher: $out"
	real='and the real Hyprland'
else
	real='(real Hyprland not installed here)'
fi

printf 'hypr verify: skip notice, 8 staged configs, refusal named %s\n' "$real"
