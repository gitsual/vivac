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
  const monthOnly = new Intl.DateTimeFormat(locale, { month: 'long' });
  const monthNarrow = new Intl.DateTimeFormat(locale, { month: 'narrow' });
  const weekdayLong = new Intl.DateTimeFormat(locale, { weekday: 'long' });
  const dateLong = new Intl.DateTimeFormat(locale, { day: 'numeric', month: 'long', year: 'numeric' });
  const month = new Intl.DateTimeFormat(locale, { month: 'long', year: 'numeric' });
  const weekdayShort = new Intl.DateTimeFormat(locale, { weekday: 'short' });
  const long = new Intl.DateTimeFormat(locale, { weekday: 'long', day: 'numeric', month: 'long' });
  const cap = (s) => s.charAt(0).toUpperCase() + s.slice(1);
  return {
    month: (d) => cap(month.format(d)),
    weekdayShort: (d) => cap(weekdayShort.format(d).replace('.', '')),
    long: (d) => cap(long.format(d)),
    monthName: (d) => cap(monthOnly.format(d)),
    monthNarrow: (d) => cap(monthNarrow.format(d)),
    weekdayLong: (d) => cap(weekdayLong.format(d)),
    dateLong: (d) => dateLong.format(d),
  };
}

export const esc = (s) => String(s ?? '').replace(/[&<>"']/g, (c) => `&#${c.charCodeAt(0)};`);

// "{1} of {2}" with its values, the way the labels are written.
export const fmt = (text, ...args) => String(text ?? '').replace(/\{(\d+)\}/g, (_, i) => String(args[Number(i) - 1] ?? ''));

// A popup that takes the keyboard (the system panel, opened on purpose by a
// right click) closes with Escape and when focus leaves it, instead of by
// the pointer's comings and goings.
export function closeOnEscapeOrBlur(name, graceMs = 1200) {
  const opened = Date.now();
  let closing = false;
  const close = () => {
    if (closing) return;
    closing = true;
    try { localStorage.removeItem(`popup.${name}.alive`); } catch {}
    zebar.currentWidget().window.tauri.close();
  };
  window.addEventListener('keydown', (e) => { if (e.key === 'Escape') close(); });
  // A blur right at the opening is the window not having been given the
  // focus yet, not the pointer having gone elsewhere.
  window.addEventListener('blur', () => { if (Date.now() - opened > graceMs) close(); });
  setInterval(() => { try { localStorage.setItem(`popup.${name}.alive`, String(Date.now())); } catch {} }, 400);
  return close;
}

// An arc of a ring: `value` 0..1 of a circle of radius r at the viewBox's
// middle, starting at twelve o'clock; the track is a full circle under it.
export function ringPaths(r, value, from = 0.0, sweep = 1.0) {
  const c = 2 * Math.PI * r;
  const v = Math.max(0, Math.min(1, value));
  return { c, dash: `${(c * sweep * v).toFixed(2)} ${c.toFixed(2)}`, trackDash: `${(c * sweep).toFixed(2)} ${c.toFixed(2)}`, from };
}

export const GB = 1024 ** 3;
// Sizes the way the Linux panels write them: one decimal under 100, none over.
export function human(bytes) {
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  let v = Math.max(0, Number(bytes) || 0);
  let i = 0;
  while (v >= 1024 && i < units.length - 1) { v /= 1024; i++; }
  return `${v >= 100 || i === 0 ? Math.round(v) : v.toFixed(1)} ${units[i]}`;
}
