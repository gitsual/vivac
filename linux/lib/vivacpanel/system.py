"""System: processor, memory, disks and graphics card in one panel with tabs.

The four hover popups of the Windows bar (windows/static/zebar/vivac/gauge.js:
cpu.html, memory.html, disk.html, gpu.html) as one panel: a tab for each, the
number that matters first as a hero, what is behind it under, and the
programs using the most. It reads /proc, /sys, `df` and `nvidia-smi` itself
and refreshes every two seconds while it is open.

The pure half (the readings) imports no GTK. Where it reads is overridable so
the tests can feed it a fake machine: VIVAC_PROC (/proc), VIVAC_SYS (/sys),
VIVAC_DF (df), VIVAC_NVIDIA_SMI (nvidia-smi).
"""
from __future__ import annotations

import os
import re
import shutil
import subprocess
import time
from dataclasses import dataclass, field
from pathlib import Path

TABS = ("cpu", "memory", "disk", "gpu")


def _proc() -> Path:
    return Path(os.environ.get("VIVAC_PROC") or "/proc")


def _sys() -> Path:
    return Path(os.environ.get("VIVAC_SYS") or "/sys")


def _read(path: Path) -> str:
    try:
        return path.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return ""


# ---- processor -----------------------------------------------------------

def read_cpu() -> dict:
    """/proc/stat as {"total": (busy, all), "cores": [(busy, all), ...]} in
    ticks; busy is everything but idle and iowait."""
    out: dict = {"total": (0, 0), "cores": []}
    for line in _read(_proc() / "stat").splitlines():
        if not line.startswith("cpu"):
            continue
        name, *fields = line.split()
        nums = [int(x) for x in fields if x.isdigit()]
        total = sum(nums[:8])
        idle = (nums[3] if len(nums) > 3 else 0) + (nums[4] if len(nums) > 4 else 0)
        if name == "cpu":
            out["total"] = (total - idle, total)
        else:
            out["cores"].append((total - idle, total))
    return out


def cpu_usage(prev: dict, cur: dict) -> tuple[float, list[float]]:
    """Use in percent over the time between two readings: of the whole
    processor, and of each thread."""
    def pct(a, b) -> float:
        d_all = b[1] - a[1]
        return max(0.0, min(100.0, 100.0 * (b[0] - a[0]) / d_all)) if d_all > 0 else 0.0
    cores = [pct(a, b) for a, b in zip(prev["cores"], cur["cores"])]
    return pct(prev["total"], cur["total"]), cores


def loadavg() -> tuple[float, float, float]:
    parts = _read(_proc() / "loadavg").split()
    try:
        return float(parts[0]), float(parts[1]), float(parts[2])
    except (IndexError, ValueError):
        return 0.0, 0.0, 0.0


def cpu_info() -> dict:
    """Model, physical cores, threads and the average clock in MHz."""
    model, mhz, ids, threads = "", [], set(), 0
    phys = core = None
    for line in _read(_proc() / "cpuinfo").splitlines() + [""]:
        key, _, value = line.partition(":")
        key, value = key.strip(), value.strip()
        if key == "model name" and not model:
            model = re.sub(r"\s+", " ", value)
        elif key == "cpu MHz":
            try:
                mhz.append(float(value))
            except ValueError:
                pass
        elif key == "physical id":
            phys = value
        elif key == "core id":
            core = value
        elif key == "processor":
            threads += 1
        elif not line and core is not None:
            ids.add((phys, core))
            phys = core = None
    return {"model": model, "cores": len(ids) or threads, "threads": threads,
            "mhz": int(round(sum(mhz) / len(mhz))) if mhz else 0}


_CPU_SENSORS = ("k10temp", "coretemp", "zenpower", "cpu_thermal", "acpitz")


def temperature() -> float | None:
    """The processor's temperature in Celsius, from the hwmon of its driver
    (not the first hwmon, which is often an SSD)."""
    found = {}
    for hw in sorted((_sys() / "class" / "hwmon").glob("hwmon*")):
        name = _read(hw / "name").strip()
        raw = _read(hw / "temp1_input").strip()
        if name in _CPU_SENSORS and raw.lstrip("-").isdigit():
            found.setdefault(name, int(raw) / 1000)
    for name in _CPU_SENSORS:
        if name in found:
            return found[name]
    return None


# ---- memory ----------------------------------------------------------------

@dataclass
class Mem:
    total: int
    used: int
    available: int
    swap_total: int
    swap_used: int


def memory() -> Mem:
    kb = {}
    for line in _read(_proc() / "meminfo").splitlines():
        m = re.match(r"(\w+):\s+(\d+)", line)
        if m:
            kb[m.group(1)] = int(m.group(2)) * 1024
    total = kb.get("MemTotal", 0)
    available = kb.get("MemAvailable", kb.get("MemFree", 0))
    swap = kb.get("SwapTotal", 0)
    return Mem(total, total - available, available, swap, swap - kb.get("SwapFree", 0))


# ---- programs --------------------------------------------------------------

def read_procs() -> dict[int, tuple[str, int, int]]:
    """{pid: (name, cpu ticks, resident bytes)} for every process we may read."""
    page = os.sysconf("SC_PAGE_SIZE")
    out = {}
    try:
        entries = [e for e in _proc().iterdir() if e.name.isdigit()]
    except OSError:
        return out
    for e in entries:
        stat = _read(e / "stat")
        head, _, tail = stat.rpartition(")")
        fields = tail.split()
        if not head or len(fields) < 13:
            continue
        name = head.partition("(")[2]
        try:
            ticks = int(fields[11]) + int(fields[12])
            rss = int(_read(e / "statm").split()[1]) * page
        except (ValueError, IndexError):
            continue
        out[int(e.name)] = (name, ticks, rss)
    return out


def top_cpu(prev: dict, cur: dict, dt: float, n: int = 5, clk: int | None = None,
            ncpu: int | None = None) -> list[tuple[str, float]]:
    """Programs by use of the whole machine over dt seconds, the processes of
    one program (same name) added up. A process that is new has no past."""
    clk = clk or os.sysconf("SC_CLK_TCK")
    ncpu = ncpu or cpu_info()["threads"] or os.cpu_count() or 1
    sums: dict[str, int] = {}
    for pid, (name, ticks, _rss) in cur.items():
        if pid in prev:
            sums[name] = sums.get(name, 0) + max(0, ticks - prev[pid][1])
    scale = 100.0 / (clk * max(dt, 0.001) * ncpu)
    ranked = sorted(((name, d * scale) for name, d in sums.items()), key=lambda x: (-x[1], x[0]))
    return ranked[:n]


def top_mem(cur: dict, n: int = 5) -> list[tuple[str, int]]:
    sums: dict[str, int] = {}
    for name, _ticks, rss in cur.values():
        sums[name] = sums.get(name, 0) + rss
    return sorted(sums.items(), key=lambda x: (-x[1], x[0]))[:n]


# ---- disks -------------------------------------------------------------------

@dataclass
class Disk:
    device: str
    fstype: str
    mount: str
    total: int
    used: int
    avail: int
    percent: float
    alert: bool


_NOT_REAL = {"tmpfs", "devtmpfs", "efivarfs", "squashfs", "overlay", "ramfs", "proc", "sysfs", "devpts",
             "cgroup", "cgroup2", "securityfs", "debugfs", "tracefs", "configfs", "fusectl", "mqueue",
             "hugetlbfs", "pstore", "bpf", "autofs", "binfmt_misc", "fuse.portal", "fuse.gvfsd-fuse",
             "iso9660", "nsfs", "rpc_pipefs"}


def disks() -> list[Disk]:
    """Each real filesystem mounted, once (a device mounted in several places,
    as btrfs subvolumes are, counts under its shortest path), by path."""
    df = os.environ.get("VIVAC_DF") or "df"
    try:
        text = subprocess.run([df, "-P", "-T", "-B1"], capture_output=True, text=True, timeout=8,
                              env={**os.environ, "LC_ALL": "C"}).stdout
    except (OSError, subprocess.TimeoutExpired):
        return []
    by_device: dict[str, Disk] = {}
    for line in text.splitlines()[1:]:
        f = line.split(None, 6)
        if len(f) < 7 or f[1] in _NOT_REAL or f[6].startswith(("/run", "/sys", "/proc", "/dev", "/snap")):
            continue
        try:
            total, used, avail = int(f[2]), int(f[3]), int(f[4])
        except ValueError:
            continue
        if total <= 0:
            continue
        pct = 100.0 * used / (used + avail) if used + avail > 0 else 0.0
        d = Disk(f[0], f[1], f[6], total, used, avail, pct, pct > 90)
        old = by_device.get(f[0])
        if old is None or len(d.mount) < len(old.mount):
            by_device[f[0]] = d
    return sorted(by_device.values(), key=lambda d: d.mount)


# ---- graphics card -----------------------------------------------------------

@dataclass
class GpuProc:
    pid: int
    name: str
    kind: str
    mb: int


@dataclass
class Gpu:
    name: str
    load: int | None
    mem_used: int | None
    mem_total: int | None
    temp: float | None
    power: float | None
    power_limit: float | None
    fan: int | None
    clock: int | None
    procs: list[GpuProc] = field(default_factory=list)


def _smi(*args: str, timeout: float = 6.0) -> str | None:
    exe = os.environ.get("VIVAC_NVIDIA_SMI") or shutil.which("nvidia-smi")
    if not exe:
        return None
    try:
        r = subprocess.run([exe, *args], capture_output=True, text=True, timeout=timeout)
    except (OSError, subprocess.TimeoutExpired):
        return None
    return r.stdout if r.returncode == 0 else None


def _num(text: str, kind=float):
    try:
        return kind(float(text.strip()))
    except ValueError:
        return None  # "[N/A]", "N/A"


def gpu(procs: bool = True) -> Gpu | None:
    """The first NVIDIA card, or None without nvidia-smi or a card. The
    programs using it (graphics and compute) cost a second of sampling, so
    they are read only when asked."""
    out = _smi("--query-gpu=name,utilization.gpu,memory.used,memory.total,temperature.gpu,power.draw,"
               "power.limit,fan.speed,clocks.current.graphics", "--format=csv,noheader,nounits")
    if not out or not out.strip():
        return None
    f = [x.strip() for x in out.strip().splitlines()[0].split(",")]
    if len(f) < 9:
        return None
    g = Gpu(f[0], _num(f[1], int), _num(f[2], int), _num(f[3], int), _num(f[4]), _num(f[5]), _num(f[6]),
            _num(f[7], int), _num(f[8], int))
    if procs:
        g.procs = gpu_procs()
    return g


def gpu_procs() -> list[GpuProc]:
    text = _smi("pmon", "-c", "1", "-s", "um", timeout=8.0) or ""
    found = []
    for line in text.splitlines():
        if line.lstrip().startswith("#") or not line.strip():
            continue
        f = line.split()
        if len(f) < 12 or not f[1].isdigit():
            continue
        pid = int(f[1])
        comm = _read(_proc() / str(pid) / "comm").strip()
        found.append(GpuProc(pid, comm or " ".join(f[11:]), f[2], int(f[9]) if f[9].isdigit() else 0))
    return sorted(found, key=lambda p: -p.mb)


# ---- the bar ---------------------------------------------------------------

def bar_summary(cpu: float, mem: "Mem", disk_list: list, temp: float | None, g: "Gpu | None") -> dict:
    """The one chip the bar shows for the whole machine (it unfolds into the
    separate gauges): the processor's use as text, every gauge in the
    tooltip, and the class of the worst one, so a full disk or a hot GPU
    shows on the folded chip too."""
    from .kit import T
    mem_pct = 100 * mem.used / mem.total if mem.total else 0
    worst = "ok"

    def rate(level: str) -> None:
        nonlocal worst
        order = ("ok", "warning", "critical")
        if order.index(level) > order.index(worst):
            worst = level

    rate("critical" if cpu >= 95 else "warning" if cpu >= 85 else "ok")
    rate("critical" if mem_pct >= 95 else "warning" if mem_pct >= 90 else "ok")
    lines = [f"{T('sys.tab.cpu')}: {round(cpu)}%" + (f" · {temp:.0f}°C" if temp is not None else ""),
             f"{T('sys.tab.memory')}: {round(mem_pct)}% ({human_bytes(mem.used)} / {human_bytes(mem.total)})"]
    if temp is not None:
        rate("critical" if temp >= 90 else "warning" if temp >= 80 else "ok")
    for d in disk_list:
        lines.append(f"{d.mount} {round(d.percent)}%" + (" ⚠" if d.alert else ""))
        if d.alert:  # a full disk is a warning, not an emergency: it stays full for days
            rate("warning")
    if g is not None:
        parts = [f"{g.load}%" if g.load is not None else "", f"{g.temp:.0f}°C" if g.temp is not None else ""]
        lines.append(f"{T('sys.tab.gpu')}: " + " · ".join(p for p in parts if p))
        if g.temp is not None:
            rate("critical" if g.temp >= 90 else "warning" if g.temp >= 80 else "ok")
    lines.append(T("sys.bar_click"))
    return {"text": f"\U000F061A {round(cpu)}%", "tooltip": "\n".join(lines), "class": worst}


def waybar(args: list[str] | None = None) -> int:
    import json
    import time
    a = read_cpu()
    time.sleep(0.25)
    total, _cores = cpu_usage(a, read_cpu())
    print(json.dumps(bar_summary(total, memory(), disks(), temperature(), gpu(procs=False)), ensure_ascii=False))
    return 0



def available_tabs() -> list[str]:
    tabs = ["cpu", "memory", "disk"]
    if gpu(procs=False) is not None:
        tabs.append("gpu")
    return tabs


def human_bytes(n: float) -> str:
    units = ("B", "KB", "MB", "GB", "TB", "PB")
    i = 0
    while n >= 1024 and i < len(units) - 1:
        n /= 1024
        i += 1
    if i >= 3:
        return f"{n:.0f} {units[i]}" if n >= 100 else f"{n:.1f} {units[i]}"
    return f"{n:.0f} {units[i]}"


# ---- one reading of everything ---------------------------------------------

@dataclass
class Snapshot:
    cpu: float
    cores: list[float]
    load: tuple[float, float, float]
    temp: float | None
    mem: Mem
    top_cpu: list[tuple[str, float]]
    top_mem: list[tuple[str, int]]
    disks: list[Disk]
    gpu: Gpu | None


class Sampler:
    """Readings that need two points in time (use, programs' use) kept between
    calls; the first call takes its own second point after a moment."""

    def __init__(self) -> None:
        self.cpu = None
        self.procs: dict = {}
        self.at = 0.0
        self.info = cpu_info()
        self.has_gpu: bool | None = None

    def sample(self, gpu_procs: bool = False, with_disks: bool = True) -> Snapshot:
        if self.cpu is None:
            self.cpu, self.procs, self.at = read_cpu(), read_procs(), time.monotonic()
            time.sleep(0.3)
        cpu, procs, now = read_cpu(), read_procs(), time.monotonic()
        total, cores = cpu_usage(self.cpu, cpu)
        top = top_cpu(self.procs, procs, now - self.at, 6, ncpu=self.info["threads"])
        self.cpu, self.procs, self.at = cpu, procs, now
        card = None
        if self.has_gpu is not False:
            card = gpu(procs=gpu_procs)
            self.has_gpu = card is not None
        return Snapshot(total, cores, loadavg(), temperature(), memory(), top, top_mem(procs, 6),
                        disks() if with_disks else [], card)


# ---- derived readings the redesigned panel draws --------------------------

def heat_alpha(pct: float) -> float:
    """How strongly a thread's tile is filled: a little at idle, full at 100."""
    return min(1.0, 0.14 + 0.0175 * max(0.0, pct))


def history_stats(values, step: float = 2.0) -> tuple[float, float, float]:
    """(peak, mean, seconds since the peak) of a history sampled every `step`
    seconds; zeros while it is empty. The latest of equal peaks wins."""
    vals = list(values)
    if not vals:
        return 0.0, 0.0, 0.0
    peak = max(vals)
    last = max(i for i, v in enumerate(vals) if v == peak)
    return peak, sum(vals) / len(vals), (len(vals) - 1 - last) * step


def split_seconds(seconds: float) -> tuple[int, int]:
    s = int(round(seconds))
    return s // 60, s % 60


def thread_columns(cores: list[float]) -> list[list[float | None]]:
    """Per-thread use laid out as one column per physical core, one row per
    SMT sibling, as the kernel's topology says (cpuN/topology/core_id and
    physical_package_id). Without it, siblings are taken as adjacent pairs
    when /proc/cpuinfo says there are two threads per core."""
    groups: dict[tuple[str, str], list[int]] = {}
    for i in range(len(cores)):
        topo = _sys() / "devices" / "system" / "cpu" / f"cpu{i}" / "topology"
        core, pkg = _read(topo / "core_id").strip(), _read(topo / "physical_package_id").strip()
        if not core:
            groups = {}
            break
        groups.setdefault((pkg, core), []).append(i)
    if not groups:
        info = cpu_info()
        smt = max(1, info["threads"] // info["cores"]) if info["cores"] else 1
        smt = smt if len(cores) % smt == 0 else 1
        groups = {("0", str(i // smt)): list(range(i - i % smt, i - i % smt + smt)) for i in range(0, len(cores), smt)}
    cols = sorted(groups.values(), key=lambda g: g[0])
    rows = max((len(g) for g in cols), default=1)
    return [[cores[i] for i in g] + [None] * (rows - len(g)) for g in cols]


def stack_parts(items: list[tuple[str, float]], total: float, keep: int) -> list[tuple[str, float]]:
    """The (name, fraction of total) of the first `keep` items; the stack of
    a programs bar. An empty or zero total gives no parts."""
    if total <= 0:
        return []
    return [(n, max(0.0, v) / total) for n, v in items[:keep]]


# ---- the panel ---------------------------------------------------------------

def _drawing(Gtk, pal: dict) -> object:
    """The drawn pieces of this panel (a 270 degree gauge, the history with
    its axes, the per-thread heat map, a stack with gaps, a thin bar), as
    Cairo over the palette. The Windows side draws the same in WPF."""
    import math

    from .draw import rgb
    from .gfx import helpers

    g = helpers(Gtk, pal)
    text, rounded, curve = g.text, g.rounded, g.curve

    class Gauge(Gtk.DrawingArea):
        """A gauge of 270 degrees open at the bottom: track and a fraction."""

        def __init__(self, size: int = 112, thickness: int = 11) -> None:
            super().__init__()
            self.set_content_width(size)
            self.set_content_height(size)
            self.set_halign(Gtk.Align.CENTER)
            self.thickness, self.fraction, self.alert = thickness, 0.0, False
            self.set_draw_func(self._draw)

        def set(self, fraction: float, alert: bool = False) -> None:
            self.fraction, self.alert = max(0.0, min(1.0, fraction)), alert
            self.queue_draw()

        def _draw(self, _a, cr, w, h) -> None:
            r, cx, cy = min(w, h) / 2 - self.thickness / 2, w / 2, h / 2
            start = 3 * math.pi / 4
            cr.set_line_width(self.thickness)
            cr.set_line_cap(1)
            cr.set_source_rgba(*rgb(pal["surfaceAlt"]))
            cr.arc(cx, cy, r, start, start + 1.5 * math.pi)
            cr.stroke()
            if self.fraction > 0.004:
                cr.set_source_rgba(*rgb(pal["alert"] if self.alert else pal["accent"]))
                cr.arc(cx, cy, r, start, start + 1.5 * math.pi * self.fraction)
                cr.stroke()

    class History(Gtk.DrawingArea):
        """The last two minutes: 0/50/100 % guides with their labels at the
        right, the line over a fading fill, a dot at now, the time under."""

        def __init__(self, values, height: int, labels: tuple[str, str, str], right: int = 34) -> None:
            super().__init__()
            self.values, self.labels, self.right = values, labels, right
            self.set_content_height(height)
            self.set_hexpand(True)
            self.set_draw_func(self._draw)

        def _draw(self, _a, cr, w, h) -> None:
            import cairo
            pw, top, bottom = w - self.right, 4, h - 18
            cr.set_line_width(1)
            for frac, label in ((0.0, "0%"), (0.5, "50%"), (1.0, "100%")):
                y = round(bottom - (bottom - top) * frac) + 0.5
                cr.set_source_rgba(*rgb(pal["line"]))
                cr.set_dash([] if frac == 0 else [2, 4])
                cr.move_to(0, y)
                cr.line_to(pw, y)
                cr.stroke()
                text(cr, label, pw + 6, y, 11, pal["textSecondary"])
            cr.set_dash([])
            text(cr, self.labels[0], 0, h - 6, 11, pal["textSecondary"])
            text(cr, self.labels[1], pw / 2, h - 6, 11, pal["textSecondary"], anchor="middle")
            text(cr, self.labels[2], pw, h - 6, 11, pal["textSecondary"], anchor="end")
            vals = list(self.values)
            if not vals:
                return
            step = pw / (self.values.maxlen - 1)
            pts = [(pw - step * (len(vals) - 1 - i), bottom - (bottom - top) * max(0, min(100, v)) / 100)
                   for i, v in enumerate(vals)]
            if len(pts) > 1:
                curve(cr, pts)
                cr.set_line_join(1)
                cr.set_line_cap(1)
                line = cr.copy_path()
                cr.line_to(pts[-1][0], bottom)
                cr.line_to(pts[0][0], bottom)
                cr.close_path()
                grad = cairo.LinearGradient(0, top, 0, bottom)
                grad.add_color_stop_rgba(0, *rgb(pal["accent"], 0.38))
                grad.add_color_stop_rgba(1, *rgb(pal["accent"], 0.0))
                cr.set_source(grad)
                cr.fill()
                cr.new_path()
                cr.append_path(line)
                cr.set_line_width(2)
                cr.set_source_rgba(*rgb(pal["accent"]))
                cr.stroke()
            x, y = pts[-1]
            cr.arc(x, y, 5, 0, 2 * math.pi)
            cr.set_source_rgba(*rgb(pal["surface"]))
            cr.fill()
            cr.arc(x, y, 3, 0, 2 * math.pi)
            cr.set_source_rgba(*rgb(pal["accent"]))
            cr.fill()

    class Heat(Gtk.DrawingArea):
        """One tile per thread, a column per core, filled by its use."""

        def __init__(self) -> None:
            super().__init__()
            self.columns: list[list[float | None]] = []
            self.set_hexpand(True)
            self.set_draw_func(self._draw)

        def set(self, columns) -> None:
            rows = max((len(c) for c in columns), default=1)
            self.set_content_height(int(rows * 28 + (rows - 1) * 4.9 + 22))
            self.columns = columns
            self.queue_draw()

        def _draw(self, _a, cr, w, h) -> None:
            n = len(self.columns)
            if not n:
                return
            gap, th = 4.9, 28
            tw = (w - gap * (n - 1)) / n
            rows = max(len(c) for c in self.columns)
            for c, col in enumerate(self.columns):
                x = c * (tw + gap)
                for r, v in enumerate(col):
                    if v is None:
                        continue
                    y = r * (th + gap)
                    rounded(cr, x, y, tw, th, 6)
                    cr.set_source_rgba(*rgb(pal["surfaceAlt"]))
                    cr.fill()
                    rounded(cr, x, y, tw, th, 6)
                    cr.set_source_rgba(*rgb(pal["alert"] if v >= 95 else pal["accent"], heat_alpha(v)))
                    cr.fill()
                    if tw >= 20:
                        hot = v >= 22
                        text(cr, f"{v:.0f}", x + tw / 2, y + th / 2, 12,
                             pal["actionText"] if hot else pal["text"], bold=hot, anchor="middle")
                if tw >= 20:
                    text(cr, str(c), x + tw / 2, rows * (th + gap) + 6, 11, pal["textSecondary"], anchor="middle")

    class Segs(Gtk.DrawingArea):
        """A stack of coloured parts with a 2 px gap, the rest as the track;
        an optional label sits in the rest."""

        def __init__(self, height: int = 10) -> None:
            super().__init__()
            self.set_content_height(height)
            self.set_hexpand(True)
            self.parts: list[tuple[float, str]] = []
            self.label = ""
            self.set_draw_func(self._draw)

        def set(self, parts: list[tuple[float, str]], label: str = "") -> None:
            self.parts, self.label = parts, label
            self.queue_draw()

        def _draw(self, _a, cr, w, h) -> None:
            rounded(cr, 0, 0, w, h, h / 2 if h < 16 else 10)
            cr.clip()
            cr.set_source_rgba(*rgb(pal["surfaceAlt"]))
            cr.paint()
            x = 0.0
            for frac, colour in self.parts:
                pw = w * max(0.0, frac)
                if pw <= 0:
                    continue
                cr.set_source_rgba(*rgb(pal.get(colour, colour)))
                cr.rectangle(x, 0, max(1.0, pw - 2), h)
                cr.fill()
                x += pw
            if self.label and w - x > 60:
                text(cr, self.label, x + (w - x) / 2, h / 2, 12, pal["textSecondary"], anchor="middle")

    class NS:
        pass

    ns = NS()
    ns.Gauge, ns.History, ns.Heat, ns.Segs, ns.Bar = Gauge, History, Heat, Segs, g.Bar
    return ns


def main(tab: str = "cpu") -> int:
    import threading
    from collections import deque

    from .draw import widgets as ring_widgets
    from .kit import T, gtk_kit, mix

    k = gtk_kit()
    Gtk, Gdk, GLib = k.Gtk, k.Gdk, k.GLib
    tabs = available_tabs()
    if tab not in tabs:
        tab = "cpu"
    sampler = Sampler()
    sampler.has_gpu = "gpu" in tabs
    panel = k.Panel("system", "\U000F0A07", T("sys.title"), "",
                    hints=[("Tab 1-%d" % len(tabs), T("sys.key.tabs")), ("Esc", T("sys.key.close"))], width=528)
    glyphs = {"cpu": "\U000F0EE0", "memory": "\U000F035B", "disk": "\U000F02CA", "gpu": "\U000F08AE"}
    state = {"tab": tab, "busy": False, "snap": None, "pages": {}, "buttons": {}, "tabvals": {}}
    history = {"cpu": deque(maxlen=60), "memory": deque(maxlen=60), "gpu": deque(maxlen=60)}
    pal = dict(panel.p)
    # Tokens the board has and the kit's palette does not: derived from it.
    pal["alertText"] = mix(pal["alert"], pal["text"], 0.43)
    pal["alertSoft"] = mix(pal["bg"], pal["alert"], 0.18)
    pal["successSoft"] = mix(pal["bg"], pal["success"], 0.18)
    pal["successText"] = mix(pal["success"], pal["text"], 0.2)
    pal["warnSoft"] = mix(pal["bg"], pal["accent"], 0.18)
    pal["lineStrong"] = mix(pal["bg"], pal["text"], 0.4)
    d = _drawing(Gtk, pal)
    ring = ring_widgets(Gtk, pal)
    # Colours of the programs in a stack, in order, and of what is left over.
    series = [pal["accent"], pal["info"], pal["success"], pal["alertText"], pal["text"], pal["muted"]]

    def style() -> None:
        p = pal
        css = f"""
.vivac .sys-tabs {{ background: {p['surface']}; border-radius: 14px; padding: 4px; }}
.vivac .systab {{ border-radius: 10px; padding: 0; min-height: 50px; border: none; box-shadow: none;
  background: transparent; color: {p['text']}; }}
.vivac .systab:hover {{ background: {p['surfaceAlt']}; }}
.vivac .systab.on {{ background: {p['actionFill']}; color: {p['actionText']};
  box-shadow: 0 0 0 2px {p['bg']}, 0 0 0 4px {p['focusRing']}; }}
.vivac .systab:focus-visible {{ box-shadow: 0 0 0 2px {p['bg']}, 0 0 0 4px {p['focusRing']}; }}
.vivac .systab-n {{ font-size: 13px; }}
.vivac .systab.on .systab-n {{ font-weight: 700; }}
.vivac .systab-v {{ font-size: 12px; color: {p['textSecondary']}; }}
.vivac .systab.on .systab-v {{ color: {p['actionText']}; }}
.vivac .systab-v.warn {{ color: {p['alertText']}; font-weight: 700; }}
.vivac .systab.on .systab-v.warn {{ color: {p['actionText']}; }}
.vivac .sys-pill {{ border-radius: 13px; padding: 0 10px; min-height: 26px; font-size: 13px; font-weight: 700;
  background: {p['successSoft']}; color: {p['successText']}; }}
.vivac .sys-pill.warn {{ background: {p['warnSoft']}; color: {p['accent']}; }}
.vivac .sys-pill.alert {{ background: {p['alertSoft']}; color: {p['alertText']}; }}
.vivac .sys-card {{ background: {p['surface']}; border-radius: 12px; padding: 14px; }}
.vivac .sys-hero {{ background: {p['surface']}; border-radius: 12px; padding: 12px; }}
.vivac .sys-strip {{ background: {p['surface']}; border-radius: 12px; padding: 8px 4px; }}
.vivac .sys-sep {{ background: {p['line']}; min-width: 1px; }}
.vivac .sys-k {{ font-size: 11px; letter-spacing: 1px; font-weight: 700; color: {p['textSecondary']}; }}
.vivac .sys-v {{ font-size: 15px; font-weight: 700; color: {p['text']}; }}
.vivac .sys-v.alert {{ color: {p['alertText']}; }}
.vivac .sys-s {{ font-size: 11px; color: {p['textSecondary']}; }}
.vivac .sys-sec {{ font-size: 12px; letter-spacing: 1px; font-weight: 700; color: {p['muted']}; }}
.vivac .sys-count {{ font-size: 12px; font-weight: 700; color: {p['text']}; }}
.vivac .sys-note {{ font-size: 12px; color: {p['textSecondary']}; }}
.vivac .sys-note b {{ color: {p['text']}; }}
.vivac .sys-name {{ font-size: 13px; color: {p['text']}; }}
.vivac .sys-val {{ font-size: 13px; font-weight: 700; color: {p['text']}; }}
.vivac .sys-pct {{ font-size: 12px; color: {p['textSecondary']}; }}
.vivac .sys-big {{ font-size: 44px; font-weight: 700; color: {p['text']}; letter-spacing: -1px; }}
.vivac .sys-big-u {{ font-size: 18px; color: {p['textSecondary']}; }}
.vivac .sys-gauge-n {{ font-size: 33px; font-weight: 700; color: {p['text']}; letter-spacing: -1px; }}
.vivac .sys-gauge-u {{ font-size: 13px; color: {p['textSecondary']}; }}
.vivac .sys-dot {{ min-width: 8px; min-height: 8px; border-radius: 2px; }}
.vivac .sys-kind {{ font-size: 12px; color: {p['textSecondary']}; background: {p['surfaceAlt']};
  border-radius: 10px; padding: 1px 10px; }}
.vivac .sys-disk {{ background: {p['surface']}; border-radius: 12px; padding: 10px 14px; }}
.vivac .sys-disk.alert {{ background: {p['alertSoft']}; box-shadow: inset 0 0 0 2px {p['alert']}; }}
.vivac .sys-disk-mount {{ font-size: 15px; font-weight: 700; color: {p['text']}; }}
.vivac .sys-disk-pct {{ font-size: 12px; font-weight: 700; color: {p['text']}; }}
.vivac .sys-chip {{ font-size: 12px; font-weight: 700; color: {p['alertText']}; }}
.vivac .sys-empty {{ font-size: 12px; color: {p['textSecondary']}; padding: 8px 10px; }}
"""
        for i, colour in enumerate(series + [pal["lineStrong"], pal["textSecondary"]]):
            css += f".vivac .sys-c{i} {{ background: {colour}; }}\n"
        prov = Gtk.CssProvider()
        prov.load_from_string(css)
        Gtk.StyleContext.add_provider_for_display(Gdk.Display.get_default(), prov,
                                                  Gtk.STYLE_PROVIDER_PRIORITY_USER)

    def label(text: str = "", *classes: str, xalign: float = 0.5, markup: bool = False, **kw):
        w = Gtk.Label(xalign=xalign, **kw)
        (w.set_markup if markup else w.set_label)(text)
        for c in classes:
            w.add_css_class(c)
        return w

    def clear(box) -> None:
        child = box.get_first_child()
        while child:
            nxt = child.get_next_sibling()
            box.remove(child)
            child = nxt

    def vbox(spacing: int = 0, *classes: str, **kw):
        b = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=spacing, **kw)
        for c in classes:
            b.add_css_class(c)
        return b

    def section(title: str, count=None):
        """HILOS 24 ......... a note: the label, a count, and a note at the right."""
        row = Gtk.Box(spacing=8)
        row.append(label(title.upper(), "sys-sec", xalign=0))
        cnt = label("" if count is None else str(count), "sys-count", xalign=0)
        row.append(cnt)
        note = label("", "sys-note", xalign=1, hexpand=True, markup=True, ellipsize=3)
        row.append(note)
        return row, cnt, note

    def dot(i: int):
        w = Gtk.Box(valign=Gtk.Align.CENTER)
        w.add_css_class("sys-dot")
        w.add_css_class(f"sys-c{i}")
        return w

    def strip(count: int):
        """A card of `count` columns split by thin rules: key, value, a line
        under it and room for one drawn extra."""
        box = Gtk.Box()
        box.add_css_class("sys-strip")
        cells = []
        for i in range(count):
            if i:
                sep = Gtk.Box()
                sep.add_css_class("sys-sep")
                box.append(sep)
            col = vbox(3, hexpand=True, halign=Gtk.Align.FILL)
            col.set_homogeneous(False)
            key, val, sub = label("", "sys-k"), label("-", "sys-v"), label("", "sys-s")
            extra = vbox(0, halign=Gtk.Align.CENTER)
            for w in (key, val, sub, extra):
                col.append(w)
            col.set_size_request(1, -1)
            box.append(col)
            cells.append({"k": key, "v": val, "s": sub, "x": extra})
        box.set_homogeneous(False)
        return box, cells

    def gauge_hero(history_key: str, caption_below: bool = False):
        """The gauge with its number, and the history beside it."""
        hero = Gtk.Box(spacing=16)
        hero.add_css_class("sys-hero")
        gauge = d.Gauge()
        over = Gtk.Overlay()
        over.set_child(gauge)
        num = Gtk.Box(halign=Gtk.Align.CENTER, valign=Gtk.Align.CENTER)
        num.set_margin_bottom(6)
        n = label("0", "sys-gauge-n")
        num.append(n)
        num.append(label("%", "sys-gauge-u", valign=Gtk.Align.END))
        num.get_last_child().set_margin_bottom(4)
        over.add_overlay(num)
        over.set_size_request(112, 112)
        hero.append(over)
        col = vbox(2, hexpand=True)
        head = Gtk.Box()
        left, right = label("", "sys-note", xalign=0, hexpand=True), label("", "sys-note", xalign=1, markup=True)
        head.append(left)
        head.append(right)
        hist = d.History(history[history_key], 100, (T("sys.t_2min"), T("sys.t_1min"), T("sys.t_now")))
        for w in ((hist, head) if caption_below else (head, hist)):
            col.append(w)
        hero.append(col)
        return hero, gauge, n, left, right, hist

    class Rows:
        """Fixed rows of: a colour dot, a name, an optional bar, values."""

        def __init__(self, count: int, bars: bool = True, with_pct: bool = False) -> None:
            self.box = vbox(2)
            self.rows = []
            for _ in range(count):
                r = Gtk.Box(spacing=10)
                r.set_size_request(-1, 22)
                dt = Gtk.Box(valign=Gtk.Align.CENTER)
                dt.add_css_class("sys-dot")
                name = label("", "sys-name", xalign=0, ellipsize=3, width_chars=14, max_width_chars=14)
                name.set_size_request(150, -1)
                bar = d.Bar()
                val = label("", "sys-val", xalign=1, width_chars=7 if with_pct else 6)
                pct = label("", "sys-pct", xalign=1, width_chars=4) if with_pct else None
                for w in (dt, name, bar if bars else label("", hexpand=True), val, pct):
                    if w is not None:
                        r.append(w)
                if not bars:
                    r.get_first_child().get_next_sibling().set_hexpand(True)
                self.rows.append({"row": r, "dot": dt, "name": name, "bar": bar, "val": val, "pct": pct, "cls": None})
                self.box.append(r)

        def set(self, i: int, colour_index: int, name: str, frac: float, val: str, pct: str = "",
                bar: bool = True) -> None:
            row = self.rows[i]
            row["row"].set_visible(True)
            if row["cls"]:
                row["dot"].remove_css_class(row["cls"])
            row["cls"] = f"sys-c{colour_index}"
            row["dot"].add_css_class(row["cls"])
            row["name"].set_label(name)
            row["name"].set_tooltip_text(name)
            row["bar"].set_opacity(1.0 if bar else 0.0)
            row["bar"].set(frac, series[colour_index] if colour_index < len(series) else pal["lineStrong"])
            row["val"].set_label(val)
            if row["pct"]:
                row["pct"].set_label(pct)

        def hide_from(self, n: int) -> None:
            for i in range(n, len(self.rows)):
                self.rows[i]["row"].set_visible(False)

    pages = state["pages"]
    PAGE = dict(spacing=10)

    # ---- the four tabs ----------------------------------------------------

    def build_cpu():
        hero, gauge, num, left, right, hist = gauge_hero("cpu")
        facts, cells = strip(3)
        for c, key in zip(cells, (T("sys.cores"), T("sys.frequency"), T("sys.load_short"))):
            c["k"].set_label(key.upper())
        bars = Gtk.Box(spacing=3, valign=Gtk.Align.END)
        bars.set_size_request(-1, 16)
        load_bars = []
        for opacity in (1.0, 0.7, 0.45):
            b = Gtk.Box(valign=Gtk.Align.END)
            b.add_css_class("sys-dot")
            b.add_css_class("sys-c0")
            b.set_size_request(20, 5)
            b.set_opacity(opacity)
            bars.append(b)
            load_bars.append(b)
        cells[2]["x"].append(bars)
        heat_card = vbox(10, "sys-card")
        hsec, hcount, hnote = section(T("sys.threads"), 0)
        heat = d.Heat()
        heat_card.append(hsec)
        heat_card.append(heat)
        top_card = vbox(8, "sys-card")
        tsec, tcount, tnote = section(T("sys.top"), 0)
        stack = d.Segs(10)
        rows = Rows(5, with_pct=False)
        for w in (tsec, stack, rows.box):
            top_card.append(w)
        box = vbox(10)
        for w in (hero, facts, heat_card, top_card):
            box.append(w)
        pages["cpu"] = dict(widget=box, hist=hist, gauge=gauge, num=num, left=left, right=right, cells=cells,
                            load_bars=load_bars, heat=heat, hcount=hcount, hnote=hnote, tcount=tcount, tnote=tnote,
                            stack=stack, rows=rows)

    def build_memory():
        hero = Gtk.Box(spacing=16)
        hero.add_css_class("sys-card")
        hero.set_valign(Gtk.Align.START)
        col = vbox(2, valign=Gtk.Align.END)
        col.append(label(T("sys.used").upper(), "sys-sec", xalign=0))
        big = Gtk.Box()
        big_n = label("0", "sys-big", xalign=0)
        big.append(big_n)
        big.append(label("%", "sys-big-u", valign=Gtk.Align.END))
        big.get_last_child().set_margin_bottom(6)
        col.append(big)
        amount = label("", "sys-note", xalign=0)
        col.append(amount)
        hero.append(col)
        spacer = Gtk.Box(hexpand=True)
        hero.append(spacer)
        hist = d.History(history["memory"], 74, (T("sys.t_2min"), T("sys.t_1min"), T("sys.t_now")))
        hist.set_size_request(262, -1)
        hist.set_hexpand(False)
        hero.append(hist)
        map_card = vbox(10, "sys-card")
        segs = d.Segs(30)
        legend = Gtk.Box(homogeneous=False)
        l0, l1, l2 = label("0", "sys-s", xalign=0), label(T("sys.mem_map"), "sys-s", hexpand=True), \
            label("", "sys-s", xalign=1)
        for w in (l0, l1, l2):
            legend.append(w)
        # the hero and the map are one card, as in the board
        map_card.append(hero)
        hero.remove_css_class("sys-card")
        map_card.append(segs)
        map_card.append(legend)
        facts, cells = strip(3)
        for c, key in zip(cells, (T("sys.available"), T("sys.used"), T("sys.swap"))):
            c["k"].set_label(key.upper())
        swap_bar = d.Bar()
        swap_bar.set_size_request(100, 6)
        swap_bar.set_hexpand(False)
        cells[2]["x"].append(swap_bar)
        top_card = vbox(8, "sys-card")
        tsec, tcount, tnote = section(T("sys.top_mem"), 0)
        tnote.set_label(T("sys.top_mem_note"))
        rows = Rows(7, with_pct=True)
        for w in (tsec, rows.box):
            top_card.append(w)
        box = vbox(10)
        for w in (map_card, facts, top_card):
            box.append(w)
        pages["memory"] = dict(widget=box, hist=hist, big=big_n, amount=amount, segs=segs, l2=l2, cells=cells,
                               swap_bar=swap_bar, tcount=tcount, rows=rows)

    def build_disk():
        facts, cells = strip(3)
        for c, key in zip(cells, (T("sys.total_free"), T("sys.drives_k"), T("sys.need_attention"))):
            c["k"].set_label(key.upper())
        head, count, note = section(T("sys.drives_k"), 0)
        note.set_label(T("sys.sorted_path"))
        list_box = vbox(8)
        box = vbox(10)
        for w in (facts, head, list_box):
            box.append(w)
        pages["disk"] = dict(widget=box, cells=cells, count=count, list=list_box, cards={}, sig=None)

    def build_gpu():
        hero, gauge, num, left, right, hist = gauge_hero("gpu", caption_below=True)
        left.set_label(T("sys.gpu_use"))
        facts, cells = strip(3)
        for c, key in zip(cells, (T("sys.power"), T("sys.fan"), T("sys.clock"))):
            c["k"].set_label(key.upper())
        power_bar = d.Bar()
        power_bar.set_size_request(100, 6)
        power_bar.set_hexpand(False)
        cells[0]["x"].append(power_bar)
        vram = vbox(8, "sys-card")
        vhead = Gtk.Box()
        vhead.append(label(T("sys.vram").upper(), "sys-sec", xalign=0, hexpand=True))
        vval = label("-", "sys-val", xalign=1)
        vhead.append(vval)
        segs = d.Segs(16)
        legend = Gtk.Box()
        gl0, gl1, gl2 = label("0", "sys-s", xalign=0), label("", "sys-s", hexpand=True), label("", "sys-s", xalign=1)
        for w in (gl0, gl1, gl2):
            legend.append(w)
        for w in (vhead, segs, legend):
            vram.append(w)
        prog = vbox(8, "sys-card")
        psec, pcount, pnote = section(T("sys.gpu_procs"), 0)
        pnote.set_label(T("sys.kinds_note"))
        plist = vbox(2)
        prog.append(psec)
        prog.append(plist)
        box = vbox(10)
        for w in (hero, facts, vram, prog):
            box.append(w)
        pages["gpu"] = dict(widget=box, hist=hist, gauge=gauge, num=num, right=right, cells=cells, power_bar=power_bar,
                            vval=vval, segs=segs, gl1=gl1, gl2=gl2, pcount=pcount, plist=plist, sig=None)

    # ---- applying a reading ---------------------------------------------

    def temp_pill(t):
        """The header's temperature: ok, warm or hot, with a shape for hot."""
        header = panel.header_end
        clear(header)
        if t is None:
            return
        kind = "alert" if t >= 85 else "warn" if t >= 75 else ""
        pill = label(("⚠ " if t >= 85 else "\U000F050F ") + f"{t:.0f}°C", "sys-pill", valign=Gtk.Align.CENTER)
        if kind:
            pill.add_css_class(kind)
        header.append(pill)

    def set_tab_value(key: str, text: str, warn: bool = False) -> None:
        lab = state["tabvals"].get(key)
        if lab is not None:
            lab.set_label(("\u26a0 " if warn else "") + text)
            (lab.add_css_class if warn else lab.remove_css_class)("warn")

    def pct_text(v: float) -> str:
        return f"{v:.0f}%" if v >= 10 else f"{v:.1f}%"

    def apply(s: Snapshot) -> None:
        history["cpu"].append(s.cpu)
        history["memory"].append(100.0 * s.mem.used / s.mem.total if s.mem.total else 0)
        if s.gpu and s.gpu.load is not None:
            history["gpu"].append(s.gpu.load)
        apply_cpu(s)
        apply_memory(s)
        apply_disks(s.disks)
        if s.gpu and "gpu" in pages:
            apply_gpu(s.gpu)
        header_for_tab()
        subtitle()

    def apply_cpu(s: Snapshot) -> None:
        info, p = sampler.info, pages["cpu"]
        p["gauge"].set(s.cpu / 100, s.cpu >= 90)
        p["num"].set_label(f"{s.cpu:.0f}")
        p["left"].set_label(T("sys.use_total", len(s.cores)))
        peak, mean, _ago = history_stats(history["cpu"])
        p["right"].set_markup(T("sys.peak_mean", f"<b>{peak:.0f}%</b>", f"<b>{mean:.0f}%</b>"))
        p["hist"].queue_draw()
        c = p["cells"]
        mhz = info["mhz"]
        smt = max(1, info["threads"] // max(1, info["cores"]))
        c[0]["v"].set_label(f"{info['cores']} / {info['threads']}")
        c[0]["s"].set_label(T("sys.smt", smt))
        c[1]["v"].set_label(f"{mhz / 1000:.2f} GHz" if mhz else "-")
        c[1]["s"].set_label(T("sys.freq_avg"))
        c[2]["v"].set_label(" ".join(f"{x:.2f}" for x in s.load))
        top_load = max(max(s.load), 0.01)
        for b, v in zip(p["load_bars"], s.load):
            b.set_size_request(20, int(4 + 6 * v / top_load))
        cols = thread_columns(s.cores)
        p["heat"].set(cols)
        p["hcount"].set_label(str(len(s.cores)))
        rows_n = max((len(col) for col in cols), default=1)
        p["hnote"].set_label(T("sys.threads_note", rows_n))
        shown = s.top_cpu[:5]
        total = max(s.cpu, 0.1)
        parts = stack_parts(shown, total, 5)
        p["stack"].set([(f, series[i]) for i, (_n, f) in enumerate(parts)])
        top = max((v for _n, v in shown), default=0)
        for i, (n, v) in enumerate(shown):
            p["rows"].set(i, i, n, v / top if top else 0, pct_text(v))
        p["rows"].hide_from(len(shown))
        p["tcount"].set_label(str(len(shown)))
        summed = sum(v for _n, v in shown)
        p["tnote"].set_label(T("sys.top_sum", pct_text(summed), pct_text(s.cpu), pct_text(max(0.0, s.cpu - summed))))
        set_tab_value("cpu", f"{s.cpu:.0f}%")

    def apply_memory(s: Snapshot) -> None:
        m, p = s.mem, pages["memory"]
        pct = 100.0 * m.used / m.total if m.total else 0
        p["hist"].queue_draw()
        p["big"].set_label(f"{pct:.0f}")
        p["amount"].set_label(f"{human_bytes(m.used)} / {human_bytes(m.total)}")
        shown = [(n, float(b)) for n, b in s.top_mem[:6]]
        parts = stack_parts(shown, float(m.total), 6)
        rest = max(0.0, m.used - sum(b for _n, b in shown))
        stack = [(f, series[i]) for i, (_n, f) in enumerate(parts)]
        if m.total and rest > 0:
            stack.append((rest / m.total, pal["lineStrong"]))
        p["segs"].set(stack, T("sys.free_n", human_bytes(m.available)))
        p["l2"].set_label(human_bytes(m.total))
        c = p["cells"]
        c[0]["v"].set_label(human_bytes(m.available))
        c[0]["s"].set_label(T("sys.of_total", f"{100.0 * m.available / m.total:.0f}" if m.total else "0"))
        c[1]["v"].set_label(human_bytes(m.used))
        c[1]["s"].set_label(T("sys.of_total", f"{pct:.0f}"))
        c[2]["v"].set_label(f"{human_bytes(m.swap_used)} / {human_bytes(m.swap_total)}" if m.swap_total
                            else T("sys.no_swap"))
        c[2]["s"].set_label("")
        p["swap_bar"].set_visible(bool(m.swap_total))
        p["swap_bar"].set(m.swap_used / m.swap_total if m.swap_total else 0)
        top = max((b for _n, b in shown), default=0)
        for i, (n, b) in enumerate(shown):
            p["rows"].set(i, i, n, b / top if top else 0, human_bytes(b), f"{100.0 * b / m.total:.0f}%" if m.total else "")
        n = len(shown)
        if m.total and rest > 0 and n < len(p["rows"].rows):
            p["rows"].set(n, 6, T("sys.rest_procs"), 0, human_bytes(rest), f"{100.0 * rest / m.total:.0f}%", bar=False)
            n += 1
        p["rows"].hide_from(n)
        p["tcount"].set_label(str(len(shown)))
        set_tab_value("memory", f"{pct:.0f}%")

    def apply_disks(ds) -> None:
        p = pages["disk"]
        alerts = [x for x in ds if x.alert]
        free = sum(x.avail for x in ds)
        c = p["cells"]
        c[0]["v"].set_label(human_bytes(free))
        c[0]["s"].set_label(T("sys.free_of_total", human_bytes(sum(x.total for x in ds))))
        c[1]["v"].set_label(str(len(ds)))
        c[1]["s"].set_label(T("sys.with_space", len(ds) - len(alerts)))
        c[2]["v"].set_label(("⚠ " if alerts else "") + str(len(alerts)))
        (c[2]["v"].add_css_class if alerts else c[2]["v"].remove_css_class)("alert")
        c[2]["s"].set_label(T("sys.at_pct", alerts[0].mount, f"{alerts[0].percent:.0f}") if alerts else T("sys.all_fine"))
        p["count"].set_label(str(len(ds)))
        sig = tuple((x.mount, x.device) for x in ds)
        if sig != p["sig"]:
            clear(p["list"])
            p["cards"], p["sig"] = {}, sig
            if not ds:
                p["list"].append(label(T("sys.no_disks"), "sys-empty", xalign=0))
            for x in ds:
                card = Gtk.Box(spacing=14)
                card.add_css_class("sys-disk")
                rg = ring.Ring(52, 6)
                over = Gtk.Overlay()
                over.set_child(rg)
                pc = label("", "sys-disk-pct", halign=Gtk.Align.CENTER, valign=Gtk.Align.CENTER)
                over.add_overlay(pc)
                card.append(over)
                col = vbox(1, hexpand=True, valign=Gtk.Align.CENTER)
                head = Gtk.Box(spacing=8)
                head.append(label(x.mount, "sys-disk-mount", xalign=0, ellipsize=2))
                chip = label("", "sys-chip")
                head.append(chip)
                col.append(head)
                col.append(label(f"{x.device} · {x.fstype}", "sys-s", xalign=0, ellipsize=3))
                card.append(col)
                right = vbox(1, valign=Gtk.Align.CENTER)
                free_l = label("", "sys-v", xalign=1)
                of_l = label("", "sys-s", xalign=1)
                right.append(free_l)
                right.append(of_l)
                card.append(right)
                p["list"].append(card)
                p["cards"][x.mount] = (card, rg, pc, chip, free_l, of_l)
        for x in ds:
            card, rg, pc, chip, free_l, of_l = p["cards"][x.mount]
            rg.set(x.percent / 100, "alert" if x.alert else "")
            pc.set_label(f"{x.percent:.0f}%")
            free_l.set_label(human_bytes(x.avail))
            of_l.set_label(T("sys.free_of_total", human_bytes(x.total)))
            chip.set_label("⚠ " + T("sys.full") if x.alert else "")
            (card.add_css_class if x.alert else card.remove_css_class)("alert")
        set_tab_value("disk", T("sys.tab_alert", len(alerts)) if alerts else T("sys.drives", len(ds)),
                      warn=bool(alerts))
        state["tabvals"]["disk_icon"] = bool(alerts)

    def apply_gpu(g: Gpu) -> None:
        p = pages["gpu"]
        load = g.load or 0
        p["hist"].queue_draw()
        p["gauge"].set(load / 100, load >= 95)
        p["num"].set_label(str(load))
        peak, _mean, ago = history_stats(history["gpu"])
        mins, secs = split_seconds(ago)
        when = T("sys.dur_min", mins, secs) if mins else T("sys.dur_s", secs)
        p["right"].set_markup(T("sys.peak_ago", f"<b>{peak:.0f}%</b>", when) if len(history["gpu"]) > 1 else "")
        c = p["cells"]
        c[0]["v"].set_label(f"{g.power:.0f} / {g.power_limit:.0f} W" if g.power is not None and g.power_limit
                            else (f"{g.power:.0f} W" if g.power is not None else "-"))
        p["power_bar"].set_visible(bool(g.power is not None and g.power_limit))
        p["power_bar"].set((g.power or 0) / g.power_limit if g.power_limit else 0)
        c[1]["v"].set_label(f"{g.fan}%" if g.fan is not None else "-")
        c[1]["s"].set_label(T("sys.fan_stopped") if g.fan == 0 else "")
        c[2]["v"].set_label(f"{g.clock} MHz" if g.clock is not None else "-")
        if g.mem_used is not None and g.mem_total:
            p["vval"].set_label(f"{g.mem_used / 1024:.1f} / {g.mem_total / 1024:.1f} GB")
            p["gl2"].set_label(f"{g.mem_total / 1024:.1f} GB")
            p["gl1"].set_label(T("sys.vram_pct", f"{100.0 * g.mem_used / g.mem_total:.0f}",
                                 human_bytes((g.mem_total - g.mem_used) * 1048576)))
            if not getattr(state["snap"], "procs_read", False):
                p["segs"].set([(g.mem_used / g.mem_total, "accent")])
        if getattr(state["snap"], "procs_read", False):
            grouped: dict[str, list] = {}
            for x in g.procs:
                grouped.setdefault(x.name, []).append(x)
            groups = sorted(grouped.items(), key=lambda kv: -sum(x.mb for x in kv[1]))
            sig = tuple((name, sum(x.mb for x in xs)) for name, xs in groups)
            if g.mem_total:
                shown = [(n, float(sum(x.mb for x in xs))) for n, xs in groups[:6]]
                p["segs"].set([(f, series[i]) for i, (_n, f) in enumerate(stack_parts(shown, float(g.mem_total), 6))])
            if sig != p["sig"]:
                p["sig"] = sig
                p["pcount"].set_label(str(len(groups)))
                clear(p["plist"])
                if not g.procs:
                    p["plist"].append(label(T("sys.gpu_none"), "sys-empty", xalign=0))
                kinds = {"C": ("Σ ", T("sys.kind.compute")), "G": ("⊞ ", T("sys.kind.graphics")),
                         "C+G": ("◑ ", T("sys.kind.both"))}
                for i, (name, xs) in enumerate(groups[:8]):
                    kind = "C+G" if len({x.kind for x in xs} | ({"C", "G"} if any("+" in x.kind for x in xs) else set())) > 1 else xs[0].kind
                    r = Gtk.Box(spacing=10)
                    r.set_size_request(-1, 28)
                    r.append(dot(min(i, 5)) if i < 6 else dot(6))
                    r.append(label(name + (f" ×{len(xs)}" if len(xs) > 1 else ""), "sys-name", xalign=0,
                                   ellipsize=3, hexpand=True))
                    glyph, word = kinds.get(kind, ("", kind))
                    kind_l = label(glyph + word, "sys-kind", valign=Gtk.Align.CENTER)
                    kind_l.set_size_request(92, -1)
                    r.append(kind_l)
                    r.append(label(f"{sum(x.mb for x in xs)} MB", "sys-val", xalign=1, width_chars=8))
                    r.set_tooltip_text("pid " + ", ".join(str(x.pid) for x in xs))
                    p["plist"].append(r)
        set_tab_value("gpu", f"{load}%")

    def header_for_tab() -> None:
        s, t = state["snap"], state["tab"]
        if s is None:
            temp_pill(None)
        elif t == "cpu":
            temp_pill(s.temp)
        elif t == "gpu" and s.gpu:
            temp_pill(s.gpu.temp)
        else:
            temp_pill(None)

    def subtitle() -> None:
        s, t = state["snap"], state["tab"]
        if s is None:
            panel.subtitle.set_label(T("sys.measuring"))
        elif t == "cpu":
            panel.subtitle.set_label(sampler.info["model"] or T("sys.tab.cpu"))
        elif t == "memory":
            panel.subtitle.set_label(f"{human_bytes(s.mem.used)} {T('sys.of')} {human_bytes(s.mem.total)}")
        elif t == "disk":
            panel.subtitle.set_label(T("sys.drives", len(s.disks)))
        elif t == "gpu" and s.gpu:
            panel.subtitle.set_label(s.gpu.name)

    # ---- the frame: tabs, stack, refresh, keys --------------------------

    def show(name: str) -> None:
        state["tab"] = name
        state["stack"].set_visible_child_name(name)
        for key, btn in state["buttons"].items():
            (btn.add_css_class if key == name else btn.remove_css_class)("on")
        header_for_tab()
        subtitle()
        if name == "gpu":
            pages["gpu"]["sig"] = None
            tick(now=True)

    def build(_panel):
        style()
        root = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=10)
        root.set_margin_top(12)
        tab_bar = Gtk.Box(spacing=6, homogeneous=True)
        tab_bar.add_css_class("sys-tabs")
        for key in tabs:
            inner = vbox(2, halign=Gtk.Align.CENTER, valign=Gtk.Align.CENTER)
            top = Gtk.Box(spacing=6, halign=Gtk.Align.CENTER)
            top.append(label(glyphs[key], "systab-n"))
            top.append(label(T("sys.tab." + key), "systab-n"))
            inner.append(top)
            val = label("", "systab-v")
            state["tabvals"][key] = val
            inner.append(val)
            btn = Gtk.Button(child=inner)
            btn.add_css_class("systab")
            btn.connect("clicked", lambda _b, key=key: show(key))
            state["buttons"][key] = btn
            tab_bar.append(btn)
        root.append(tab_bar)
        stack = Gtk.Stack(vhomogeneous=False, hhomogeneous=True)
        state["stack"] = stack
        build_cpu()
        build_memory()
        build_disk()
        if "gpu" in tabs:
            build_gpu()
        for key in tabs:
            stack.add_named(pages[key]["widget"], key)
        root.append(k.scroller(stack, 820))
        GLib.idle_add(attach)
        show(state["tab"])
        tick(now=True)
        GLib.timeout_add(2000, lambda: (tick(), True)[1])
        return root

    def attach():
        win = panel.window
        if win is None:
            return True
        keys = Gtk.EventControllerKey()
        keys.set_propagation_phase(Gtk.PropagationPhase.CAPTURE)

        def pressed(_c, keyval, _code, st):
            order = tabs
            i = order.index(state["tab"])
            if keyval == Gdk.KEY_Tab:
                show(order[(i + 1) % len(order)])
            elif keyval == Gdk.KEY_ISO_Left_Tab:
                show(order[(i - 1) % len(order)])
            elif Gdk.KEY_1 <= keyval <= Gdk.KEY_9 and keyval - Gdk.KEY_1 < len(order):
                show(order[keyval - Gdk.KEY_1])
            else:
                return False
            return True
        keys.connect("key-pressed", pressed)
        win.add_controller(keys)
        return False

    def tick(now: bool = False) -> None:
        if state["busy"]:
            return
        state["busy"] = True
        want_procs = state["tab"] == "gpu"

        def work():
            try:
                snap = sampler.sample(gpu_procs=want_procs)
                snap.procs_read = want_procs
            except Exception:  # a reading that fails must not stop the panel
                snap = None

            def done():
                state["busy"] = False
                if snap is not None:
                    state["snap"] = snap
                    apply(snap)
                return False
            GLib.idle_add(done)
        threading.Thread(target=work, daemon=True).start()

    panel.on_build = build
    return panel.run()
