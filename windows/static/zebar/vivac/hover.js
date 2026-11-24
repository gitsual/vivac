// What resting the pointer on a bar button opens, and when. Plain functions
// with no Zebar in them, so a test can run them under Node.
//
// The bar times the rest (300 ms) and says so to whoever shows the panel:
// the resident host for the WPF panels (a "hover <panel>" line down its
// pipe), the bar's own popups for the month, the forecast and the system
// gauges. Closing is the panel's business (lib\Hover.psm1, hover-rule.js).
export const REST_MS = 300;

// The same mapping the Arch bar has. Phone, workspaces and the sessions
// button open nothing; their tooltips stay.
const BY_ACT = {
  mute: 'sound', network: 'network', bluetooth: 'bluetooth', security: 'security',
  theme: 'theme', power: 'power', updates: 'updates', sys: 'system', sysgauge: 'system',
};

// The panel a button opens, or null. An act, as bar.js stamps it in
// data-act; clock and weather are the two buttons that have none.
export function panelFor(act, ctx = {}) {
  if (act === 'clock') return 'calendar';
  if (act === 'weather') return 'forecast';
  if (act === 'eject') return ctx.drive ? `usb:${ctx.drive}` : null;
  return BY_ACT[act] ?? null;
}

// A button with a panel shows no tooltip: the panel is its tooltip.
export const opensPanel = (act) => act === 'eject' || act in BY_ACT;

// Panels drawn by the resident host; the rest are the bar's own popups.
export const isHostPanel = (panel) => panel !== null && !['system', 'calendar', 'forecast'].includes(panel);

// The pointer's intent: which panel it is on, and for how long. target(key)
// is called whenever the pointer is on a button (or on none: null), however
// often; it opens a panel after REST_MS on the same one and says when it
// leaves one it opened. A click on the button before the rest opens the
// panel its own way, so the rest is dropped.
export function createHoverIntent({ rest = REST_MS, setTimer, clearTimer, onRest, onLeave }) {
  let current = null;
  let timer = null;
  let rested = false;
  const cancel = () => { if (timer !== null) { clearTimer(timer); timer = null; } };
  return {
    target(key) {
      if (key === current) return;
      cancel();
      if (current !== null && rested) onLeave(current);
      current = key;
      rested = false;
      if (key === null) return;
      timer = setTimer(() => { timer = null; rested = true; onRest(key); }, rest);
    },
    click() { cancel(); },
    get current() { return current; },
  };
}
