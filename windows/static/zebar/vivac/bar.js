// The vivac bar. Plain modules, no build step and no framework: Zebar loads
// this file as it is, and so can anyone reading it.
//
// What the bar shows is decided per machine, not here: config.js is rendered
// by scripts/deploy.ps1 from render/zebar/vivac/config.js.in, so a gauge only
// exists when the hardware answers for it (a battery, a Wi-Fi adapter, an
// NVIDIA card). This file only knows how to draw each one.
import * as zebar from './zebar-client.js';
import { config } from './config.js';
import { createHoverIntent, opensPanel, panelFor, isHostPanel } from './hover.js';

const icons = await fetch('./workspace-icons.json').then((r) => r.json());

// Nerd Font glyphs, written as code points so the source stays readable.
const G = {
  wired: '\u{F0200}', wiredOff: '\u{F0202}', wifi: '\u{F05A9}', wifiOff: '\u{F05AA}',
  system: '\u{F061A}', cpu: '\u{F0EE0}', memory: '\u{F035B}', disk: '\u{F02CA}', gpu: '\u{F08AE}',
  clock: '\u{F0954}', volume: '\u{F057E}', muted: '\u{F075F}',
  battery: ['\u{F007A}', '\u{F007C}', '\u{F007E}', '\u{F0080}', '\u{F0079}'], charging: '\u{F0084}',
  desktop: '\u{F01C4}', theme: '\u25D0', power: '\u23FB', sesiones: '\u27F2',
  shield: '\u{F0565}', shieldAlert: '\u{F0ECC}',
  bluetooth: '\u{F00AF}', bluetoothOff: '\u{F00B2}', usb: '\u{F129E}',
  update: '\u{F06B0}', restart: '\u{F0709}', bug: '\u{F00E4}',
  phone: '\u{F011C}',
};

const weatherGlyph = {
  clear_day: '\u{F0599}', clear_night: '\u{F0594}', cloudy_day: '\u{F0595}', cloudy_night: '\u{F0F31}',
  light_rain_day: '\u{F0597}', light_rain_night: '\u{F0597}', heavy_rain_day: '\u{F0596}',
  heavy_rain_night: '\u{F0596}', snow_day: '\u{F0598}', snow_night: '\u{F0598}',
  thunder_day: '\u{F0593}', thunder_night: '\u{F0593}',
};

const providerConfig = {
  glazewm: { type: 'glazewm' },
  date: { type: 'date', formatting: 'HH:mm  ccc d LLL yyyy', locale: config.locale },
  cpu: { type: 'cpu', refreshInterval: 2000 },
  memory: { type: 'memory', refreshInterval: 5000 },
  disk: { type: 'disk', refreshInterval: 30000 },
  network: { type: 'network', refreshInterval: 5000 },
  audio: { type: 'audio' },
};
if (config.modules.includes('battery')) providerConfig.battery = { type: 'battery', refreshInterval: 30000 };
if (config.weather) providerConfig.weather = { type: 'weather', refreshInterval: 1800000, ...config.weather };

const providers = zebar.createProviderGroup(providerConfig);

const esc = (s) => String(s ?? '').replace(/[&<>"']/g, (c) => `&#${c.charCodeAt(0)};`);
const pill = (cls, glyph, text, title = '', attrs = '') =>
  `<div class="pill ${cls}" title="${esc(title)}"${attrs}><span class="glyph">${glyph}</span>${esc(text)}</div>`;

// ---------------------------------------------------------------- workspaces

// A window's glyph: its process name exactly, then the longest matching
// prefix, then a fragment of its title, then the default. The same lookup
// order as the source bar, keyed by process instead of Wayland class.
function glyphFor(win) {
  const proc = (win.processName || '').toLowerCase();
  if (icons.processes[proc]) return icons.processes[proc];
  const prefix = Object.keys(icons.prefixes)
    .filter((p) => proc.startsWith(p))
    .sort((a, b) => b.length - a.length)[0];
  if (prefix) return icons.prefixes[prefix];
  const title = win.title || '';
  for (const [fragment, glyph] of Object.entries(icons.titles)) {
    if (title.includes(fragment)) return glyph;
  }
  return icons.default;
}

function windowsOf(container) {
  if (!container) return [];
  if (container.type === 'window') return [container];
  return (container.children || []).flatMap(windowsOf);
}

// All ten by number, as in the source: an occupied one is followed by a glyph
// per window, the focused one is underlined, the empty ones recede. Windows
// can be minimized, which Hyprland has no notion of: those come last and dim.
// With the Windows taskbar gone the bar is the only way back to one, so each
// glyph is a button (a minimized window is restored to the state it left,
// then focused) and minimized windows take the five places first, the rest
// becoming a count, so one busy workspace cannot push the other nine off the
// bar and a minimized window is never the one hidden behind it.
const MAX_GLYPHS = 5;
const isMin = (w) => w.state?.type === 'minimized';
function drawWorkspaces(wm) {
  const byName = new Map(wm.allWorkspaces.map((w) => [w.name, w]));
  let html = '';
  for (let n = 1; n <= 10; n++) {
    const ws = byName.get(String(n));
    const wins = ws ? windowsOf(ws) : [];
    const minimized = wins.filter(isMin).slice(0, MAX_GLYPHS);
    const shown = [...wins.filter((w) => !isMin(w)).slice(0, MAX_GLYPHS - minimized.length), ...minimized];
    const cls = ['ws-item'];
    if (ws?.hasFocus) cls.push('focused');
    else if (ws?.isDisplayed) cls.push('displayed');
    if (!wins.length) cls.push('empty');
    let glyphs = shown
      .map((w) => `<span class="glyph${isMin(w) ? ' minimized' : ''}" data-win="${esc(w.id)}" title="${esc(w.title)}">${glyphFor(w)}</span>`)
      .join('');
    if (wins.length > shown.length) glyphs += `<span class="more">+${wins.length - shown.length}</span>`;
    html += `<button class="${cls.join(' ')}" data-ws="${n}">${n}${glyphs}</button>`;
  }
  // Drawn again only when something shows differently: every provider's
  // output calls this, several times a second, and a button replaced between
  // the press and the release of a click loses the click.
  const el = document.getElementById('ws');
  if (el.innerHTML !== html) el.innerHTML = html;
}

// A workspace button goes there, as Win+number does; on the one already in
// front it brings back windows that are all minimized. A window's glyph
// brings that window to the front. Answered on the press, by the strip
// itself, so it holds however often the buttons are drawn again.
document.getElementById('ws').addEventListener('pointerdown', (e) => {
  if (e.button !== 0) return;
  const wm = providers.outputMap.glazewm;
  if (!wm) return;
  const glyph = e.target.closest('[data-win]');
  if (glyph) {
    focusWindow(wm, allWindows(wm).find((w) => w.id === glyph.dataset.win));
    return;
  }
  const b = e.target.closest('button[data-ws]');
  if (!b) return;
  const ws = wm.allWorkspaces.find((w) => w.name === b.dataset.ws);
  if (ws?.hasFocus) restoreHidden(wm, ws);
  else wm.runCommand(`focus --workspace ${b.dataset.ws}`);
});

const allWindows = (wm) => wm.allWorkspaces.flatMap(windowsOf);
async function focusWindow(wm, win) {
  if (!win) return;
  if (isMin(win)) await wm.runCommand('toggle-minimized', win.id);
  await wm.runCommand(`focus --container-id ${win.id}`);
}

// Arriving on a workspace whose windows are all minimized (Spotify or Steam
// started to the tray, say) would show an empty desktop with no taskbar to
// bring them back from, so they are restored on arrival, by Win+number as
// much as by a click. Only a change of workspace triggers it: minimizing the
// last window where you are leaves it minimized.
async function restoreHidden(wm, ws) {
  const wins = windowsOf(ws);
  if (!wins.length || !wins.every(isMin)) return;
  for (const w of wins) await wm.runCommand('toggle-minimized', w.id);
  await wm.runCommand(`focus --container-id ${wins[wins.length - 1].id}`);
}

// A window that arrives maximized or fullscreen (File Explorer reopens the
// way it was last closed, so do many programs) would sit in front of the
// tiles, the only thing on its workspace with depth. Every window new to the
// window manager in that state joins the tiling instead, on whichever
// workspace it opened. Only on arrival: one made fullscreen afterwards, with
// MOD+F, was meant to be.
let knownWindows = null;
function tileArrivals(wm) {
  const wins = allWindows(wm);
  if (knownWindows === null) {
    knownWindows = new Set(wins.map((w) => w.id));
    return;
  }
  for (const w of wins) {
    if (knownWindows.has(w.id)) continue;
    knownWindows.add(w.id);
    if (w.state?.type === 'fullscreen') wm.runCommand('set-tiling', w.id);
  }
  if (knownWindows.size > 2000) knownWindows = new Set(wins.map((w) => w.id));
}

let lastWs;
function restoreOnArrival(wm) {
  const ws = wm.focusedWorkspace;
  if (!ws || ws.name === lastWs) return;
  const first = lastWs === undefined;
  lastWs = ws.name;
  if (!first) restoreHidden(wm, ws);
}

function drawTitle(wm) {
  const el = document.getElementById('title');
  const focused = wm.focusedContainer;
  if (focused && focused.type === 'window' && focused.title) {
    el.className = 'title';
    el.textContent = focused.title.length > 60 ? focused.title.slice(0, 59) + '\u2026' : focused.title;
  } else {
    el.className = 'title empty';
    el.textContent = `${G.desktop} ${config.labels.desktop}`;
  }
}

// -------------------------------------------------------------------- gauges

// Two network gauges, one per kind of adapter, each with its address inline:
// a pulled cable and a dropped Wi-Fi read differently. An address Windows
// made up for itself (169.254.x.x, no DHCP answer) is a link with no address,
// the case worth a look, so it takes the accent instead of passing as an IP.
const realAddress = (i) => (i.ipv4Addresses || []).find((a) => !a.startsWith('169.254.'));
const selfAssigned = (i) => (i.ipv4Addresses || []).some((a) => a.startsWith('169.254.'));
// A click opens vivac's network panel (lib/Network.psm1).
const netPill = (cls, glyph, title) =>
  `<button class="pill ${cls}" data-act="network" title="${esc(title)}"><span class="glyph">${glyph}</span></button>`;
function networkPill(net, kind) {
  const ifaces = (net?.interfaces || []).filter((i) => i.type === (kind === 'wired' ? 'ethernet' : 'wifi'));
  const up = ifaces.find(realAddress);
  const linked = ifaces.find(selfAssigned);
  const glyph = kind === 'wired' ? G.wired : G.wifi;
  // Glyph only, the state in its colour and the detail on hover: the clock
  // stays at the true middle only if the right half fits in half the bar.
  if (up) {
    let tip = up.friendlyName || up.name;
    if (kind === 'wireless' && net.defaultGateway?.ssid) tip = `${net.defaultGateway.ssid} ${net.defaultGateway.signalStrength ?? ''}%  ${tip}`;
    return netPill('net', glyph, `${realAddress(up)}  ${tip}`);
  }
  if (linked) return netPill('net linked', glyph, `${config.labels.no_address}  ${linked.friendlyName || linked.name}`);
  if (kind === 'wired') return netPill('net disconnected', G.wiredOff, `${config.labels.wired}: ${config.labels.no_link}`);
  return netPill('net disconnected', G.wifiOff, `Wi-Fi: ${config.labels.not_connected}`);
}

let gpuTemp = null;
let gpuLoad = null;
async function pollGpu() {
  try {
    const r = await zebar.shellExec('nvidia-smi', '--query-gpu=temperature.gpu,utilization.gpu --format=csv,noheader,nounits');
    const [t, u] = String(r.stdout).trim().split(',').map((x) => parseInt(x, 10));
    gpuTemp = Number.isFinite(t) ? t : null;
    gpuLoad = Number.isFinite(u) ? u : null;
  } catch {
    gpuTemp = null;
    gpuLoad = null;
  }
}
if (config.modules.includes('gpu')) {
  pollGpu();
  setInterval(pollGpu, 5000);
}

function batteryPill(b) {
  if (!b) return '';
  const pct = Math.round(b.chargePercent);
  const glyph = b.isCharging ? G.charging : G.battery[Math.min(4, Math.floor(pct / 20.01))];
  const cls = pct <= 15 ? 'battery critical' : pct <= 30 ? 'battery warning' : 'battery';
  return pill(cls, glyph, `${pct}%`);
}

function diskPill(d) {
  const sys = (d?.disks || []).find((x) => /^C:/i.test(x.mountPoint));
  if (!sys) return '';
  const used = 100 - Math.round((sys.availableSpace.bytes / sys.totalSpace.bytes) * 100);
  return pill(`disk sys-gauge${used > 90 ? ' warning' : ''}`, G.disk, `${used}%`, sys.mountPoint, ' data-act="sysgauge" data-tab="disk"');
}

function audioPill(a) {
  const dev = a?.defaultPlaybackDevice;
  if (!dev) return '';
  if (dev.isMuted) return `<div class="pill audio muted" data-act="mute">${G.muted}</div>`;
  return `<div class="pill audio" data-act="mute" title="${esc(dev.name)}"><span class="glyph">${G.volume}</span>${Math.round(dev.volume)}%</div>`;
}

// Defender's state, read by bin/vivac-security.ps1 in place of Windows
// Security's tray icon: always the shield alone, coloured and with the
// alert glyph when something needs a look, and the words only in the
// tooltip (a sentence on the bar shoves every pill beside it, e.g. the
// Malwarebytes trial countdown). Clicking it opens the security surface
// and reads the state again a little later, when a scan or update started
// from there may have changed it.
let security = null;
async function pollSecurity() {
  try {
    const r = await zebar.shellExec(
      'powershell.exe',
      `-NoProfile -NonInteractive -ExecutionPolicy Bypass -File ${config.repo}\\bin\\vivac-security.ps1 -Status`,
    );
    security = JSON.parse(String(r.stdout).trim());
  } catch {
    security = null;
  }
  draw();
}
if (config.modules.includes('security')) {
  pollSecurity();
  setInterval(pollSecurity, 600000);
}

function securityPill() {
  if (!security) return '';
  const cls = { ok: 'security', warn: 'security warning', alert: 'security critical' }[security.state] || 'security';
  const glyph = security.state === 'ok' ? G.shield : G.shieldAlert;
  return `<button class="pill ${cls}" data-act="security" title="${esc(security.tip)}"><span class="glyph">${glyph}</span></button>`;
}

// The two buttons at the end open vivac's own surfaces, through the resident
// host's pipe as the keys do, or by starting the surface when no host
// answers. Zebar only lets a widget run what its zpack.json grants, and that
// grant names these verbs and nothing else.
function launch(verb) {
  zebar.shellSpawn(
    'cmd.exe',
    `/c echo ${verb}>\\\\.\\pipe\\${config.pipe} 2>nul || conhost.exe --headless powershell.exe -NoProfile -ExecutionPolicy Bypass -File ${config.repo}\\bin\\vivac.ps1 ${verb}`,
  );
}

// What the notification area answered for, drawn by vivac instead: the bar
// keeps no program's own icon (they took the room the gauges need), only
// the few things a machine has to reach from anywhere. bin/vivac-tray.ps1
// reads them, the same way bin/vivac-security.ps1 reads Defender: Bluetooth,
// a restart Windows Update waits for and the antivirus every minute, the
// pending updates every half hour, since Windows Update takes seconds to say.
// USB volumes use the physical bus: USB hard disks can report as fixed.
const trayScript = `-NoProfile -NonInteractive -ExecutionPolicy Bypass -File ${config.repo}\\bin\\vivac-tray.ps1`;
let tray = null;
let updates = null;
let usbDrives = [];
async function pollDrives() {
  const result = await trayJson('-Drives');
  if (result) usbDrives = result.drives || [];
  draw();
}
if (config.modules.includes('usb')) {
  pollDrives();
  setInterval(pollDrives, 15000);
}
async function trayJson(arg) {
  try {
    const r = await zebar.shellExec('powershell.exe', `${trayScript} ${arg}`);
    return JSON.parse(String(r.stdout).trim());
  } catch {
    return null;
  }
}
async function pollTray() { tray = await trayJson('-Status'); draw(); }
async function pollUpdates() { updates = await trayJson('-Updates'); draw(); }
const wantsTray = ['bluetooth', 'updates', 'antivirus'].some((m) => config.modules.includes(m));
if (wantsTray) {
  pollTray();
  setInterval(pollTray, 60000);
}
if (config.modules.includes('updates')) {
  pollUpdates();
  setInterval(pollUpdates, 1800000);
}
const trayAct = (arg, later = 3000) => {
  zebar.shellSpawn('powershell.exe', `${trayScript} ${arg}`);
  setTimeout(pollTray, later);
};

// Glyph only, the state in its colour: on in the foreground, off receding.
// Click opens vivac's Bluetooth panel (lib/Bluetooth.psm1), to connect, pair
// or forget; right click turns the radio on or off.
function bluetoothPill() {
  if (typeof tray?.bluetooth !== 'boolean') return '';
  const on = tray.bluetooth;
  const tip = `Bluetooth: ${on ? config.labels.bt_on : config.labels.bt_off}`;
  return `<button class="pill bluetooth${on ? '' : ' off'}" data-act="bluetooth" title="${esc(tip)}"><span class="glyph">${on ? G.bluetooth : G.bluetoothOff}</span></button>`;
}

// One letter per USB volume: click to browse, right click for its actions.
function usbPill(d) {
  const drives = usbDrives;
  if (!drives.length) return '';
  return drives
    .map((x) => {
      const letter = x.letter.toUpperCase();
      const capacity = `${(x.size / 1e9).toFixed(0)} GB`;
      const tip = `${letter} ${x.name} ${x.label || ''} (${capacity})\n${config.labels.usb_actions}`;
      return `<button class="pill usb" data-act="eject" data-drive="${letter}" title="${esc(tip)}"><span class="glyph">${G.usb}</span>${letter}</button>`;
    })
    .join('');
}

// The phone, through KDE Connect (bin/vivac-phone.ps1, lib/Phone.psm1): a
// glyph while a paired phone is reachable, its name on hover, a count when
// there are several; nothing at all without KDE Connect or a phone. Asked
// every minute; a click opens the menu on its Phone category.
let phone = null;
async function pollPhone() {
  try {
    const r = await zebar.shellExec(
      'powershell.exe',
      `-NoProfile -NonInteractive -ExecutionPolicy Bypass -File ${config.repo}\\bin\\vivac-phone.ps1 -Status`,
    );
    phone = JSON.parse(String(r.stdout).trim());
  } catch {
    phone = null;
  }
  draw();
}
if (config.modules.includes('phone')) {
  pollPhone();
  setInterval(pollPhone, 60000);
}

function phonePill() {
  const phones = Array.isArray(phone?.phones) ? phone.phones.filter((p) => p && typeof p.name === 'string') : [];
  if (!phones.length) return '';
  const tip = phones.map((p) => `${p.name}: ${config.labels.phone_reachable}`).join('\n');
  const count = phones.length > 1 ? `<span class="badge">${phones.length}</span>` : '';
  return `<button class="pill phone" data-act="phone" title="${esc(tip)}"><span class="glyph">${G.phone}</span>${count}</button>`;
}

// The update icon, always there at the bar's right end: it opens vivac's
// updates panel (lib/Updates.psm1). A badge counts what Windows Update and
// winget have waiting, in the urgent colour with a shield when a security
// update is among them; the accent all over says Windows waits for a restart.
function updatesPill() {
  if (tray?.reboot) return `<button class="pill updates reboot" data-act="updates" title="${esc(config.labels.reboot)}"><span class="glyph">${G.restart}</span></button>`;
  const os = updates?.count || 0;
  const apps = updates?.apps || 0;
  const sec = updates?.security || 0;
  if (!os && !apps) return `<button class="pill updates" data-act="updates" title="${esc(config.labels.updates_none)}"><span class="glyph">${G.update}</span></button>`;
  const tip = [];
  if (sec) tip.push(`${config.labels.updates_security}: ${sec}`);
  if (os) tip.push(`${config.labels.updates}: ${updates.titles.join(' \u00B7 ')}`);
  if (apps) tip.push(`${config.labels.updates_apps}: ${updates.appTitles.join(' \u00B7 ')}`);
  const cls = sec ? 'pending security' : 'pending';
  const glyph = sec ? G.shieldAlert : G.update;
  return `<button class="pill updates ${cls}" data-act="updates" title="${esc(tip.join('\n'))}"><span class="glyph">${glyph}</span><span class="badge">${os + apps}</span></button>`;
}

// The right block reads in groups, left to right, with a rule between them,
// in the source bar's order: the links; the machine (one chip that unfolds
// into its gauges); Bluetooth; the volume and the drives; the shield; the
// saved sessions; the theme; the update icon; the power button.
// config.modules says which exist; this says where they sit. (The antivirus
// lives in the shield; the other pills stand in for a tray of program icons.)
const GROUPS = [
  ['wireless', 'wired', 'phone'],
  ['system', 'battery'],
  ['bluetooth'],
  ['audio', 'usb'],
  ['security'],
  ['sesiones'],
  ['theme'],
  ['updates'],
  ['power'],
];
// The gauges the system chip folds away: click the chip and they unfold beside
// it, click again and they fold. Which ones exist is the machine's facts.
const DRAWER = ['cpu', 'memory', 'disk', 'gpu'];
const modules = config.modules.includes('system') || !DRAWER.some((m) => config.modules.includes(m)) ? config.modules : ['system', ...config.modules];
let sysOpen = false;

const rate = (v, warn, crit) => (v >= crit ? 'critical' : v >= warn ? 'warning' : '');
const worse = (a, b) => ['', 'warning', 'critical'].indexOf(a) >= ['', 'warning', 'critical'].indexOf(b) ? a : b;

// One chip for the whole machine, the processor's use as its text, every
// gauge in its tooltip and the class of the worst one, so a full disk or a hot
// card shows on the folded chip too.
function systemChip(out) {
  const lines = [];
  let worst = '';
  if (out.cpu) {
    lines.push(`${config.labels.cpu}: ${Math.round(out.cpu.usage)}%`);
    worst = worse(worst, rate(out.cpu.usage, 85, 95));
  }
  if (out.memory) {
    lines.push(`${config.labels.memory}: ${Math.round(out.memory.usage)}% (${(out.memory.usedMemory / 1024 ** 3).toFixed(1)} / ${(out.memory.totalMemory / 1024 ** 3).toFixed(1)} GB)`);
    worst = worse(worst, rate(out.memory.usage, 90, 95));
  }
  for (const d of out.disk?.disks || []) {
    if (!d.totalSpace?.bytes) continue;
    const pct = Math.round(100 - (d.availableSpace.bytes / d.totalSpace.bytes) * 100);
    lines.push(`${d.mountPoint.replace(/\\$/, '')} ${pct}%${pct > 90 ? ' \u26A0' : ''}`);
    if (pct > 90) worst = worse(worst, 'warning');
  }
  if (gpuTemp !== null) {
    lines.push(`GPU: ${gpuLoad !== null ? `${gpuLoad}% \u00B7 ` : ''}${gpuTemp}\u00B0C`);
    worst = worse(worst, rate(gpuTemp, 80, 90));
  }
  lines.push(config.labels.sys_bar_click);
  const text = out.cpu ? `${Math.round(out.cpu.usage)}%` : '';
  return `<button class="pill sys-chip ${worst}" data-act="sys" title="${esc(lines.join('\n'))}"><span class="glyph">${G.system}</span>${esc(text)}</button>`;
}

function drawerPills(out) {
  if (!sysOpen) return '';
  return DRAWER.filter((m) => config.modules.includes(m)).map((m) => modulePill(m, out)).join('');
}

function modulePill(m, out) {
  switch (m) {
    case 'wireless': return networkPill(out.network, 'wireless');
    case 'wired': return networkPill(out.network, 'wired');
    case 'system': return systemChip(out) + drawerPills(out);
    case 'cpu': return out.cpu ? pill(`cpu sys-gauge${out.cpu.usage > 85 ? ' high' : ''}`, G.cpu, `${Math.round(out.cpu.usage)}%`, '', ' data-act="sysgauge" data-tab="cpu"') : '';
    case 'memory': return out.memory ? pill(`memory sys-gauge ${rate(out.memory.usage, 90, 95)}`, G.memory, `${Math.round(out.memory.usage)}%`, '', ' data-act="sysgauge" data-tab="memory"') : '';
    case 'disk': return diskPill(out.disk);
    case 'gpu': return gpuTemp !== null ? pill(`gpu sys-gauge ${gpuTemp >= 90 ? 'critical' : gpuTemp >= 80 ? 'warning' : ''}`, G.gpu, `${gpuTemp}\u00B0C`, '', ' data-act="sysgauge" data-tab="gpu"') : '';
    case 'battery': return batteryPill(out.battery);
    case 'audio': return audioPill(out.audio);
    case 'security': return securityPill();
    case 'bluetooth': return bluetoothPill();
    case 'usb': return usbPill(out.disk);
    case 'updates': return updatesPill();
    case 'phone': return phonePill();
    case 'theme': return `<button class="pill theme" data-act="theme" title="${esc(config.labels.theme)}">${G.theme}</button>`;
    // sesiones (13-11): clic = restaurar la última foto de los escritorios; clic derecho = guardarla (bin\sesiones.ps1)
    case 'sesiones': return `<button class="pill sesiones" data-act="sesiones" title="Sesiones · clic: restaurar · clic derecho: guardar">${G.sesiones}</button>`;
    case 'power': return `<button class="pill power" data-act="power" title="${esc(config.labels.power)}">${G.power}</button>`;
  }
  return '';
}

function drawRight(out) {
  // A group with nothing to show leaves no rule behind; a module this bar
  // does not group still shows, at the end, rather than vanishing.
  const grouped = [...GROUPS.flat(), ...DRAWER];
  const groups = [...GROUPS, modules.filter((m) => !grouped.includes(m))]
    // sesiones is the user's own tool (bin\sesiones.ps1), not a config module: always shown
    .map((g) => g.filter((m) => m === 'sesiones' || modules.includes(m)).map((m) => modulePill(m, out)).join(''))
    .filter(Boolean);
  const el = document.getElementById('right');
  el.innerHTML = groups.join('<span class="sep"></span>');
  // The panel a button opens on hover is its tooltip; the others keep theirs.
  el.querySelectorAll('[data-act]').forEach((b) => { if (opensPanel(b.dataset.act)) b.removeAttribute('title'); });
  el.querySelectorAll('[data-act]').forEach((b) => {
    const act = b.dataset.act;
    if (act === 'mute') {
      // Both clicks reach the themed device controls. Mute is available
      // inside the panel; the wheel adjusts the default output directly.
      b.addEventListener('click', () => launch('sound'));
      b.addEventListener('contextmenu', (e) => {
        e.preventDefault();
        launch('sound');
      });
      b.addEventListener('wheel', (e) => {
        const dev = out.audio?.defaultPlaybackDevice;
        if (!dev) return;
        const next = Math.max(0, Math.min(100, Math.round(dev.volume + (e.deltaY < 0 ? 5 : -5))));
        out.audio.setVolume(next);
      });
    } else if (act === 'sesiones') {
      const ses = (verbo) => zebar.shellSpawn('conhost.exe', `--headless powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\\Users\\alvar\\bin\\sesiones.ps1 ${verbo}`);
      b.addEventListener('click', () => ses('restaurar'));
      b.addEventListener('contextmenu', (e) => { e.preventDefault(); ses('guardar'); });
    } else if (act === 'sys') {
      // Unfolds the gauges, or folds them; the right button opens the panel.
      b.addEventListener('click', () => { sysOpen = !sysOpen; draw(); });
      b.addEventListener('contextmenu', (e) => { e.preventDefault(); openSystem('cpu'); });
    } else if (act === 'sysgauge') {
      b.addEventListener('click', () => { sysOpen = false; draw(); });
      b.addEventListener('contextmenu', (e) => { e.preventDefault(); openSystem(b.dataset.tab); });
    } else if (act === 'security') {
      b.addEventListener('click', () => {
        launch(act);
        setTimeout(pollSecurity, 90000);
      });
    } else if (act === 'bluetooth') {
      b.addEventListener('click', () => {
        launch('bluetooth');
        setTimeout(pollTray, 30000);
      });
      b.addEventListener('contextmenu', (e) => {
        e.preventDefault();
        trayAct('-Bluetooth');
      });
    } else if (act === 'eject') {
      b.addEventListener('click', () => {
        zebar.shellSpawn('powershell.exe', `${trayScript} -Browse ${b.dataset.drive}`);
      });
      b.addEventListener('contextmenu', (e) => {
        e.preventDefault();
        zebar.shellSpawn('powershell.exe', `${trayScript} -DriveMenu ${b.dataset.drive}`);
      });
    } else if (act === 'updates') {
      // What the panel installs shows here on the next polls.
      b.addEventListener('click', () => {
        launch('updates');
        setTimeout(pollTray, 60000);
        setTimeout(pollUpdates, 300000);
      });
    } else {
      b.addEventListener('click', () => launch(act));
    }
  });
}

function drawCenter(out) {
  document.getElementById('clock').innerHTML = out.date ? `<span class="glyph">${G.clock}</span>${esc(out.date.formatted)}` : '';
  const w = out.weather;
  const el = document.getElementById('weather');
  if (w) {
    el.style.display = '';
    el.innerHTML = `<span class="glyph">${weatherGlyph[w.status] || ''}</span>${Math.round(w.celsiusTemp)}\u00B0C`;
  } else {
    el.style.display = 'none';
  }
}

function draw() {
  const out = providers.outputMap;
  if (out.glazewm) {
    tileArrivals(out.glazewm);
    restoreOnArrival(out.glazewm);
    drawWorkspaces(out.glazewm);
    drawTitle(out.glazewm);
  }
  drawCenter(out);
  drawRight(out);
}

// Resting the pointer on a button opens its panel, the one a click opens: the
// WPF panels (network, sound, ...) through the resident host, the month, the
// forecast and the system gauges as popups of their own (calendar.html,
// forecast.html, system.html), since this widget is only as tall as the bar.
// hover.js decides what a button opens and times the rest (300 ms); how the
// panel closes again is the panel's (lib\Hover.psm1, popup.js). The two sides
// of a popup talk through localStorage, which every widget of the pack
// shares: popup.<name>.hot says the pointer rested on ("1:<ms>") or left
// ("0:<ms>") the button, popup.<name>.pin says it was clicked, and the popup
// stamps popup.<name>.alive while it is open.
const stamp = (key) => { try { localStorage.setItem(key, String(Date.now())); } catch {} };
const mark = (key, value) => { try { localStorage.setItem(key, `${value}:${Date.now()}`); } catch {} };
const fresh = (key, ms) => { try { return Date.now() - Number(localStorage.getItem(key) || 0) < ms; } catch { return false; } };

// A line for the resident host. Only the pipe: with no host running there is
// nothing to open by hover, and starting a panel for a mere rest would be
// worse than doing nothing.
const hostSay = (line) => zebar.shellSpawn('cmd.exe', `/c echo ${line}>\\\\.\\pipe\\${config.pipe} 2>nul`);

// A key is a panel, and for the system panel the tab as well: system:disk.
const popupOf = (key) => key.split(':')[0];

function startPopup(widget) {
  if (fresh(`popup.${widget}.alive`, 1200)) return;
  stamp(`popup.${widget}.alive`);
  // Opened by preset, the path the CLI takes too: zebar 3.0.3's
  // startWidget with a placement built here never opened a window. The
  // presets in zpack.json sit each popup under its pill, which keeps its
  // place because the middle column is centred on the screen.
  zebar.startWidgetPreset(widget, 'default', {}).catch((e) => {
    try { localStorage.setItem('popup.error', `${widget}: ${e?.message ?? e}`); } catch {}
  });
}

const intent = createHoverIntent({
  setTimer: (fn, ms) => setTimeout(fn, ms),
  clearTimer: (id) => clearTimeout(id),
  onRest(key) {
    const panel = popupOf(key);
    if (isHostPanel(panel)) { hostSay(`hover ${key}`); return; }
    if (panel === 'system') { try { localStorage.setItem('system.tab', key.split(':')[1] || 'cpu'); } catch {} }
    mark(`popup.${panel}.hot`, 1);
    startPopup(panel);
  },
  onLeave(key) {
    const panel = popupOf(key);
    if (isHostPanel(panel)) hostSay(`hover-leave ${key}`);
    else mark(`popup.${panel}.hot`, 0);
  },
});

// The key of the button under the pointer, or null. The right-hand side is
// drawn again on every sample, so the pointer is followed through the
// container (events of a button that is replaced under it would be lost).
function keyAt(target) {
  const b = target.closest?.('[data-act]');
  if (!b) return null;
  const act = b.dataset.act;
  const panel = panelFor(act, { drive: b.dataset.drive });
  if (!panel) return null;
  return act === 'sys' ? 'system:cpu' : act === 'sysgauge' ? `system:${b.dataset.tab}` : panel;
}
const right = document.getElementById('right');
right.addEventListener('pointermove', (e) => intent.target(keyAt(e.target)));
right.addEventListener('pointerleave', () => intent.target(null));
for (const [id, act] of [['clock', 'clock'], ['weather', 'weather']]) {
  const el = document.getElementById(id);
  el.addEventListener('mouseenter', () => intent.target(panelFor(act)));
  el.addEventListener('mouseleave', () => intent.target(null));
}
// A click is the old behaviour (the verbs above), and pins a popup that is
// open by hover: the host does the same for its panels, on the verb.
document.addEventListener('click', (e) => {
  const b = e.target.closest?.('[data-act], #clock, #weather');
  if (!b) return;
  intent.click();
  const panel = b.id === 'clock' ? 'calendar' : b.id === 'weather' ? 'forecast' : keyAt(b) && popupOf(keyAt(b));
  if (panel && !isHostPanel(panel)) mark(`popup.${panel}.pin`, 1);
}, true);

// The system panel is also opened on purpose, by a right click on the chip or
// on one of its gauges, and then holds the keyboard (Escape or a click
// elsewhere closes it). The tab it opens on goes by localStorage, which a
// panel already open follows too.
function openSystem(tab) {
  try { localStorage.setItem('system.tab', tab); } catch {}
  mark('popup.system.pin', 1);
  if (fresh('popup.system.alive', 1200)) return;
  mark('popup.system.hot', 0);
  startPopup('system');
}

// The last two minutes of processor and memory use, for the graph in their
// popups: a popup lives only while hovered, the bar all the time.
const history = { cpu: [], memory: [], gpu: [] };
let lastSample = 0;
providers.onOutput(() => {
  const out = providers.outputMap;
  if (Date.now() - lastSample < 2000) return;
  lastSample = Date.now();
  for (const k of ['cpu', 'memory']) {
    if (!out[k]) continue;
    history[k].push(Math.round(out[k].usage));
    if (history[k].length > 60) history[k].shift();
  }
  if (gpuLoad !== null) {
    history.gpu.push(gpuLoad);
    if (history.gpu.length > 60) history.gpu.shift();
  }
  try { localStorage.setItem('gauge.history', JSON.stringify(history)); } catch {}
});

// Scrolling over the workspace strip walks them, as in the source bar.
document.getElementById('ws').addEventListener('wheel', (e) => {
  const wm = providers.outputMap.glazewm;
  if (!wm) return;
  wm.runCommand(e.deltaY < 0 ? 'focus --prev-active-workspace' : 'focus --next-active-workspace');
});

providers.onOutput(draw);
draw();

// Proof of life for bin/vivac-bar-watch.ps1, which restarts Zebar when this
// goes stale. Stamped only while the bar is really drawn: its stylesheet
// applied and the workspaces in place. A page that loaded blank, half a
// module graph or no styles, never stamps, and is restarted.
function drawn() {
  const bar = document.getElementById('bar');
  return getComputedStyle(bar).position === 'absolute' && document.getElementById('ws').childElementCount > 0;
}
function stampAlive() {
  if (drawn()) zebar.shellExec('cmd.exe', '/d /c cd /d %LOCALAPPDATA%\\vivac && type nul>bar.alive').catch(() => {});
}
setTimeout(stampAlive, 3000);
setInterval(stampAlive, 30000);

// A theme switch rewrites styles.css; the bar takes it the moment it lands,
// without a restart (a restarted Zebar is gone for seconds, and the wallpaper
// has long changed). The file is re-read a few times a second, and when its
// text differs it goes into a <style> of its own, replacing the last one, so
// the swap is one repaint; a file caught half written (no closing brace yet)
// waits for the next read. A stamp follows, as the proof the new styles drew
// (lib/Bar.psm1, Test-VivacBarProven, scripts/deploy.ps1 waits for it).
let liveCss = null;
async function restyle() {
  let css;
  try { css = await (await fetch('./styles.css', { cache: 'no-store' })).text(); } catch { return; }
  if (css === liveCss || !css.trim().endsWith('}')) return;
  const first = liveCss === null;
  liveCss = css;
  if (first) return; // what the page loaded with
  let live = document.getElementById('live-styles');
  if (!live) {
    live = document.createElement('style');
    live.id = 'live-styles';
    document.head.appendChild(live);
  }
  live.textContent = css;
  for (const link of document.querySelectorAll('link[rel="stylesheet"]')) link.disabled = true;
  stampAlive();
}
restyle();
setInterval(restyle, 300);
