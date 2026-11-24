#!/usr/bin/env bash
set -Eeuo pipefail

# A panel opened by resting the pointer on its bar button (lib/bar-hover)
# closes on its own, as a hover menu does; one opened or touched by a click or
# a key stays. The rule is kit.HoverClose, driven here with a fake clock:
#   - the pointer leaves the button without coming into the panel: closes
#     after LEFT_BUTTON_MS
#   - the pointer comes into the panel: stays; leaves it: closes after
#     LEFT_PANEL_MS, unless it comes back or rests on the button again
#   - a click or a key in the panel pins it: nothing closes it on hover again
# Then vivac-panel's flags: --hover-leave with no such panel open does nothing
# and returns at once.

repo_root="${REPO_ROOT:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)}"
fail() {
	printf '%s\n' "$1" >&2
	exit 1
}

/usr/bin/python3 -I - "$repo_root/lib" <<'PY' || fail 'HoverClose broke its rule'
import sys
sys.path.insert(0, sys.argv[1])
from vivacpanel.kit import HoverClose

class Clock:
    def __init__(self):
        self.now, self.timers, self.next = 0, {}, 1
    def later(self, ms, fn):
        self.timers[self.next] = (self.now + ms, fn)
        self.next += 1
        return self.next - 1
    def cancel(self, ident):
        self.timers.pop(ident, None)
    def run(self, ms):
        end = self.now + ms
        while True:
            due = [(t, i) for i, (t, _) in self.timers.items() if t <= end]
            if not due:
                break
            t, i = min(due)
            self.now = t
            _, fn = self.timers.pop(i)
            fn()
        self.now = end

def fresh(hover=True):
    clock, closed = Clock(), []
    rule = HoverClose(clock.later, clock.cancel, lambda: closed.append(clock.now), hover=hover)
    return clock, closed, rule

L, P = HoverClose.LEFT_BUTTON_MS, HoverClose.LEFT_PANEL_MS

clock, closed, rule = fresh()
rule.button_left()
clock.run(L - 1); assert closed == [], 'closed before the grace'
clock.run(2); assert closed == [L], f'left the button, never came in: {closed}'

clock, closed, rule = fresh()
rule.pointer_in(); rule.button_left(); clock.run(5000)
assert closed == [], f'closed with the pointer inside: {closed}'
rule.pointer_out(); clock.run(P - 1); assert closed == []
rule.pointer_in(); clock.run(5000); assert closed == [], 'came back in time and still closed'
rule.pointer_out(); clock.run(P + 1); assert len(closed) == 1, f'left the panel and it stayed: {closed}'

clock, closed, rule = fresh()
rule.button_left(); clock.run(L // 2)
rule.button_rested(); clock.run(5000)
assert closed == [], f'rested on the button again and it closed: {closed}'

clock, closed, rule = fresh()
rule.pointer_in(); rule.pin(); rule.pointer_out(); rule.button_left(); clock.run(5000)
assert closed == [], f'a pinned panel closed on hover: {closed}'
assert not rule.hover

clock, closed, rule = fresh(hover=False)
rule.button_left(); rule.pointer_out(); clock.run(5000)
assert closed == [], 'a panel opened by a click closed on hover'
PY

# The network panel opens on the tab its button names (network#wired is
# Ethernet, network#wireless Wi-Fi), and an open one switches tab when the
# pointer rests on the other button.
/usr/bin/python3 -I - "$repo_root/lib" <<'PY2' || fail 'the network panel ignores the tab it is asked for'
import sys
sys.path.insert(0, sys.argv[1])
from vivacpanel.network import tab_for
assert tab_for([]) == "wifi"
assert tab_for(["ethernet"]) == "eth" and tab_for(["eth"]) == "eth"
assert tab_for(["wifi"]) == "wifi" and tab_for(["nonsense"]) == "wifi"
PY2
grep -q 'def main(\*args' "$repo_root/lib/vivacpanel/network.py" || fail 'network.main takes no tab'
grep -q 'on_hover_args' "$repo_root/lib/vivacpanel/network.py" || fail 'an open network panel does not switch tab on hover'

# --hover-leave reaches a panel only if one of that kind is open.
start=$(date +%s%N)
HOME="$(mktemp -d)" /usr/bin/python3 "$repo_root/dotfiles/ricer/.local/bin/vivac-panel" sound --hover-leave ||
	fail '--hover-leave failed with no panel open'
elapsed=$((($(date +%s%N) - start) / 1000000))
((elapsed < 3000)) || fail "--hover-leave with no panel took ${elapsed} ms"

printf 'panel hover: closes after leaving, stays while inside, a click or a key pins it\n'
