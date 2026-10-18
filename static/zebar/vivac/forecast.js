// The forecast under the weather pill: what it is like now, the next twelve
// hours and the coming week, for this machine's place. Zebar's own weather
// provider only answers for the present, so this asks Open-Meteo (no key)
// directly. The place is the one in the settings (weather_location = lat,lon)
// or, set to auto, the one the public IP address points at, as the bar's
// pill does. Both answers are kept in localStorage for a while, so hovering
// again is instant and does not ask again.
import { config } from './config.js';
import { keepOpenWhileHovered, names, esc } from './popup.js';

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

function cached(key, maxAge) {
  try {
    const v = JSON.parse(localStorage.getItem(key) || 'null');
    if (v && Date.now() - v.at < maxAge) return v.data;
  } catch {}
  return null;
}
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

async function forecast(p) {
  const key = `forecast.data.${p.lat},${p.lon}`;
  const hit = cached(key, 20 * 60000);
  if (hit) return hit;
  const q = new URLSearchParams({
    latitude: p.lat, longitude: p.lon, timezone: 'auto', forecast_days: '7', wind_speed_unit: 'kmh',
    current: 'temperature_2m,apparent_temperature,relative_humidity_2m,wind_speed_10m,weather_code,is_day',
    hourly: 'temperature_2m,precipitation_probability,weather_code,is_day',
    daily: 'weather_code,temperature_2m_max,temperature_2m_min,precipitation_probability_max,sunrise,sunset,uv_index_max',
  });
  const data = await fetch(`https://api.open-meteo.com/v1/forecast?${q}`).then((x) => x.json());
  keep(key, data);
  return data;
}

const deg = (t) => `${Math.round(t)}°`;
const hhmm = (iso) => iso.slice(11, 16);

function draw(p, f) {
  const c = f.current;
  const now = kind(c.weather_code, c.is_day === 1);
  let html = `<div class="popup-head"><span class="fc-place">${esc(p.name)}</span></div>`;
  html += `<div class="fc-now"><span class="fc-now-glyph">${now.g}</span><span class="fc-now-temp">${deg(c.temperature_2m)}</span>`;
  html += `<span class="fc-now-text">${esc(now.t)}<br><span class="dim">${esc(L.feels)} ${deg(c.apparent_temperature)}</span></span></div>`;
  const d = f.daily;
  html += '<div class="fc-facts">';
  html += `<span>${esc(L.humidity)} <b>${Math.round(c.relative_humidity_2m)}%</b></span>`;
  html += `<span>${esc(L.wind)} <b>${Math.round(c.wind_speed_10m)} km/h</b></span>`;
  html += `<span>${esc(L.rain)} <b>${d.precipitation_probability_max[0] ?? 0}%</b></span>`;
  html += `<span>UV <b>${Math.round(d.uv_index_max[0] ?? 0)}</b></span>`;
  html += `<span>\u{F059C} <b>${hhmm(d.sunrise[0])}</b></span>`;
  html += `<span>\u{F059B} <b>${hhmm(d.sunset[0])}</b></span>`;
  html += '</div>';

  // The next twelve hours from the one we are in.
  const h = f.hourly;
  // The hours come in the place's own time; this machine is in it too.
  const t = new Date();
  const pad = (n) => String(n).padStart(2, '0');
  const nowHour = `${t.getFullYear()}-${pad(t.getMonth() + 1)}-${pad(t.getDate())}T${pad(t.getHours())}`;
  let i0 = h.time.findIndex((x) => x.slice(0, 13) === nowHour);
  if (i0 < 0) i0 = 0;
  html += `<div class="fc-label">${esc(L.next_hours)}</div><div class="fc-hours">`;
  for (let i = i0 + 1; i <= i0 + 12 && i < h.time.length; i++) {
    const k = kind(h.weather_code[i], h.is_day[i] === 1);
    const pp = h.precipitation_probability[i];
    html += `<div class="fc-hour"><span class="dim">${h.time[i].slice(11, 13)}</span><span class="fc-glyph" title="${esc(k.t)}">${k.g}</span>`;
    html += `<span>${deg(h.temperature_2m[i])}</span><span class="fc-pp${pp >= 50 ? ' wet' : ''}">${pp ? `${pp}%` : ''}</span></div>`;
  }
  html += '</div>';

  html += `<div class="fc-label">${esc(L.week)}</div><div class="fc-days">`;
  for (let i = 0; i < d.time.length; i++) {
    const k = kind(d.weather_code[i]);
    const day = i === 0 ? L.today : N.weekdayShort(new Date(`${d.time[i]}T12:00`));
    const pp = d.precipitation_probability_max[i];
    html += `<span class="fc-day">${esc(day)}</span><span class="fc-glyph" title="${esc(k.t)}">${k.g}</span>`;
    html += `<span class="fc-text">${esc(k.t)}</span><span class="fc-pp${pp >= 50 ? ' wet' : ''}">${pp ? `${pp}%` : ''}</span>`;
    html += `<span class="fc-range"><span class="dim">${deg(d.temperature_2m_min[i])}</span> ${deg(d.temperature_2m_max[i])}</span>`;
  }
  html += '</div>';
  el.innerHTML = html;
}

el.innerHTML = `<div class="popup-foot">${esc(L.loading)}</div>`;
try {
  const p = await place();
  draw(p, await forecast(p));
} catch {
  el.innerHTML = `<div class="popup-foot">${esc(L.forecast_unavailable)}</div>`;
}
