// The forecast under the weather pill, in the design the Linux side's weather
// panel has: what it is like now with the sun's arc, four readings, the next
// eight hours as a temperature curve and the week with its range bars. Zebar's
// own weather provider only answers for the present, so this asks Open-Meteo
// (no key) directly. The place is the one in the settings (weather_location =
// lat,lon) or, set to auto, the one the public IP address points at, as the
// bar's pill does. Both answers are kept in localStorage for a while, so
// hovering again is instant and does not ask again.
import { config } from './config.js';
import { keepOpenWhileHovered, names, esc, fmt } from './popup.js';

keepOpenWhileHovered('forecast');
const L = config.labels;
const N = names(config.locale);
const el = document.getElementById('forecast');

// WMO weather codes, grouped the way a glance reads them.
function kind(code, day = true) {
  if (code === 0) return { g: day ? '\u{F0599}' : '\u{F0594}', t: L.wx_clear };
  if (code <= 2) return { g: day ? '\u{F0595}' : '\u{F0F31}', t: L.wx_partly };
  if (code === 3) return { g: '\u{F0590}', t: L.wx_cloudy };
  if (code <= 48) return { g: '\u{F0591}', t: L.wx_fog };
  if (code <= 57) return { g: '\u{F0597}', t: L.wx_drizzle };
  if (code <= 67) return { g: code >= 65 ? '\u{F0596}' : '\u{F0597}', t: L.wx_rain };
  if (code <= 77 || code === 85 || code === 86) return { g: '\u{F0598}', t: L.wx_snow };
  if (code <= 82) return { g: '\u{F0596}', t: L.wx_showers };
  return { g: '\u{F067E}', t: L.wx_thunder };
}

function cachedEntry(key, maxAge) {
  try {
    const v = JSON.parse(localStorage.getItem(key) || 'null');
    if (v && Date.now() - v.at < maxAge) return v;
  } catch {}
  return null;
}
const cached = (key, maxAge) => cachedEntry(key, maxAge)?.data ?? null;
function keep(key, data) {
  try { localStorage.setItem(key, JSON.stringify({ at: Date.now(), data })); } catch {}
}

async function place() {
  const w = config.weather || {};
  if (typeof w.latitude === 'number') {
    let name = cached('forecast.placeName', 7 * 86400000);
    if (!name) {
      try {
        const r = await fetch(`https://nominatim.openstreetmap.org/reverse?format=json&zoom=10&accept-language=${config.locale}&lat=${w.latitude}&lon=${w.longitude}`).then((x) => x.json());
        const a = r.address || {};
        name = [a.city || a.town || a.village || a.municipality, a.state || a.province].filter(Boolean).join(', ');
        keep('forecast.placeName', name);
      } catch {}
    }
    return { lat: w.latitude, lon: w.longitude, name: name || `${w.latitude}, ${w.longitude}` };
  }
  let p = cached('forecast.place', 6 * 3600000);
  if (!p) {
    const r = await fetch('https://ipinfo.io/json').then((x) => x.json());
    const [lat, lon] = String(r.loc).split(',').map(Number);
    p = { lat, lon, name: [r.city, r.region].filter(Boolean).join(', ') };
    keep('forecast.place', p);
  }
  return p;
}

async function forecast(p, force = false) {
  const key = `forecast.data.${p.lat},${p.lon}`;
  const hit = force ? null : cachedEntry(key, 20 * 60000);
  if (hit) return hit;
  const q = new URLSearchParams({
    latitude: p.lat, longitude: p.lon, timezone: 'auto', forecast_days: '7', wind_speed_unit: 'kmh',
    current: 'temperature_2m,apparent_temperature,relative_humidity_2m,wind_speed_10m,weather_code,is_day',
    hourly: 'temperature_2m,precipitation_probability,weather_code,is_day',
    daily: 'weather_code,temperature_2m_max,temperature_2m_min,precipitation_probability_max,sunrise,sunset,uv_index_max',
  });
  const data = await fetch(`https://api.open-meteo.com/v1/forecast?${q}`).then((x) => x.json());
  keep(key, data);
  return { at: Date.now(), data };
}

const deg = (t) => `${Math.round(t)}°`;
const hhmm = (iso) => iso.slice(11, 16);
const clock = (ms) => new Date(ms).toLocaleTimeString(config.locale, { hour: '2-digit', minute: '2-digit' });
// The place's clock as minutes since midnight, from the "YYYY-MM-DDTHH:MM" Open-Meteo gives.
const minutes = (iso) => Number(iso.slice(11, 13)) * 60 + Number(iso.slice(14, 16));
const duration = (min) => (min >= 60 ? fmt(L.fc_hm, Math.floor(min / 60), min % 60) : fmt(L.fc_min_only, min));

function sunArc(f, c) {
  const d = f.daily;
  const rise = minutes(d.sunrise[0]);
  const set = minutes(d.sunset[0]);
  const t = new Date();
  const now = t.getHours() * 60 + t.getMinutes();
  const up = now >= rise && now <= set;
  const frac = up ? (now - rise) / (set - rise) : 0;
  // A half circle of radius 66 centred at (95, 76); the sun walks it from the
  // left (rise) to the right (set).
  const r = 66;
  const cx = 95;
  const cy = 76;
  const ang = Math.PI * (1 - frac);
  const sx = cx + r * Math.cos(ang);
  const sy = cy - r * Math.sin(ang);
  const done = up && frac > 0 ? `<path class="arc-done" d="M ${cx - r} ${cy} A ${r} ${r} 0 0 1 ${sx.toFixed(1)} ${sy.toFixed(1)}"/>` : '';
  const left = `<path class="arc-left" d="M ${(up ? sx : cx - r).toFixed(1)} ${(up ? sy : cy).toFixed(1)} A ${r} ${r} 0 0 1 ${cx + r} ${cy}"/>`;
  const sun = up ? `<circle class="sun" cx="${sx.toFixed(1)}" cy="${sy.toFixed(1)}" r="7"/>` : '';
  let caption;
  if (up) caption = `${esc(L.fc_sun_left)}<b>${esc(duration(set - now))}</b>`;
  else if (now < rise) caption = `${esc(L.fc_sun_in)}<b>${esc(duration(rise - now))}</b>`;
  else caption = `<b>${esc(L.fc_night)}</b>`;
  return `<div class="fc-sun"><svg viewBox="0 0 190 84">${left}${done}<line class="horizon" x1="${cx - r - 14}" y1="${cy}" x2="${cx + r + 14}" y2="${cy}"/>${sun}</svg>
    <div class="fc-sun-text">${caption}</div>
    <div class="fc-sun-times"><span>${hhmm(d.sunrise[0])}<small>${esc(L.fc_sunrise)}</small></span><span>${hhmm(d.sunset[0])}<small>${esc(L.fc_sunset)}</small></span></div></div>`;
}

const uvWord = (uv) => (uv < 3 ? L.fc_uv_low : uv < 6 ? L.fc_uv_moderate : uv < 8 ? L.fc_uv_high : uv < 11 ? L.fc_uv_very_high : L.fc_uv_extreme);

function tile(glyph, key, value, unit, bar) {
  return `<div class="card fc-tile"><div class="fc-tile-k"><span>${glyph}</span>${esc(key)}</div><div class="fc-tile-v">${value}<small>${unit}</small></div>${bar}</div>`;
}
const meter = (pct) => `<div class="fc-bar"><i style="width:${Math.max(0, Math.min(100, pct))}%"></i></div>`;

function hoursChart(f, i0) {
  const h = f.hourly;
  const idx = [];
  for (let i = i0; i < i0 + 8 && i < h.time.length; i++) idx.push(i);
  const temps = idx.map((i) => h.temperature_2m[i]);
  const lo = Math.min(...temps);
  const hi = Math.max(...temps);
  const span = Math.max(1, hi - lo);
  const W = 100 * idx.length;
  const pts = temps.map((v, k) => [50 + k * 100, 26 + (1 - (v - lo) / span) * 40]);
  const line = pts.map((p) => `${p[0].toFixed(1)},${p[1].toFixed(1)}`).join(' ');
  const area = `${pts[0][0]},84 ${line} ${pts[pts.length - 1][0]},84`;
  let svg = `<svg class="fc-chart" viewBox="0 0 ${W} 84" preserveAspectRatio="none"><defs><linearGradient id="fcfade" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="var(--accent)" stop-opacity="0.28"/><stop offset="1" stop-color="var(--accent)" stop-opacity="0"/></linearGradient></defs>`;
  svg += `<polygon class="area" points="${area}"/><polyline class="line" points="${line}" vector-effect="non-scaling-stroke"/></svg>`;
  // Points and labels are HTML-sized elements over the stretched curve, so the
  // circles stay round whatever the card's width.
  let marks = '';
  pts.forEach((p, k) => {
    marks += `<span style="position:absolute;left:${(p[0] / W * 100).toFixed(2)}%;top:${(p[1] / 84 * 100).toFixed(1)}%;transform:translate(-50%,-50%);width:9px;height:9px;border-radius:5px;box-sizing:border-box;border:2px solid var(--accent);background:${k === 0 ? 'var(--accent)' : 'var(--surface)'}"></span>`;
    marks += `<span style="position:absolute;left:${(p[0] / W * 100).toFixed(2)}%;top:calc(${(p[1] / 84 * 100).toFixed(1)}% - 16px);transform:translateX(-50%);font-size:11px;font-weight:700">${deg(temps[k])}</span>`;
  });
  return `<div style="position:relative">${svg}${marks}</div>`;
}

function draw(p, entry) {
  const f = entry.data;
  const c = f.current;
  const now = kind(c.weather_code, c.is_day === 1);
  const d = f.daily;
  let html = `<div class="pn"><div class="pn-head"><div class="pn-tile">\u{F0595}</div>`;
  html += `<div class="pn-titles"><div class="pn-title">${esc(L.fc_title)}</div><div class="pn-sub">${esc(p.name)} · ${esc(fmt(L.fc_updated, clock(entry.at)))}</div></div>`;
  html += `<div class="pn-side fc-refresh"><button data-act="refresh" title="${esc(L.fc_refresh)}">\u{F0450}</button></div></div>`;
  html += '<div class="pn-stack">';
  html += `<div class="card fc-hero"><div class="fc-hero-glyph">${now.g}</div><div><div class="fc-hero-temp">${deg(c.temperature_2m)}</div>`;
  html += `<div class="fc-hero-text">${esc(now.t)}</div><div class="s">${esc(L.feels)} ${deg(c.apparent_temperature)}</div></div>${sunArc(f, c)}</div>`;

  const uv = Math.round(d.uv_index_max[0] ?? 0);
  html += '<div class="fc-tiles">';
  html += tile('\u{F058E}', L.humidity, Math.round(c.relative_humidity_2m), '%', meter(c.relative_humidity_2m));
  html += tile('\u{F059D}', L.wind, Math.round(c.wind_speed_10m), 'km/h', meter((c.wind_speed_10m / 60) * 100));
  html += tile('\u{F0596}', L.rain, d.precipitation_probability_max[0] ?? 0, '%', meter(d.precipitation_probability_max[0] ?? 0));
  html += tile('\u{F0599}', 'UV', uv, esc(uvWord(uv)), `<div class="fc-uv">${Array.from({ length: 11 }, (_, i) => `<i class="${i < uv ? 'on' : ''}"></i>`).join('')}</div>`);
  html += '</div>';

  // The next hours from the one we are in; they come in the place's own time,
  // and this machine is in it too.
  const h = f.hourly;
  const t = new Date();
  const pad = (n) => String(n).padStart(2, '0');
  const nowHour = `${t.getFullYear()}-${pad(t.getMonth() + 1)}-${pad(t.getDate())}T${pad(t.getHours())}`;
  let i0 = h.time.findIndex((x) => x.slice(0, 13) === nowHour);
  if (i0 < 0) i0 = 0;
  const n = Math.min(8, h.time.length - i0);
  html += `<div class="card"><div class="sec">${esc(L.next_hours)} <span class="n">${n}</span><span class="note">${esc(L.fc_temp_c)}</span></div>`;
  html += '<div class="fc-hours">';
  for (let i = i0; i < i0 + n; i++) {
    const k = kind(h.weather_code[i], h.is_day[i] === 1);
    html += `<div class="fc-hours-col"><span class="fc-hours-glyph" title="${esc(k.t)}">${k.g}</span></div>`;
  }
  html += '</div>' + hoursChart(f, i0);
  html += '<div class="fc-hours">';
  for (let i = i0; i < i0 + n; i++) html += `<div class="fc-hours-col"><span class="fc-hours-h">${h.time[i].slice(11, 13)}h</span></div>`;
  html += '</div></div>';

  const lo = Math.min(...d.temperature_2m_min);
  const hi = Math.max(...d.temperature_2m_max);
  const span = Math.max(1, hi - lo);
  html += `<div class="card"><div class="sec">${esc(L.week)} <span class="n">${d.time.length}</span><span class="note">${esc(L.fc_range)}</span></div><div class="fc-week">`;
  for (let i = 0; i < d.time.length; i++) {
    const k = kind(d.weather_code[i]);
    const day = i === 0 ? L.today : N.weekdayLong(new Date(`${d.time[i]}T12:00`));
    const pp = d.precipitation_probability_max[i];
    const a = ((d.temperature_2m_min[i] - lo) / span) * 100;
    const b = ((d.temperature_2m_max[i] - lo) / span) * 100;
    const marker = i === 0 ? `<b style="left:${Math.max(0, Math.min(100, ((c.temperature_2m - lo) / span) * 100)).toFixed(1)}%"></b>` : '';
    html += `<div class="fc-row${i === 0 ? ' today' : ''}"><span class="fc-day">${esc(day)}</span><span class="fc-glyph">${k.g}</span><span class="fc-text">${esc(k.t)}</span>`;
    html += pp ? `<span class="fc-rain chip ${pp >= 50 ? 'info' : ''}">\u{F058E} ${pp}%</span>` : '<span></span>';
    html += `<span class="fc-min">${deg(d.temperature_2m_min[i])}</span><span class="fc-range"><i style="left:${a.toFixed(1)}%;width:${Math.max(4, b - a).toFixed(1)}%"></i>${marker}</span>`;
    html += `<span class="fc-max">${deg(d.temperature_2m_max[i])}</span></div>`;
  }
  html += '</div></div></div>';
  html += `<div class="pn-foot"><span><span class="key">↻</span>${esc(L.fc_k_refresh)}</span><span>Open-Meteo</span></div></div>`;
  el.innerHTML = html;
  el.querySelector('[data-act=refresh]').addEventListener('click', () => load(true));
}

let current = null;
async function load(force = false) {
  try {
    current = current || (await place());
    draw(current, await forecast(current, force));
  } catch {
    el.innerHTML = `<div class="pn"><div class="empty-note">${esc(L.forecast_unavailable)}</div></div>`;
  }
}
el.innerHTML = `<div class="pn"><div class="empty-note"><span class="spinner"></span>${esc(L.loading)}</div></div>`;
await load();
