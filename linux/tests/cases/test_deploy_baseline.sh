#!/usr/bin/env bash
set -Eeuo pipefail

# The baseline gate exists to make an unintended change to the default profile
# impossible to miss. These scenarios prove it fails on drift in either
# direction — edited content and added file — and recovers on a re-freeze.

repo_root="${REPO_ROOT:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)}"

sandbox="$(mktemp -d "${TMPDIR:-/tmp}/vivac-baseline.XXXXXX")"
trap 'rm -rf -- "$sandbox"' EXIT

# Work on a copy: the gate reads the tree next to the script, so the script is
# copied alongside a disposable dotfiles/ rather than pointed at the checkout.
mkdir -p -- "$sandbox/scripts" "$sandbox/data"
cp -- "$repo_root/scripts/freeze-baseline.sh" "$sandbox/scripts/"
cp -r -- "$repo_root/dotfiles" "$sandbox/dotfiles"

gate() { (cd "$sandbox" && bash scripts/freeze-baseline.sh "$@"); }

fail() {
	printf '%s\n' "$1" >&2
	exit 1
}

gate --update >/dev/null
gate >/dev/null || fail 'baseline: a freshly frozen baseline must verify'

# Scenario 1 — a deployed file's content changed.
printf '\n# drift\n' >>"$sandbox/dotfiles/kitty/.config/kitty/kitty.conf"
if gate >/dev/null 2>&1; then
	fail 'scenario 1: gate accepted an edited default-profile file'
fi
gate --update >/dev/null
gate >/dev/null || fail 'scenario 1: re-freezing must restore the green state'

# Scenario 2 — a new file joined the default profile.
printf 'new\n' >"$sandbox/dotfiles/kitty/.config/kitty/extra.conf"
if gate >/dev/null 2>&1; then
	fail 'scenario 2: gate accepted a file added to the default profile'
fi

# Scenario 3 — a file left the default profile.
rm -- "$sandbox/dotfiles/kitty/.config/kitty/extra.conf"
rm -- "$sandbox/dotfiles/kitty/.config/kitty/kitty.conf"
if gate >/dev/null 2>&1; then
	fail 'scenario 3: gate accepted a file removed from the default profile'
fi

printf 'deploy baseline gate: 3 drift scenarios rejected as expected\n'
