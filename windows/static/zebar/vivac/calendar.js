// The month under the clock, in the design the Linux side's calendar has: a
// card for today (the day, its week, how far into the year), the month's
// navigation, and the grid with ISO week numbers from Monday, weekends
// shaded and this week's row banded. The wheel moves a month either way, the
// arrows too, and "Today" comes back to this one.
import { config } from './config.js';
import { keepOpenWhileHovered, names, esc, fmt } from './popup.js';

keepOpenWhileHovered('calendar');
const L = config.labels;
const N = names(config.locale);
const el = document.getElementById('calendar');
let shown = new Date();
shown.setDate(1);

function isoWeek(d) {
  const t = new Date(Date.UTC(d.getFullYear(), d.getMonth(), d.getDate()));
  const day = t.getUTCDay() || 7;
  t.setUTCDate(t.getUTCDate() + 4 - day);
  const year = new Date(Date.UTC(t.getUTCFullYear(), 0, 1));
  return Math.ceil(((t - year) / 86400000 + 1) / 7);
}

const sameDay = (a, b) => a.getFullYear() === b.getFullYear() && a.getMonth() === b.getMonth() && a.getDate() === b.getDate();
const daysIn = (y, m) => new Date(y, m + 1, 0).getDate();
const isLeap = (y) => (y % 4 === 0 && y % 100 !== 0) || y % 400 === 0;

function hero(today) {
  const yearLen = isLeap(today.getFullYear()) ? 366 : 365;
  const dayOfYear = Math.round((new Date(today.getFullYear(), today.getMonth(), today.getDate()) - new Date(today.getFullYear(), 0, 1)) / 86400000) + 1;
  const left = yearLen - dayOfYear;
  let notches = '';
  let months = '';
  for (let m = 0; m < 12; m++) {
    const cur = m === today.getMonth();
    const frac = cur ? (today.getDate() - 1 + 0.5) / daysIn(today.getFullYear(), m) : 0;
    notches += `<span class="cal-notch${m < today.getMonth() ? ' done' : ''}">${cur ? `<i style="width:${(frac * 100).toFixed(0)}%"></i>` : ''}</span>`;
    months += `<span${cur ? ' class="cur"' : ''}>${esc(N.monthNarrow(new Date(today.getFullYear(), m, 1)))}</span>`;
  }
  return `<div class="card cal-hero">
    <div class="cal-big">${today.getDate()}</div>
    <div class="cal-dow-name">${esc(N.weekdayLong(today))}</div>
    <div class="cal-long">${esc(N.dateLong(today))}</div>
    <div class="cal-week-chip"><span class="chip info">${esc(fmt(L.cal_week, isoWeek(today)))}</span></div>
    <div class="cal-year"><div class="cal-notches">${notches}</div><div class="cal-months">${months}</div>
      <div class="cal-yfoot"><span>${fmt(esc(L.cal_day_of), `<b>${dayOfYear}</b>`, yearLen)}</span><span>${left === 1 ? esc(L.cal_days_left_one) : fmt(esc(L.cal_days_left), `<b>${left}</b>`)}</span></div></div>
  </div>`;
}

function grid(today) {
  const first = new Date(shown);
  const start = new Date(first);
  start.setDate(1 - ((first.getDay() + 6) % 7));
  let html = '<div class="card cal-grid"><span class="cal-head wk">' + esc(L.cal_wk) + '</span>';
  for (let i = 0; i < 7; i++) {
    const d = new Date(start);
    d.setDate(start.getDate() + i);
    html += `<span class="cal-head${i >= 5 ? ' weekend' : ''}">${esc(N.weekdayShort(d).slice(0, 3))}</span>`;
  }
  const todayWeek = `${today.getFullYear()}-${isoWeek(today)}`;
  const d = new Date(start);
  for (let w = 0; w < 6; w++) {
    const thursday = new Date(d);
    thursday.setDate(d.getDate() + 3);
    const band = `${thursday.getFullYear()}-${isoWeek(d)}` === todayWeek ? ' thisweek' : '';
    html += `<span class="cal-cell wk${band}">${isoWeek(d)}</span>`;
    for (let i = 0; i < 7; i++) {
      const cls = ['cal-cell'];
      if (d.getMonth() !== first.getMonth()) cls.push('other');
      if (i >= 5) cls.push('weekend');
      if (band) cls.push('thisweek');
      if (i === 6) cls.push('sun');
      if (sameDay(d, today)) html += `<span class="${cls.join(' ')}"><span class="cal-today" style="display:block">${d.getDate()}</span></span>`;
      else html += `<span class="${cls.join(' ')}">${d.getDate()}</span>`;
      d.setDate(d.getDate() + 1);
    }
  }
  return html + '</div>';
}

function draw() {
  const today = new Date();
  const first = new Date(shown);
  let html = `<div class="pn"><div class="pn-head"><div class="pn-tile">\u{F00ED}</div>
    <div class="pn-titles"><div class="pn-title">${esc(L.cal_title)}</div><div class="pn-sub">${esc(N.month(first))}</div></div></div>`;
  html += `<div class="pn-stack">${hero(today)}`;
  html += `<div class="cal-nav"><button class="sq" data-act="prev">‹</button><div class="cal-nav-title">${esc(N.month(first))}</div><button class="sq" data-act="next">›</button><button class="btn" data-act="today">${esc(L.today)}</button></div>`;
  html += grid(today);
  html += `</div><div class="pn-foot"><span><span class="key">↕</span>${esc(L.cal_k_month)}</span><span><span class="key">${esc(L.today)}</span>${esc(L.cal_k_today)}</span></div></div>`;
  el.innerHTML = html;
  el.querySelectorAll('[data-act]').forEach((b) => b.addEventListener('click', () => {
    if (b.dataset.act === 'today') { shown = new Date(); shown.setDate(1); }
    else shown.setMonth(shown.getMonth() + (b.dataset.act === 'next' ? 1 : -1));
    draw();
  }));
}

el.addEventListener('wheel', (e) => {
  shown.setMonth(shown.getMonth() + (e.deltaY < 0 ? -1 : 1));
  draw();
});
draw();
// Past midnight with the popup open, today moves.
setInterval(draw, 60000);
