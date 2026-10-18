// What the bar's hover popups share: staying open while the pointer is on
// them or on the pill that opened them, and closing themselves after. The
// bar's half of the handshake is at the end of bar.js.
import * as zebar from 'https://esm.sh/zebar@3.0';

const GRACE = 400; // the pointer crossing from the pill down into the popup
const FIRST = 2500; // a popup the pointer never reaches, if the stamps fail

export function keepOpenWhileHovered(name) {
  const opened = Date.now();
  let inside = false;
  let closing = false;
  document.body.addEventListener('mouseenter', () => { inside = true; });
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
    if (inside || closing || hover < GRACE) return;
    if (!Number.isFinite(hover) && Date.now() - opened < FIRST) return;
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
