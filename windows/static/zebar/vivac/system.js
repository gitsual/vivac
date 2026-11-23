// The system panel: the four gauges the bar folds into one chip (processor,
// memory, disks, graphics card) as tabs of one drop-down, in the design the
// Linux side's system panel has. Zebar's providers give the numbers at once;
// the per-thread use, the programs using the most and the card's detail come
// from bin/vivac-sysinfo.ps1, which takes a moment, so they fill in after.
// The bar records the last two minutes of use (localStorage gauge.history)
// for the graphs, since a panel lives only while it is open.
import * as zebar from './zebar-client.js';
import { config } from './config.js';
import { closeOnEscapeOrBlur, esc, fmt, human } from './popup.js';

const L = config.labels;
const el = document.getElementById('system');
const script = `-NoProfile -NonInteractive -ExecutionPolicy Bypass -File ${config.repo}\\bin\\vivac-sysinfo.ps1`;
const hasGpu = config.modules.includes('gpu');
const TABS = ['cpu', 'memory', 'disk', ...(hasGpu ? ['gpu'] : [])];
const TAB_NAME = { cpu: L.cpu, memory: L.memory, disk: L.disks, gpu: L.sys_tab_gpu };
const TAB_GLYPH = { cpu: '\u{F061A}', memory: '\u{F035B}', disk: '\u{F02CA}', gpu: '\u{F08AE}' };
const SERIES = ['var(--s1)', 'var(--s2)', 'var(--s3)', 'var(--s4)', 'var(--s5)', 'var(--s6)'];

let tab = 'cpu';
try { const t = localStorage.getItem('system.tab'); if (TABS.includes(t)) tab = t; } catch {}

const close = closeOnEscapeOrBlur('system');
let info = null; // the processor's name and counts, asked once
let cores = null; // per-thread use, processes, threads
let top = null; // programs by processor and memory
let gpu = null; // nvidia-smi
let gpuProcs = null;
let providers = null;

const pct0 = (v) => `${Math.round(v)}%`;
const pct1 = (v) => (v >= 10 ? `${Math.round(v)}%` : `${v.toFixed(1)}%`);
const clamp = (v, lo = 0, hi = 100) => Math.max(lo, Math.min(hi, v));

function history(key) {
  try { return JSON.parse(localStorage.getItem('gauge.history') || '{}')[key] || []; } catch { return []; }
}

// ---- drawing pieces --------------------------------------------------------

// The 270-degree ring of the hero cards: a gap at the bottom, the value
// clockwise from the lower left.
function ring(value, hot) {
  const r = 46;
  const c = 2 * Math.PI * r;
  const arc = c * 0.75;
  const v = clamp(value, 0, 1) * arc;
  const rot = 'transform="rotate(135 60 60)"';
  return `<div class="ring-wrap"><svg viewBox="0 0 120 120"><circle class="ring-track" cx="60" cy="60" r="${r}" stroke-dasharray="${arc.toFixed(1)} ${c.toFixed(1)}" ${rot}/>`
    + `${v > 0.5 ? `<circle class="ring-val${hot ? ' hot' : ''}" cx="60" cy="60" r="${r}" stroke-dasharray="${v.toFixed(1)} ${c.toFixed(1)}" ${rot}/>` : ''}</svg>`;
}
const ringNum = (n) => `<div class="ring-num">${n}<small>%</small></div></div>`;

// The last two minutes as a line over dotted 0, 50 and 100 rules, with the
// scale on the right and the minutes under it.
function graph(values, height = 92) {
  const n = values.length;
  const W = 300;
  const y = (v) => (height - 2) - (clamp(v) / 100) * (height - 4);
  let body = '';
  for (const g of [0, 50, 100]) body += `<line class="${g === 0 ? 'base' : 'grid'}" x1="0" x2="${W}" y1="${y(g).toFixed(1)}" y2="${y(g).toFixed(1)}" vector-effect="non-scaling-stroke"/>`;
  let dot = '';
  if (n >= 2) {
    const pts = values.map((v, i) => `${((i / 59) * W + (W - ((n - 1) / 59) * W)).toFixed(1)},${y(v).toFixed(1)}`);
    body += `<polygon class="area" points="${pts[0].split(',')[0]},${height} ${pts.join(' ')} ${W},${height}"/><polyline class="line" points="${pts.join(' ')}"/>`;
    dot = `<span style="position:absolute;right:36px;top:${(y(values[n - 1]) / height * 100).toFixed(1)}%;width:7px;height:7px;margin:-3px -3px 0 0;border-radius:4px;background:var(--accent)"></span>`;
  }
  const label = (v) => `<span class="y" style="top:${(y(v) / height * 100).toFixed(1)}%">${v}%</span>`;
  return `<div class="hist-plot"><svg class="hist-svg" viewBox="0 0 ${W} ${height}" preserveAspectRatio="none" style="height:${height}px">${body}</svg>${dot}${label(100)}${label(50)}${label(0)}</div>`
    + `<div class="hist-x" style="padding-right:36px"><span>${esc(L.sys_t_2min)}</span><span>${esc(L.sys_t_1min)}</span><span>${esc(L.sys_t_now)}</span></div>`;
}

function peakMean(values) {
  if (!values.length) return { peak: 0, mean: 0, ago: 0 };
  const peak = Math.max(...values);
  const last = values.lastIndexOf(peak);
  return { peak, mean: values.reduce((a, b) => a + b, 0) / values.length, ago: (values.length - 1 - last) * 2 };
}

const fact = (key, value, sub = '', extra = '', cls = '') =>
  `<div class="fact"><div class="fact-k">${esc(key)}</div><div class="fact-v${cls ? ` ${cls}` : ''}">${value}</div><div class="fact-s">${sub}</div>${extra}</div>`;
const miniBar = (pct) => `<div class="mini"><i style="width:${clamp(pct).toFixed(0)}%"></i></div>`;
const section = (title, count, note) =>
  `<div class="sec">${esc(title)}${count !== undefined ? ` <span class="n">${count}</span>` : ''}${note ? `<span class="note">${note}</span>` : ''}</div>`;

// Threads as one column per physical core, one row per sibling. Windows does
// not say which logical processors share a core; siblings are adjacent pairs
// when there are twice as many threads as cores, as on every SMT part.
function heat(per, physical) {
  if (!per.length) return '';
  const smt = physical && per.length % physical === 0 ? per.length / physical : 1;
  const colsN = per.length / smt;
  let cells = '';
  for (let r = 0; r < smt; r++) {
    for (let c = 0; c < colsN; c++) {
      const v = per[c * smt + r];
      const a = Math.min(1, 0.14 + 0.0175 * v);
      const style = `background:color-mix(in srgb, var(--accent) ${(a * 100).toFixed(0)}%, var(--surface));${a > 0.6 ? 'color:var(--bg);font-weight:700' : ''}`;
      cells += `<div class="heat-cell" style="${style}">${Math.round(v)}</div>`;
    }
  }
  let idx = '';
  for (let c = 0; c < colsN; c++) idx += `<div class="heat-idx">${c}</div>`;
  const cols = `grid-template-columns:repeat(${colsN}, 1fr)`;
  return { smt, html: `<div class="heat" style="${cols}">${cells}</div><div class="heat" style="${cols};margin-top:2px">${idx}</div>` };
}

function stack(parts, freeText) {
  let html = '<div class="stack">';
  for (const p of parts) html += `<i style="width:${(p.frac * 100).toFixed(2)}%;background:${p.color}"></i>`;
  if (freeText !== undefined) html += `<i class="free">${esc(freeText)}</i>`;
  return `${html}</div>`;
}

function procRow(i, name, frac, value, pct, color = SERIES[i], bar = true) {
  const dot = `<span class="pdot" style="background:${color}"></span>`;
  const bars = bar ? `<span class="pbar"><i style="width:${clamp(frac * 100).toFixed(1)}%;background:${color}"></i></span>` : '';
  return `<div class="prow${bar ? '' : ' nobar'}">${dot}<span class="pname">${esc(name)}</span>${bars}<span class="pval">${esc(value)}</span>${pct !== undefined ? `<span class="ppct">${esc(pct)}</span>` : '<span></span>'}</div>`;
}

const waiting = () => `<div class="empty-note"><span class="spinner"></span>${esc(L.loading_top)}</div>`;

// ---- the four tabs ---------------------------------------------------------

function cpuTab(out) {
  const c = out.cpu;
  if (!c) return waiting();
  const hist = history('cpu');
  const { peak, mean } = peakMean(hist);
  const per = cores?.threads || [];
  const physical = c.physicalCoreCount || info?.cores || 0;
  const logical = c.logicalCoreCount || info?.threads || per.length;
  const smt = physical ? Math.max(1, Math.round(logical / physical)) : 1;
  let html = '<div class="pn-stack">';
  html += `<div class="card"><div class="hero">${ring(c.usage / 100, c.usage >= 90)}${ringNum(Math.round(c.usage))}<div>`;
  html += `<div class="hist-meta"><span>${esc(fmt(L.sys_use_total, logical))}</span><span>${fmt(esc(L.sys_peak_mean), `<b>${pct0(peak)}</b>`, `<b>${pct0(mean)}</b>`)}</span></div>${graph(hist)}</div></div></div>`;
  const freq = c.frequency > 0 ? `${(c.frequency / 1000).toFixed(2)} GHz` : '-';
  html += `<div class="card facts">${fact(L.cores, `${physical} / ${logical}`, esc(fmt(L.sys_smt, smt)))}${fact(L.frequency, esc(freq), esc(L.sys_freq_now))}`
    + `${fact(L.sys_procs_threads, cores ? `${cores.processes} / ${cores.threadCount}` : '-', cores ? esc(fmt(L.sys_queue, cores.queue)) : '')}</div>`;
  const h = heat(per, physical);
  if (h) {
    html += `<div class="card">${section(L.sys_threads, per.length, esc(fmt(L.sys_threads_note, h.smt)))}${h.html}</div>`;
  }
  const items = (top?.cpu || []).slice(0, 5);
  html += `<div class="card">${section(L.top, items.length || undefined, top ? esc(fmt(L.sys_top_sum, pct1(items.reduce((a, b) => a + b.value, 0)), pct1(c.usage), pct1(Math.max(0, c.usage - items.reduce((a, b) => a + b.value, 0))))) : '')}`;
  if (!top) html += waiting();
  else {
    const total = Math.max(c.usage, 0.1);
    html += stack(items.map((p, i) => ({ frac: clamp(p.value / total, 0, 1), color: SERIES[i] })));
    const max = Math.max(...items.map((p) => p.value), 0.1);
    html += `<div class="plist">${items.map((p, i) => procRow(i, p.name, p.value / max, pct1(p.value))).join('')}</div>`;
  }
  return `${html}</div></div>`;
}

function memoryTab(out) {
  const m = out.memory;
  if (!m) return waiting();
  const hist = history('memory');
  const used = m.usedMemory;
  const total = m.totalMemory;
  const avail = total - used;
  const pct = total ? (100 * used) / total : 0;
  let html = '<div class="pn-stack">';
  html += `<div class="card"><div class="hero mem"><div><div class="sec">${esc(L.sys_used)}</div>`
    + `<div style="display:flex;align-items:flex-end;margin-top:6px"><span style="font-size:44px;font-weight:800;line-height:1">${Math.round(pct)}</span><span style="font-size:15px;color:var(--dim);margin:0 0 5px 3px">%</span></div>`
    + `<div class="s" style="margin-top:8px">${esc(human(used))} / ${esc(human(total))}</div></div><div>${graph(hist, 74)}</div></div>`;
  const apps = (top?.memory || []).slice(0, 6).map((p) => ({ name: p.name, bytes: p.value * 1048576 }));
  const rest = Math.max(0, used - apps.reduce((a, b) => a + b.bytes, 0));
  const parts = apps.map((p, i) => ({ frac: total ? p.bytes / total : 0, color: SERIES[i] }));
  if (total && rest > 0 && top) parts.push({ frac: rest / total, color: 'var(--s7)' });
  html += `${stack(parts, fmt(L.sys_free_n, human(avail)))}<div class="stack-legend"><span>0</span><span>${esc(L.sys_mem_map)}</span><span>${esc(human(total))}</span></div></div>`;
  const swapPct = m.totalSwap ? (100 * m.usedSwap) / m.totalSwap : 0;
  html += `<div class="card facts">${fact(L.sys_available, esc(human(avail)), esc(fmt(L.sys_of_total, total ? Math.round((100 * avail) / total) : 0)))}`
    + `${fact(L.sys_used, esc(human(used)), esc(fmt(L.sys_of_total, Math.round(pct))))}`
    + `${fact(L.sys_swap, m.totalSwap ? `<span style="font-size:14px">${esc(human(m.usedSwap))} / ${esc(human(m.totalSwap))}</span>` : esc(L.sys_no_swap), '', m.totalSwap ? miniBar(swapPct) : '')}</div>`;
  html += `<div class="card">${section(L.sys_top_mem, apps.length || undefined, esc(L.sys_top_mem_note))}`;
  if (!top) html += waiting();
  else {
    const max = Math.max(...apps.map((p) => p.bytes), 1);
    html += `<div class="plist">${apps.map((p, i) => procRow(i, p.name, p.bytes / max, human(p.bytes), total ? pct0((100 * p.bytes) / total) : '')).join('')}`;
    if (total && rest > 0) html += procRow(6, L.sys_rest_procs, 0, human(rest), pct0((100 * rest) / total), 'var(--s7)', false);
    html += '</div>';
  }
  return `${html}</div></div>`;
}

const diskList = (out) => [...(out.disk?.disks || [])].filter((d) => d.totalSpace?.bytes).sort((a, b) => a.mountPoint.localeCompare(b.mountPoint)).map((d) => {
  const total = d.totalSpace.bytes;
  const avail = d.availableSpace.bytes;
  const pct = (100 * (total - avail)) / total;
  return { mount: d.mountPoint.replace(/\\$/, ''), name: d.name || '', fs: d.fileSystem || '', total, avail, pct, alert: pct > 90 };
});

function diskCard(d) {
  const r = 22;
  const c = 2 * Math.PI * r;
  const sub = [d.name, d.fs].filter(Boolean).join(' · ');
  return `<div class="dcard${d.alert ? ' alert' : ''}"><div class="dring"><svg viewBox="0 0 52 52"><circle class="ring-track" cx="26" cy="26" r="${r}"/>`
    + `<circle class="ring-val${d.alert ? ' hot' : ''}" cx="26" cy="26" r="${r}" stroke-dasharray="${(c * d.pct / 100).toFixed(1)} ${c.toFixed(1)}" transform="rotate(-90 26 26)"/></svg><span>${Math.round(d.pct)}%</span></div>`
    + `<div><div class="dmount">${esc(d.mount)}${d.alert ? `<span class="chip alert">⚠ ${esc(L.sys_full)}</span>` : ''}</div><div class="s">${esc(sub)}</div></div>`
    + `<div><div class="dfree">${esc(human(d.avail))}</div><div class="s" style="text-align:right">${esc(fmt(L.sys_free_of_total, human(d.total)))}</div></div></div>`;
}

function diskTab(out) {
  if (!out.disk) return waiting();
  const ds = diskList(out);
  const alerts = ds.filter((d) => d.alert);
  const free = ds.reduce((a, d) => a + d.avail, 0);
  const sum = ds.reduce((a, d) => a + d.total, 0);
  let html = '<div class="pn-stack">';
  html += `<div class="card facts">${fact(L.sys_total_free, esc(human(free)), esc(fmt(L.sys_free_of_total, human(sum))))}${fact(L.sys_drives, ds.length, esc(fmt(L.sys_with_space, ds.length - alerts.length)))}`
    + `${fact(L.sys_need_attention, `${alerts.length ? '⚠ ' : ''}${alerts.length}`, alerts.length ? esc(fmt(L.sys_at_pct, alerts[0].mount, Math.round(alerts[0].pct))) : esc(L.sys_all_fine), '', alerts.length ? 'alert' : '')}</div>`;
  html += `${section(L.sys_drives, ds.length, esc(L.sys_sorted_path))}`;
  html += `<div class="dlist" style="margin-top:0">${ds.length ? ds.map(diskCard).join('') : `<div class="empty-note">${esc(L.sys_no_disks)}</div>`}</div></div>`;
  return html;
}

const KIND = { C: ['Σ ', 'sys_kind_compute'], G: ['⊞ ', 'sys_kind_graphics'], 'C+G': ['◑ ', 'sys_kind_both'] };

function gpuTab() {
  if (!gpu) return waiting();
  const hist = history('gpu');
  const load = gpu.load ?? 0;
  const { peak, ago } = peakMean(hist);
  const when = ago >= 60 ? fmt(L.sys_dur_min, Math.floor(ago / 60), ago % 60) : fmt(L.sys_dur_s, ago);
  let html = '<div class="pn-stack">';
  html += `<div class="card"><div class="hero">${ring(load / 100, load >= 95)}${ringNum(Math.round(load))}<div>${graph(hist)}`
    + `<div class="hist-meta" style="margin-top:4px"><span>${esc(L.sys_gpu_use)}</span><span>${hist.length > 1 ? fmt(esc(L.sys_peak_ago), `<b>${pct0(peak)}</b>`, esc(when)) : ''}</span></div></div></div></div>`;
  const hasPower = gpu.power != null && gpu.powerLimit;
  html += `<div class="card facts">${fact(L.gpu_power, gpu.power != null ? (hasPower ? `${Math.round(gpu.power)} / ${Math.round(gpu.powerLimit)} W` : `${Math.round(gpu.power)} W`) : '-', '', hasPower ? miniBar((100 * gpu.power) / gpu.powerLimit) : '')}`
    + `${fact(L.fan, gpu.fan != null ? `${Math.round(gpu.fan)}%` : '-', gpu.fan === 0 ? esc(L.sys_fan_stopped) : '')}${fact(L.frequency, gpu.clock != null ? `${Math.round(gpu.clock)} MHz` : '-')}</div>`;
  const procs = gpuProcs?.procs || [];
  const used = (gpu.memUsed ?? 0) * 1048576;
  const total = (gpu.memTotal ?? 0) * 1048576;
  const parts = total ? procs.slice(0, 6).map((p, i) => ({ frac: (p.mb * 1048576) / total, color: SERIES[i] })) : [];
  if (total && !parts.length) parts.push({ frac: used / total, color: 'var(--s1)' });
  html += `<div class="card"><div class="sec">${esc(L.vram)}<span class="note" style="color:var(--fg);font-weight:700">${((gpu.memUsed ?? 0) / 1024).toFixed(1)} / ${((gpu.memTotal ?? 0) / 1024).toFixed(1)} GB</span></div>${stack(parts)}`
    + `<div class="stack-legend"><span>0</span><span>${esc(fmt(L.sys_vram_pct, total ? Math.round((100 * used) / total) : 0, human(Math.max(0, total - used))))}</span><span>${((gpu.memTotal ?? 0) / 1024).toFixed(1)} GB</span></div></div>`;
  html += `<div class="card">${section(L.sys_gpu_progs, gpuProcs ? procs.length : undefined, esc(L.sys_kinds_note))}`;
  if (!gpuProcs) html += waiting();
  else if (!procs.length) html += `<div class="empty-note">${esc(L.sys_gpu_none)}</div>`;
  else {
    html += `<div class="plist">${procs.map((p, i) => {
      const [g, key] = KIND[p.kind] || ['', ''];
      return `<div class="prow-gpu"><span class="pdot" style="background:${SERIES[Math.min(i, 5)]}"></span><span class="pname">${esc(p.name)}${p.n > 1 ? ` ×${p.n}` : ''}</span><span class="kind">${g}${esc(L[key] || '')}</span><span class="pval">${p.mb} MB</span></div>`;
    }).join('')}</div>`;
  }
  return `${html}</div></div>`;
}

// ---- frame -----------------------------------------------------------------

function tabValue(key, out, ds) {
  if (key === 'cpu') return { v: out.cpu ? pct0(out.cpu.usage) : '-' };
  if (key === 'memory') return { v: out.memory ? pct0(out.memory.usage) : '-' };
  if (key === 'disk') {
    const alerts = ds.filter((d) => d.alert).length;
    return alerts ? { v: `⚠ ${fmt(L.sys_tab_alert, alerts)}`, alert: true } : { v: fmt(L.sys_drives_n, ds.length) };
  }
  return { v: gpu ? pct0(gpu.load ?? 0) : '-' };
}

function subtitle(out, ds) {
  if (tab === 'cpu') return info?.model || L.cpu;
  if (tab === 'memory') return out.memory ? `${human(out.memory.usedMemory)} ${L.sys_of} ${human(out.memory.totalMemory)}` : '';
  if (tab === 'disk') return fmt(L.sys_drives_n, ds.length);
  return gpu?.name || L.sys_tab_gpu;
}

function draw() {
  const out = providers?.outputMap || {};
  const ds = diskList(out);
  const tabs = TABS.map((k, i) => {
    const t = tabValue(k, out, ds);
    return `<button class="tab${k === tab ? ' on' : ''}${t.alert ? ' alert' : ''}" data-tab="${k}"><span class="tab-k">${esc(TAB_NAME[k])}</span><span class="tab-v">${esc(t.v)}</span></button>`;
  }).join('');
  let body = '';
  if (tab === 'cpu') body = cpuTab(out);
  else if (tab === 'memory') body = memoryTab(out);
  else if (tab === 'disk') body = diskTab(out);
  else body = gpuTab();
  const temp = tab === 'gpu' && gpu?.temp != null ? `<span class="temp-chip${gpu.temp >= 80 ? ' hot' : ''}">\u{F050F} ${Math.round(gpu.temp)}°C</span>` : '';
  el.innerHTML = `<div class="pn"><div class="pn-head"><div class="pn-tile">${TAB_GLYPH[tab]}</div>`
    + `<div class="pn-titles"><div class="pn-title">${esc(L.sys_title)}</div><div class="pn-sub">${esc(subtitle(out, ds))}</div></div><div class="pn-side">${temp}</div></div>`
    + `<div class="tabs" style="grid-template-columns:repeat(${TABS.length}, 1fr)">${tabs}</div>${body}`
    + `<div class="pn-foot"><span><span class="key">1-${TABS.length}</span>${esc(L.sys_k_tab)}</span><span><span class="key">Esc</span>${esc(L.sys_k_close)}</span></div></div>`;
}

function show(next) {
  if (!TABS.includes(next) || next === tab) return;
  tab = next;
  try { localStorage.setItem('system.tab', tab); } catch {}
  schedule(true);
  draw();
}
el.addEventListener('click', (e) => {
  const b = e.target.closest('[data-tab]');
  if (b) show(b.dataset.tab);
});
// A right click on another gauge of the bar, with the panel already open.
window.addEventListener('storage', (e) => { if (e.key === 'system.tab' && e.newValue) show(e.newValue); });
window.addEventListener('keydown', (e) => {
  if (/^[1-9]$/.test(e.key)) show(TABS[Number(e.key) - 1]);
  else if (e.key === 'Tab') { e.preventDefault(); show(TABS[(TABS.indexOf(tab) + (e.shiftKey ? TABS.length - 1 : 1)) % TABS.length]); }
});

async function sysinfo(arg) {
  try {
    const r = await zebar.shellExec('powershell.exe', `${script} ${arg}`);
    return JSON.parse(String(r.stdout).trim());
  } catch {
    return null;
  }
}

// What each tab needs beyond the providers, asked only while it is shown.
const timers = [];
function schedule(now = false) {
  timers.splice(0).forEach(clearInterval);
  const every = (ms, fn) => { if (now) fn(); timers.push(setInterval(fn, ms)); };
  if (tab === 'cpu') {
    every(2000, async () => { cores = (await sysinfo('-Cores')) ?? cores; draw(); });
    every(5000, async () => { top = (await sysinfo('-Top')) ?? top; draw(); });
  } else if (tab === 'memory') {
    every(5000, async () => { top = (await sysinfo('-Top')) ?? top; draw(); });
  } else if (tab === 'gpu') {
    every(2000, async () => { gpu = (await sysinfo('-Gpu')) ?? gpu; draw(); });
    every(4000, async () => { gpuProcs = (await sysinfo('-GpuProcs')) ?? gpuProcs; draw(); });
  }
}

providers = zebar.createProviderGroup({
  cpu: { type: 'cpu', refreshInterval: 1000 },
  memory: { type: 'memory', refreshInterval: 1000 },
  disk: { type: 'disk', refreshInterval: 10000 },
});
providers.onOutput(draw);
sysinfo('-Info').then((v) => { info = v; draw(); });
if (hasGpu) {
  const poll = async () => { gpu = (await sysinfo('-Gpu')) ?? gpu; draw(); };
  poll();
  setInterval(poll, 5000);
}
schedule(true);
draw();
