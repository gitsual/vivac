// What the bar's hover popups share: staying open while the pointer is on
// them or on the pill that opened them, and closing themselves after. The
// bar's half of the handshake is at the end of bar.js.
import * as zebar from './zebar-client.js';

const GRACE = 400; // the pointer crossing from the pill down into the popup
const FIRST = 2500; // a popup the pointer never reaches, if the stamps fail
// The webview can miss the mouseleave (the pointer jumps off, the popup is
// covered), and then the popup would stay for good: a pointer that has not
// moved over it for this long no longer holds it open.
const IDLE = 20000;

export function keepOpenWhileHovered(name) {
  const opened = Date.now();
  let inside = false;
  let moved = Date.now();
  let closing = false;
  document.body.addEventListener('mouseenter', () => { inside = true; moved = Date.now(); });
  for (const ev of ['mousemove', 'wheel', 'mousedown']) document.body.addEventListener(ev, () => { moved = Date.now(); });
  document.body.addEventListener('mouseleave', () => { inside = false; });
  const since = (key) => {
    try {
      const v = localStorage.getItem(key);
      return v ? Date.now() - Number(v) : Infinity;
    } catch { return Infinity; }
  };
  const tick = () => {
    try { localStorage.setItem(`popup.${name}.alive`, String(Date.now())); } catch {}
    const hover = since(`popup.${name}.hover`);
    if ((inside && Date.now() - moved < IDLE) || closing || hover < GRACE) return;
    // A stamp older than this opening is a pill hovered some other time:
    // this popup was not opened by a hover, so give the pointer time.
    if (hover > 5000 && Date.now() - opened < FIRST) return;
    closing = true;
    try { localStorage.removeItem(`popup.${name}.alive`); } catch {}
    zebar.currentWidget().window.tauri.close();
  };
  setInterval(tick, 150);
}

// Months and weekdays in the bar's language, from the platform.
export function names(locale) {
  const month = new Intl.DateTimeFormat(locale, { month: 'long', year: 'numeric' });
  const weekdayShort = new Intl.DateTimeFormat(locale, { weekday: 'short' });
  const long = new Intl.DateTimeFormat(locale, { weekday: 'long', day: 'numeric', month: 'long' });
  const cap = (s) => s.charAt(0).toUpperCase() + s.slice(1);
  return {
    month: (d) => cap(month.format(d)),
    weekdayShort: (d) => cap(weekdayShort.format(d).replace('.', '')),
    long: (d) => cap(long.format(d)),
  };
}

export const esc = (s) => String(s ?? '').replace(/[&<>"']/g, (c) => `&#${c.charCodeAt(0)};`);
