// The month under the clock, as the source bar's clock tooltip showed it:
// weeks from Monday with their ISO numbers, today in the accent, the other
// months' days receding. The wheel moves a month either way and a click on
// the title comes back to this one.
import { config } from './config.js';
import { keepOpenWhileHovered, names, esc } from './popup.js';

keepOpenWhileHovered('calendar');
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

function draw() {
  const today = new Date();
  const first = new Date(shown);
  const start = new Date(first);
  start.setDate(1 - ((first.getDay() + 6) % 7));
  let html = `<div class="popup-head"><button class="cal-title" data-act="today">${esc(N.month(first))}</button></div>`;
  html += '<div class="cal-grid"><span class="cal-wk"></span>';
  for (let i = 0; i < 7; i++) {
    const d = new Date(start);
    d.setDate(start.getDate() + i);
    html += `<span class="cal-dow${i >= 5 ? ' weekend' : ''}">${esc(N.weekdayShort(d).slice(0, 2))}</span>`;
  }
  const d = new Date(start);
  for (let w = 0; w < 6; w++) {
    html += `<span class="cal-wk">${isoWeek(d)}</span>`;
    for (let i = 0; i < 7; i++) {
      const cls = ['cal-day'];
      if (d.getMonth() !== first.getMonth()) cls.push('other');
      if (i >= 5) cls.push('weekend');
      if (sameDay(d, today)) cls.push('today');
      html += `<span class="${cls.join(' ')}">${d.getDate()}</span>`;
      d.setDate(d.getDate() + 1);
    }
  }
  html += '</div>';
  html += `<div class="popup-foot">${esc(N.long(today))}</div>`;
  el.innerHTML = html;
  el.querySelector('[data-act=today]').addEventListener('click', () => {
    shown = new Date();
    shown.setDate(1);
    draw();
  });
}

el.addEventListener('wheel', (e) => {
  shown.setMonth(shown.getMonth() + (e.deltaY < 0 ? -1 : 1));
  draw();
});
draw();
// Past midnight with the popup open, today moves.
setInterval(draw, 60000);
