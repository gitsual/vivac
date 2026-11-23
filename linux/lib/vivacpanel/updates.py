"""Updates: what is waiting to be installed, by origin, and whether a restart is.

The Windows side's Show-Updates (windows/lib/Updates.psm1) on Arch: the
official repositories (checkupdates, which never touches the live database),
the AUR (yay -Qua, as the bar's own counter does), uv's tools and npm's
globals. An AUR package the update script recorded as failing to build for
that very version is listed but not counted, as updates-count.sh does.
Nothing is installed here: "update everything" opens update-system.sh in a
terminal, where what it does and asks stays in view.

The bar's line is cached until pacman's database, the blocked list or ten
minutes change, because asking takes seconds (the network) and the bar asks
every time it redraws.
"""
from __future__ import annotations

import html
import json
import os
import re
import shutil
import subprocess
import time
from concurrent.futures import ThreadPoolExecutor
from dataclasses import asdict, dataclass, field
from pathlib import Path

SOURCES = ("repo", "aur", "uv", "npm")
CACHE_SECONDS = 600
# What takes effect only after a restart: the kernel, its microcode and
# firmware, the graphics stack.
RESTART = re.compile(r"^(lib32-)?(linux(-lts|-zen|-hardened|-rt)?|linux-firmware(-.+)?|(amd|intel)-ucode"
                     r"|mesa|vulkan-.+|nvidia(-.+)?|libva-nvidia-driver)$")
KERNEL = re.compile(r"^(linux(-lts|-zen|-hardened|-rt)?|linux-firmware(-.+)?|(amd|intel)-ucode)$")


@dataclass
class Pkg:
    name: str
    old: str
    new: str
    source: str
    restart: bool = False


@dataclass
class Result:
    groups: dict[str, list[Pkg]] = field(default_factory=lambda: {s: [] for s in SOURCES})
    blocked: list[Pkg] = field(default_factory=list)
    reboot: bool = False
    checked: float = 0.0

    @property
    def total(self) -> int:
        return sum(len(p) for p in self.groups.values())

    @property
    def restart(self) -> bool:
        return any(p.restart for p in self.groups["repo"] + self.groups["aur"])

    @property
    def kernel(self) -> bool:
        return any(KERNEL.match(p.name) for p in self.groups["repo"] + self.groups["aur"])


def _state_dir() -> Path:
    return Path(os.environ.get("XDG_STATE_HOME") or Path.home() / ".local" / "state") / "waybar-updates"


def _cache_file() -> Path:
    return Path(os.environ.get("XDG_CACHE_HOME") or Path.home() / ".cache") / "vivac" / "updates.json"


def _run(cmd: list[str], timeout: int = 60) -> str:
    """Stdout of a tool whatever its exit status (checkupdates says 2 for
    nothing, npm 1 for something); empty when it is missing or stalls."""
    if not shutil.which(cmd[0]):
        return ""
    try:
        return subprocess.run(cmd, capture_output=True, text=True, timeout=timeout,
                              stdin=subprocess.DEVNULL).stdout
    except (OSError, subprocess.TimeoutExpired):
        return ""


def _pacman_lines(text: str, source: str) -> list[Pkg]:
    out = []
    for line in text.splitlines():
        m = re.match(r"^(\S+)\s+(\S+)\s+->\s+(\S+)", line)
        if m:
            out.append(Pkg(m[1], m[2], m[3], source, bool(RESTART.match(m[1]))))
    return out


def repo_updates() -> list[Pkg]:
    return _pacman_lines(_run(["checkupdates"], 120), "repo")


def aur_updates() -> list[Pkg]:
    helper = "yay" if shutil.which("yay") else "paru"
    return _pacman_lines(_run([helper, "-Qua"], 90), "aur")


def blocked_aur() -> set[str]:
    try:
        return set((_state_dir() / "aur-blocked").read_text(encoding="utf-8").splitlines())
    except OSError:
        return set()


def uv_updates() -> list[Pkg]:
    out = []
    for line in _run(["uv", "tool", "list", "--outdated"], 60).splitlines():
        m = re.match(r"^([^\s-]\S*)\s+v?(\S+)\s+[\[(]latest:\s*v?([^\])\s]+)", line)
        if m:
            out.append(Pkg(m[1], m[2], m[3], "uv"))
    return out


def npm_updates() -> list[Pkg]:
    try:
        data = json.loads(_run(["npm", "outdated", "-g", "--json"], 60) or "{}")
    except json.JSONDecodeError:
        return []
    out = []
    for name, info in sorted(data.items() if isinstance(data, dict) else []):
        if isinstance(info, dict) and info.get("latest"):
            out.append(Pkg(name, str(info.get("current") or "?"), str(info["latest"]), "npm"))
    return out


def needs_reboot() -> bool:
    """The running kernel's modules are no longer installed: pacman removes
    them when it installs the next version."""
    release = _run(["uname", "-r"], 5).strip()
    if not release:
        return False
    modules = Path(os.environ.get("VIVAC_MODULES") or "/usr/lib/modules")
    return modules.is_dir() and not (modules / release).is_dir()


def _stamp() -> list[float]:
    def mtime(path: Path) -> float:
        try:
            return path.stat().st_mtime
        except OSError:
            return 0.0
    return [mtime(Path(os.environ.get("VIVAC_PACMAN_LOCAL") or "/var/lib/pacman/local")),
            mtime(_state_dir() / "aur-blocked")]


def _from_cache() -> Result | None:
    try:
        data = json.loads(_cache_file().read_text(encoding="utf-8"))
        if data["stamp"] != _stamp() or time.time() - data["time"] > CACHE_SECONDS:
            return None
        r = Result(checked=data["time"])
        r.groups = {s: [Pkg(**p) for p in data["groups"].get(s, [])] for s in SOURCES}
        r.blocked = [Pkg(**p) for p in data["blocked"]]
        return r
    except (OSError, ValueError, KeyError, TypeError):
        return None


def _to_cache(r: Result, stamp: list[float]) -> None:
    try:
        path = _cache_file()
        path.parent.mkdir(parents=True, exist_ok=True)
        tmp = path.with_suffix(".tmp")
        tmp.write_text(json.dumps({"stamp": stamp, "time": r.checked,
                                   "groups": {s: [asdict(p) for p in v] for s, v in r.groups.items()},
                                   "blocked": [asdict(p) for p in r.blocked]}), encoding="utf-8")
        tmp.replace(path)
    except OSError:
        pass


def collect(use_cache: bool = True) -> Result:
    """Every origin asked at once. The restart flag is always live."""
    r = _from_cache() if use_cache else None
    if r is None:
        stamp = _stamp()
        r = Result(checked=time.time())
        with ThreadPoolExecutor(4) as pool:
            jobs = {s: pool.submit(fn) for s, fn in (("repo", repo_updates), ("aur", aur_updates),
                                                     ("uv", uv_updates), ("npm", npm_updates))}
            for source, job in jobs.items():
                r.groups[source] = job.result()
        blocked = blocked_aur()
        r.blocked = [p for p in r.groups["aur"] if f"{p.name} {p.new}" in blocked]
        r.groups["aur"] = [p for p in r.groups["aur"] if p not in r.blocked]
        _to_cache(r, stamp)
    r.reboot = needs_reboot()
    return r


def waybar(args: list[str] | None = None) -> int:
    from .kit import T
    r = collect()
    if r.total == 0 and not r.reboot:
        # Still a button: the user wants a way to update everything at hand.
        print(json.dumps({"text": "0", "tooltip": T("updates.click"), "class": "none"}))
        return 0
    names = {"repo": T("updates.repo"), "aur": T("updates.aur"), "uv": T("updates.uv"), "npm": T("updates.npm")}
    lines = [f"{names[s]}: {len(r.groups[s])}" for s in SOURCES if r.groups[s]]
    if r.blocked:
        lines.append(T("updates.blocked_tip", " ".join(p.name for p in r.blocked)))
    if r.restart or r.reboot:
        lines.append(T("updates.reboot_tip"))
    lines.append(T("updates.click"))
    cls = "security" if r.kernel else "pending"
    print(json.dumps({"text": str(r.total) if r.total else "↻",
                      "tooltip": html.escape("\n".join(lines), quote=False), "class": cls}))
    return 0


# ---------------------------------------------------------------- the window

GLYPH = "\U000F03D6"       # package-variant
GLYPH_REPO, GLYPH_AUR, GLYPH_UV, GLYPH_NPM = "\U000F03D6", "\U000F08C7", "\U000F0320", "\U000F0399"
GLYPH_RESTART, GLYPH_OK, GLYPH_LOCK = "\U000F0709", "\U000F05E0", "\U000F033E"
UPDATE_SCRIPT = Path.home() / ".config" / "waybar" / "scripts" / "update-system.sh"


def launch_update() -> None:
    """The host's own script, in a terminal of its own."""
    subprocess.Popen(["kitty", "--class", "vivac-update", "-e", str(UPDATE_SCRIPT)], start_new_session=True)


def main() -> int:
    import threading

    from .kit import T, gtk_kit

    k = gtk_kit()
    Gtk, GLib = k.Gtk, k.GLib
    panel = k.Panel("updates", GLYPH, T("updates.title"), T("updates.checking"),
                    hints=[("Esc", T("updates.key.close"))], width=460)
    state = {"armed": False, "root": None}
    labels = {"repo": (T("updates.repo"), GLYPH_REPO), "aur": (T("updates.aur"), GLYPH_AUR),
              "uv": (T("updates.uv"), GLYPH_UV), "npm": (T("updates.npm"), GLYPH_NPM)}

    def clear(box):
        child = box.get_first_child()
        while child:
            nxt = child.get_next_sibling()
            box.remove(child)
            child = nxt

    def build(_panel):
        root = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=4)
        root.set_margin_top(12)
        state["root"] = root
        load(use_cache=True)
        panel.keys_extra = None
        return root

    def load(use_cache: bool):
        root = state["root"]
        clear(root)
        panel.subtitle.set_label(T("updates.checking"))
        wait = Gtk.Label(label=T("updates.checking_long"), xalign=0, wrap=True)
        wait.add_css_class("empty")
        root.append(wait)

        def work():
            r = collect(use_cache=use_cache)
            GLib.idle_add(lambda: (fill(r), False)[1])
        threading.Thread(target=work, daemon=True).start()

    def pkg_row(p: Pkg, glyph: str, blocked: bool = False):
        end = Gtk.Box(spacing=6, valign=Gtk.Align.CENTER)
        if blocked:
            end.append(k.badge(T("updates.blocked"), "info"))
        elif p.restart:
            end.append(k.badge(T("updates.needs_restart"), "warn"))
        r = k.row(GLYPH_LOCK if blocked else (GLYPH_RESTART if p.restart else glyph), p.name,
                  f"{p.old}  →  {p.new}", end=end,
                  tooltip=T("updates.blocked_tip_row") if blocked else "")
        if blocked:
            r.add_css_class("muted-row")
        return r

    def fill(r: Result):
        root = state["root"]
        clear(root)
        state["armed"] = False
        if r.total:
            panel.subtitle.set_label(T("updates.subtitle", r.total))
        else:
            panel.subtitle.set_label(T("updates.restart_waiting") if r.reboot else T("updates.up_to_date"))

        hero = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=8)
        hero.add_css_class("hero")
        top = Gtk.Box(spacing=12)
        big = Gtk.Label(label=str(r.total) if r.total else GLYPH_OK, xalign=0)
        big.add_css_class("big")
        top.append(big)
        cap = Gtk.Label(label=T("updates.pending", r.total) if r.total else T("updates.up_to_date"),
                        xalign=0, valign=Gtk.Align.END, hexpand=True)
        cap.add_css_class("subtitle")
        top.append(cap)
        hero.append(top)
        if r.total:
            chips = Gtk.Box(spacing=6)
            for s in SOURCES:
                if r.groups[s]:
                    chips.append(k.badge(f"{labels[s][0]} {len(r.groups[s])}"))
            n_restart = sum(p.restart for g in r.groups.values() for p in g)
            if n_restart:
                chips.append(k.badge(T("updates.chip_restart", n_restart), "alert" if r.kernel else "warn"))
            hero.append(chips)
            note = T("updates.restart_note") if r.restart else T("updates.no_restart_note")
            n = Gtk.Label(label=note, xalign=0, wrap=True)
            n.add_css_class("subtitle")
            hero.append(n)
        root.append(hero)

        if r.reboot:  # a new kernel is installed already: the restart is the update
            box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL)
            box.add_css_class("block")
            box.set_margin_top(8)
            btn = Gtk.Button(label=T("updates.reboot"))
            btn.add_css_class("action")
            btn.add_css_class("danger")

            def reboot(b):
                if not state["armed"]:
                    state["armed"] = True
                    b.set_label(T("updates.reboot_confirm"))
                    return
                subprocess.Popen(["systemctl", "reboot"], start_new_session=True)
            btn.connect("clicked", lambda b: reboot(b))
            row = k.row(GLYPH_RESTART, T("updates.reboot_row"), T("updates.reboot_row_sub"), end=btn)
            box.append(row)
            root.append(box)

        body = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=4)
        for s in SOURCES:
            items = r.groups[s]
            blocked = r.blocked if s == "aur" else []
            if not items and not blocked:
                continue
            body.append(k.section(labels[s][0], len(items)))
            block = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=2)
            block.add_css_class("block")
            for p in sorted(items, key=lambda p: (not p.restart, p.name)):
                block.append(pkg_row(p, labels[s][1]))
            for p in blocked:
                block.append(pkg_row(p, labels[s][1], blocked=True))
            body.append(block)
        if not r.total and not r.blocked:
            e = Gtk.Label(label=T("updates.none"), xalign=0, wrap=True)
            e.add_css_class("empty")
            body.append(e)
        root.append(k.scroller(body, 480))

        actions = Gtk.Box(spacing=8)
        actions.set_margin_top(12)
        go = Gtk.Button(label=T("updates.update_all"))
        go.add_css_class("primary")
        go.add_css_class("action")
        go.set_sensitive(UPDATE_SCRIPT.exists())
        go.connect("clicked", lambda *_: (launch_update(), panel.window.close()))
        again = Gtk.Button(label=T("updates.refresh"))
        again.add_css_class("action")
        again.connect("clicked", lambda *_: load(use_cache=False))
        actions.append(go)
        actions.append(again)
        root.append(actions)

    panel.on_build = build
    return panel.run()
