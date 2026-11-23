// A stand-in for Zebar's client, for looking at the bar and its panels in a
// plain browser (see shot.sh). Providers answer with canned data, shellExec
// with canned JSON, and the network calls of the forecast with a fixed day.
const q = new URLSearchParams(location.search);
try { if (q.get('tab')) localStorage.setItem('system.tab', q.get('tab')); } catch {}
try {
  const wave = (b, a) => Array.from({ length: 60 }, (_, i) => Math.round(Math.max(0, Math.min(100, b + a * Math.sin(i / 4) + ((i * 7) % 5)))));
  localStorage.setItem('gauge.history', JSON.stringify({ cpu: wave(18, 8), memory: wave(55, 2), gpu: wave(4, 3) }));
} catch {}
const GB = 1024 ** 3;
const disks = [
  ['C:\\', 'Windows', 'NTFS', 465, 34.8, false], ['D:\\', 'Datos', 'NTFS', 3600, 497, false],
  ['E:\\', 'Juegos', 'NTFS', 9100, 2400, false], ['F:\\', 'USB', 'FAT32', 14, 9, true],
].map(([m, n, fs, t, a, r]) => ({ mountPoint: m, name: n, fileSystem: fs, isRemovable: r, totalSpace: { bytes: t * GB }, availableSpace: { bytes: a * GB } }));
const win = (id, p, t, st = 'tiling') => ({ type: 'window', id, processName: p, title: t, state: { type: st } });
const ws = (n, kids, f = false) => ({ type: 'workspace', name: String(n), hasFocus: f, isDisplayed: f, children: kids });
const data = {
  glazewm: { allWorkspaces: [ws(1, [win('a', 'WindowsTerminal', 'pwsh')]), ws(2, [win('b', 'msedge', 'Edge')], true), ws(3, [win('c', 'WindowsTerminal', 'pwsh'), win('d', 'explorer', 'Files')]), ws(4, []), ws(5, []), ws(6, []), ws(7, []), ws(8, []), ws(9, []), ws(10, [])],
    focusedWorkspace: { name: '2' }, focusedContainer: { type: 'window', title: 'Edge - vivac' }, runCommand: async () => {} },
  date: { formatted: '12:58  lun 23 nov 2026' }, weather: { status: 'cloudy_day', celsiusTemp: 6 },
  cpu: { usage: 23, frequency: 3920, logicalCoreCount: 24, physicalCoreCount: 12, vendor: 'AuthenticAMD' },
  memory: { usage: 56, usedMemory: 34.8 * GB, freeMemory: 27.9 * GB, totalMemory: 62.7 * GB, usedSwap: 11.5 * GB, totalSwap: 24 * GB },
  disk: { disks },
  network: { interfaces: [{ type: 'wifi', name: 'Wi-Fi', friendlyName: 'Wi-Fi', ipv4Addresses: ['192.168.1.20'] }, { type: 'ethernet', name: 'Eth', ipv4Addresses: [] }], defaultGateway: { ssid: 'casa', signalStrength: 80 } },
  audio: { defaultPlaybackDevice: { name: 'Altavoces', volume: 100, isMuted: false }, setMute() {}, setVolume() {} },
};
export function createProviderGroup(cfg) {
  const out = {};
  for (const k of Object.keys(cfg)) out[k] = data[cfg[k].type] ?? data[k];
  return { outputMap: out, onOutput(cb) { setTimeout(cb, 0); } };
}
const info = { model: 'AMD Ryzen 9 5900X 12-Core Processor', cores: 12, threads: 24 };
const threads = [36, 28, 19, 22, 15, 13, 14, 17, 19, 30, 54, 29, 9, 7, 10, 10, 7, 4, 10, 9, 5, 4, 9, 10];
const answers = {
  '-Info': info, '-Cores': { threads, processes: 312, threadCount: 4890, queue: 0 },
  '-Top': { cpu: [{ name: 'java', value: 11 }, { name: 'qemu-system-x86', value: 1.5 }, { name: 'claude', value: 0.8 }, { name: 'python3', value: 0.1 }, { name: 'hermes', value: 0.1 }],
    memory: [{ name: 'java', value: 6656 }, { name: 'msedge', value: 6656 }, { name: 'qemu-system-x86', value: 5837 }, { name: 'python', value: 4608 }, { name: 'claude', value: 4403 }] },
  '-Gpu': { name: 'NVIDIA GeForce RTX 4080 SUPER', temp: 31, load: 1, memUsed: 3480, memTotal: 16384, power: 42, powerLimit: 320, fan: 0, clock: 570 },
  '-GpuProcs': { procs: [{ name: 'python', mb: 2680, n: 2, kind: 'C' }, { name: 'WindowsTerminal', mb: 376, n: 8, kind: 'G' }, { name: 'msedge', mb: 93, n: 1, kind: 'C+G' }, { name: 'dwm', mb: 77, n: 1, kind: 'G' }] },
};
export async function shellExec(program, args) {
  const a = String(args).split(' ').pop();
  if (answers[a]) return { stdout: JSON.stringify(answers[a]) };
  if (/security/.test(args)) return { stdout: JSON.stringify({ state: 'ok', tip: 'Defender: ok' }) };
  if (/tray/.test(args)) return { stdout: JSON.stringify(/Updates/.test(args) ? { count: 2, apps: 1, security: 0, titles: ['KB1'], appTitles: ['Git'] } : { bluetooth: true, reboot: false }) };
  if (program === 'nvidia-smi') return { stdout: '31, 1' };
  return { stdout: '{}' };
}
export const shellSpawn = async () => {};
export const startWidgetPreset = async () => {};
export const currentWidget = () => ({ window: { tauri: { close() {} } } });
// The forecast's network calls, answered with one fixed day in Madrid.
const realFetch = window.fetch.bind(window);
const hours = Array.from({ length: 48 }, (_, i) => { const d = new Date(); d.setHours(i, 0, 0, 0); return d; });
const iso = (d) => `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}T${String(d.getHours()).padStart(2, '0')}:${String(d.getMinutes()).padStart(2, '0')}`;
const day = (n) => { const d = new Date(); d.setDate(d.getDate() + n); return iso(d).slice(0, 10); };
window.fetch = async (url, o) => {
  const u = String(url);
  const json = (v) => new Response(JSON.stringify(v), { headers: { 'content-type': 'application/json' } });
  if (u.includes('ipinfo')) return json({ loc: '40.4,-3.7', city: 'Madrid', region: 'Comunidad de Madrid' });
  if (u.includes('nominatim')) return json({ address: { city: 'Madrid', state: 'Comunidad de Madrid' } });
  if (u.includes('open-meteo')) {
    return json({
      current: { temperature_2m: 13, apparent_temperature: 10, relative_humidity_2m: 48, wind_speed_10m: 4, weather_code: 3, is_day: 1 },
      hourly: { time: hours.map(iso), temperature_2m: hours.map((_, i) => 13 - (i % 24) * 0.4), precipitation_probability: hours.map(() => 0), weather_code: hours.map(() => 3), is_day: hours.map((d) => (d.getHours() >= 8 && d.getHours() < 18 ? 1 : 0)) },
      daily: { time: [0, 1, 2, 3, 4, 5, 6].map(day), weather_code: [3, 63, 80, 45, 45, 45, 3], temperature_2m_max: [13, 10, 11, 11, 11, 13, 13], temperature_2m_min: [2, 4, 6, 1, 1, 1, 2],
        precipitation_probability_max: [0, 65, 18, 3, 0, 3, 0], sunrise: [0, 1, 2, 3, 4, 5, 6].map((n) => `${day(n)}T08:10`), sunset: [0, 1, 2, 3, 4, 5, 6].map((n) => `${day(n)}T17:52`), uv_index_max: [3, 2, 2, 2, 2, 2, 2] },
    });
  }
  return realFetch(url, o);
};
