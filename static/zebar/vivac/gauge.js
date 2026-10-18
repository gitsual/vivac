// The gauges' hover popups, one page for the four: <body data-kind> says
// which (cpu.html, memory.html, disk.html, gpu.html). Zebar's providers give
// the numbers at once; the programs using the most, and the NVIDIA card's
// detail, come from bin/vivac-sysinfo.ps1, which takes a few seconds, so
// they fill in after.
import * as zebar from 'https://esm.sh/zebar@3.0';
import { config } from './config.js';
import { keepOpenWhileHovered, esc } from './popup.js';

const kind = document.body.dataset.kind;
keepOpenWhileHovered(kind);
const L = config.labels;
const el = document.getElementById('gauge');
const script = `-NoProfile -NonInteractive -ExecutionPolicy Bypass -File ${config.repo}\\bin\\vivac-sysinfo.ps1`;

const GB = 1024 ** 3;
const gb = (b) => `${(b / GB).toFixed(b >= 100 * GB ? 0 : 1)} GB`;
const bar = (pct, cls = '') => `<div class="g-bar${cls}"><span style="width:${Math.max(0, Math.min(100, pct))}%"></span></div>`;
const level = (pct) => (pct >= 90 ? ' critical' : pct >= 75 ? ' warning' : '');
const row = (label, value) => `<span class="dim">${esc(label)}</span><span>${esc(value)}</span>`;

// The last two minutes, as the bar recorded them.
function spark(key) {
  let h = [];
  try { h = JSON.parse(localStorage.getItem('gauge.history') || '{}')[key] || []; } catch {}
  if (h.length < 2) return '';
  const w = 300;
  const pts = h.map((v, i) => `${((i / (h.length - 1)) * w).toFixed(1)},${(40 - (v / 100) * 38).toFixed(1)}`).join(' ');
  return `<svg class="g-spark" viewBox="0 0 ${w} 40" preserveAspectRatio="none"><polyline points="0,40 ${pts} ${w},40" class="area"/><polyline points="${pts}" class="line"/></svg>`;
}

let top = null;
let gpu = null;
let providers = null;

function topList(key, fmt) {
  if (!top) return `<div class="fc-label">${esc(L.top)}</div><div class="dim g-wait"><span class="spinner"></span>${esc(L.loading_top)}</div>`;
  const items = top[key] || [];
  return `<div class="fc-label">${esc(L.top)}</div><div class="g-top">${items.map((p) => row(p.name, fmt(p.value))).join('')}</div>`;
}

function draw() {
  const out = providers?.outputMap || {};
  let html = '';
  if (kind === 'cpu' && out.cpu) {
    const c = out.cpu;
    html += `<div class="popup-head">${esc(L.cpu)}</div>`;
    html += `<div class="g-big">${Math.round(c.usage)}%</div>${bar(c.usage, level(c.usage))}${spark('cpu')}`;
    // Zebar leaves the frequency at 0 and the vendor empty on some machines;
    // a row with nothing to say is left out.
    html += `<div class="g-rows">${row(L.cores, `${c.physicalCoreCount} / ${c.logicalCoreCount}`)}`;
    if (c.frequency > 0) html += row(L.frequency, `${(c.frequency / 1000).toFixed(2)} GHz`);
    if (c.vendor) html += row(L.vendor, c.vendor);
    html += '</div>';
    html += topList('cpu', (v) => `${v}%`);
  } else if (kind === 'memory' && out.memory) {
    const m = out.memory;
    html += `<div class="popup-head">${esc(L.memory)}</div>`;
    html += `<div class="g-big">${gb(m.usedMemory)} <span class="dim">/ ${gb(m.totalMemory)}</span></div>${bar(m.usage, level(m.usage))}${spark('memory')}`;
    const swap = m.totalSwap ? `${gb(m.usedSwap)} / ${gb(m.totalSwap)}` : '-';
    html += `<div class="g-rows">${row(L.free, gb(m.freeMemory))}${row(L.swap, swap)}</div>`;
    html += topList('memory', (v) => (v >= 1024 ? `${(v / 1024).toFixed(1)} GB` : `${v} MB`));
  } else if (kind === 'disk' && out.disk) {
    html += `<div class="popup-head">${esc(L.disks)}</div><div class="g-disks">`;
    const disks = [...out.disk.disks].filter((d) => d.totalSpace?.bytes).sort((a, b) => a.mountPoint.localeCompare(b.mountPoint));
    for (const d of disks) {
      const used = d.totalSpace.bytes - d.availableSpace.bytes;
      const pct = (used / d.totalSpace.bytes) * 100;
      const name = `${d.mountPoint.replace(/\\$/, '')}${d.name ? `  ${d.name}` : ''}`;
      html += `<div class="g-disk"><div class="g-disk-head"><span>${esc(name)}</span><span class="dim">${esc(gb(d.availableSpace.bytes))} ${esc(L.free_of)} ${esc(gb(d.totalSpace.bytes))}</span></div>${bar(pct, level(pct))}</div>`;
    }
    html += '</div>';
  } else if (kind === 'gpu') {
    html += `<div class="popup-head">${esc(gpu?.name || 'GPU')}</div>`;
    if (!gpu) html += `<div class="dim g-wait"><span class="spinner"></span>${esc(L.loading_top)}</div>`;
    else {
      const memPct = gpu.memTotal ? (gpu.memUsed / gpu.memTotal) * 100 : 0;
      html += `<div class="g-big">${gpu.load ?? 0}% <span class="dim">${gpu.temp ?? '-'}°C</span></div>${bar(gpu.load ?? 0, level(gpu.load ?? 0))}`;
      html += `<div class="g-rows">${row(L.vram, `${(gpu.memUsed / 1024).toFixed(1)} / ${(gpu.memTotal / 1024).toFixed(1)} GB`)}`;
      html += `${row(L.gpu_power, `${Math.round(gpu.power ?? 0)} / ${Math.round(gpu.powerLimit ?? 0)} W`)}${row(L.fan, `${gpu.fan ?? 0}%`)}${row(L.frequency, `${gpu.clock ?? '-'} MHz`)}</div>`;
      html += bar(memPct, ' thin');
    }
  }
  el.innerHTML = html || `<div class="popup-foot"><span class="spinner"></span>${esc(L.loading_top)}</div>`;
}

async function sysinfo(arg) {
  try {
    const r = await zebar.shellExec('powershell.exe', `${script} ${arg}`);
    return JSON.parse(String(r.stdout).trim());
  } catch {
    return null;
  }
}

if (kind === 'gpu') {
  const poll = async () => { gpu = await sysinfo('-Gpu'); draw(); };
  poll();
  setInterval(poll, 2000);
} else {
  const want = { cpu: { cpu: { type: 'cpu', refreshInterval: 1000 } }, memory: { memory: { type: 'memory', refreshInterval: 1000 } }, disk: { disk: { type: 'disk', refreshInterval: 10000 } } }[kind];
  providers = zebar.createProviderGroup(want);
  providers.onOutput(draw);
  if (kind !== 'disk') {
    const poll = async () => { top = await sysinfo('-Top'); draw(); };
    poll();
    setInterval(poll, 5000);
  }
}
draw();
