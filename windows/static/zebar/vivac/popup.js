// What the bar's popups share: how they close. A popup the pointer's rest on
// its button opened closes by the rule in hover-rule.js (the one the WPF
// panels and the Arch panels keep), a click or a key in it pins it, and one
// opened on purpose (a right click) is pinned from the start. A pinned popup
// closes with Escape or when focus leaves it. The bar's half of the handshake
// is in bar.js: it writes popup.<name>.hot ("1:<ms>" when the pointer has
// rested on the button, "0:<ms>" when it left) and popup.<name>.pin (a click).
import * as zebar from './zebar-client.js';
import { createHoverClose } from './hover-rule.js';

// The webview can miss the mouseleave (the pointer jumps off, the popup is
// covered), and then the popup would stay for good: a pointer that has not
// moved over it for this long no longer holds it open.
const IDLE = 20000;
const TICK = 50;
// A blur right at the opening is the window not having been given the focus
// yet, not the pointer having gone elsewhere.
const BLUR_GRACE = 1200;

const read = (key) => { try { return localStorage.getItem(key) || ''; } catch { return ''; } };

export function closeByHover(name, { graceMs = BLUR_GRACE } = {}) {
  const opened = Date.now();
  const rule = createHoverClose();
  let closing = false;
  let lastHot = read(`popup.${name}.hot`);
  let lastPin = read(`popup.${name}.pin`);
  // Opened by a rest if the button says it rested a moment ago.
  const byHover = lastHot.startsWith('1:') && opened - Number(lastHot.slice(2)) < 3000;
  if (!byHover) rule.pin();
  let moved = opened;

  const close = () => {
    if (closing) return;
    closing = true;
    try { localStorage.removeItem(`popup.${name}.alive`); } catch {}
    zebar.currentWidget().window.tauri.close();
  };
  const pin = () => rule.pin();
  const body = document.body;
  body.addEventListener('mouseenter', () => { moved = Date.now(); rule.pointerIn(moved); });
  body.addEventListener('mouseleave', () => rule.pointerOut(Date.now()));
  for (const ev of ['mousemove', 'wheel']) body.addEventListener(ev, () => { moved = Date.now(); });
  body.addEventListener('mousedown', () => { moved = Date.now(); pin(); });
  window.addEventListener('keydown', (e) => { if (e.key === 'Escape') close(); else pin(); });
  window.addEventListener('blur', () => { if (rule.pinned && Date.now() - opened > graceMs) close(); });

  setInterval(() => {
    try { localStorage.setItem(`popup.${name}.alive`, String(Date.now())); } catch {}
    const now = Date.now();
    const hot = read(`popup.${name}.hot`);
    if (hot !== lastHot) {
      lastHot = hot;
      if (hot.startsWith('1:')) rule.buttonRested(now);
      else if (hot.startsWith('0:')) rule.buttonLeft(now);
    }
    const p = read(`popup.${name}.pin`);
    if (p !== lastPin) { lastPin = p; pin(); }
    if (now - moved > IDLE && !rule.pinned) rule.pointerOut(now);
    if (rule.due(now)) close();
  }, TICK);
  return close;
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
