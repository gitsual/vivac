"""Security: the firewall, the weekly antivirus scan and the audit, in one shield.

The Windows side's securityPill (windows/static/zebar/vivac/bar.js) reads
Defender; here the real things are the firewall (ufw, firewalld or nftables),
the user timer and service clamav-home-scan (a weekly ClamAV scan of the home)
and the workstation-security-audit script. Everything is read without root:
`systemctl is-active` for services, `pacman -Q` for what is installed, and
`systemctl --user show` for the scan, whose result systemd keeps only while
the unit stays loaded; the timer remembers when it last fired.
"""
from __future__ import annotations

import json
import shutil
import subprocess
import sys
import time
from dataclasses import dataclass, field

GLYPH_OK, GLYPH_WARN = "\U000F0565", "\U000F0ECC"
FIREWALLS = ("ufw", "firewalld", "nftables")
SCAN_UNIT, TIMER_UNIT, FRESHCLAM_UNIT = "clamav-home-scan.service", "clamav-home-scan.timer", "clamav-freshclam.service"
STALE_DAYS = 14
ORDER = {"ok": 0, "warn": 1, "alert": 2}


def _run(*cmd: str, timeout: float = 4.0) -> tuple[int, str]:
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
        return r.returncode, r.stdout
    except (OSError, subprocess.TimeoutExpired):
        return 127, ""


def _props(*cmd: str) -> dict[str, str]:
    props: dict[str, str] = {}
    for line in _run(*cmd)[1].splitlines():
        key, _, value = line.partition("=")
        if key:
            props[key] = value.strip()
    return props


def _epoch(value: str | None) -> int | None:
    """systemctl --timestamp=unix says "@1795434430", or nothing at all."""
    if value and value.startswith("@") and value[1:].isdigit():
        return int(value[1:])
    return None


@dataclass
class Status:
    fw_name: str | None = None
    fw_active: bool = False
    av_installed: bool = False
    av_running: bool = False
    last_ts: int | None = None
    last_result: str | None = None  # clean | infected | failed | unknown (None: never)
    timer_active: bool = False
    timer_next: int | None = None
    freshclam_active: bool = False
    audit: str | None = None
    issues: list[tuple[str, str, tuple]] = field(default_factory=list)  # (level, key, args)
    fw_level: str = "ok"
    av_level: str = "ok"

    @property
    def level(self) -> str:
        return max((i[0] for i in self.issues), key=ORDER.get, default="ok")


def status(now: float | None = None) -> Status:
    now = time.time() if now is None else now
    s = Status()
    s.audit = shutil.which("workstation-security-audit")

    installed = set()
    for line in _run("pacman", "-Q", *FIREWALLS, "clamav")[1].splitlines():
        installed.add(line.split()[0])
    s.av_installed = "clamav" in installed

    units = [f"{f}.service" for f in FIREWALLS if f in installed] + [FRESHCLAM_UNIT]
    states = _run("systemctl", "is-active", *units)[1].split()
    active = dict(zip(units, states))
    running = [f for f in FIREWALLS if active.get(f"{f}.service") == "active"]
    listed = [f for f in FIREWALLS if f in installed]
    s.fw_name = (running or listed or [None])[0]
    s.fw_active = bool(running)
    s.freshclam_active = active.get(FRESHCLAM_UNIT) == "active"

    svc = _props("systemctl", "--user", "--timestamp=unix", "show", SCAN_UNIT,
                 "-p", "LoadState,ActiveState,Result,ExecMainStatus,ExecMainExitTimestamp")
    timer = _props("systemctl", "--user", "--timestamp=unix", "show", TIMER_UNIT,
                   "-p", "LoadState,ActiveState,NextElapseUSecRealtime,LastTriggerUSec")
    s.av_running = svc.get("ActiveState") in ("active", "activating")
    s.timer_active = timer.get("ActiveState") == "active"
    s.timer_next = _epoch(timer.get("NextElapseUSecRealtime"))
    exit_ts = _epoch(svc.get("ExecMainExitTimestamp"))
    s.last_ts = exit_ts or _epoch(timer.get("LastTriggerUSec"))
    if exit_ts:
        # SuccessExitStatus=0 1 makes clamscan's "found something" a success to systemd.
        if svc.get("Result") not in ("success", "", None) or svc.get("ExecMainStatus") not in ("0", "1", "", None):
            s.last_result = "failed"
        else:
            s.last_result = "infected" if svc.get("ExecMainStatus") == "1" else "clean"
    elif s.last_ts:
        s.last_result = "unknown"

    def add(level: str, key: str, *args) -> None:
        s.issues.append((level, key, args))

    if not s.fw_name:
        add("warn", "security.p_fw_none")
        s.fw_level = "warn"
    elif not s.fw_active:
        add("alert", "security.p_fw_off")
        s.fw_level = "alert"
    if not s.av_installed:
        add("warn", "security.p_av_none")
        s.av_level = "warn"
    else:
        if s.last_result == "infected":
            add("alert", "security.p_infected")
        elif s.last_result == "failed":
            add("warn", "security.p_failed")
        elif s.last_ts is None and not s.av_running:
            add("warn", "security.p_never")
        elif s.last_ts and now - s.last_ts > STALE_DAYS * 86400 and not s.av_running:
            add("warn", "security.p_stale", ago(now, s.last_ts))
        if not s.timer_active:
            add("warn", "security.p_timer")
        if not s.freshclam_active:
            add("warn", "security.p_sig")
        s.av_level = max((i[0] for i in s.issues if i[1] != "security.p_fw_off" and i[1] != "security.p_fw_none"),
                         key=ORDER.get, default="ok")
    return s


def ago(now: float, ts: int) -> str:
    """"12 min ago", "3 h ago", "yesterday", "5 days ago"."""
    from .kit import T

    seconds = max(0, int(now - ts))
    if seconds < 3600:
        return T("security.minutes_ago", max(1, seconds // 60))
    if seconds < 86400:
        return T("security.hours_ago", seconds // 3600)
    days = seconds // 86400
    return T("security.yesterday") if days == 1 else T("security.days_ago", days)


def until(now: float, ts: int) -> str:
    from .kit import T

    seconds = ts - now
    if seconds < 3600:
        return T("security.soon")
    if seconds < 86400:
        return T("security.in_hours", int(seconds // 3600))
    days = int(seconds // 86400)
    return T("security.tomorrow") if days == 1 else T("security.in_days", days)


def firewall_line(s: Status) -> str:
    from .kit import T

    if not s.fw_name:
        return T("security.fw_none")
    return T("security.fw_on", s.fw_name) if s.fw_active else T("security.fw_off", s.fw_name)


def antivirus_line(s: Status, now: float | None = None) -> str:
    from .kit import T

    now = time.time() if now is None else now
    if not s.av_installed:
        return T("security.av_none")
    if s.av_running:
        return T("security.scan_running")
    if s.last_ts is None:
        return T("security.scan_never")
    when = ago(now, s.last_ts)
    return T({"clean": "security.scan_clean", "infected": "security.scan_infected",
              "failed": "security.scan_failed"}.get(s.last_result or "", "security.scan_unknown"), when)


def schedule_line(s: Status, now: float | None = None) -> str:
    from .kit import T

    now = time.time() if now is None else now
    if not s.timer_active:
        return T("security.timer_off")
    return T("security.next", until(now, s.timer_next)) if s.timer_next else ""


def waybar(args: list[str]) -> int:
    """One JSON line: the shield, class ok/warn/alert, and the detail as a tooltip."""
    from .kit import T

    now = time.time()
    s = status(now)
    lines = [f"{T('security.firewall')}: {firewall_line(s)}", f"{T('security.antivirus')}: {antivirus_line(s, now)}"]
    if s.av_installed and schedule_line(s, now):
        lines.append(schedule_line(s, now))
    if not s.freshclam_active and s.av_installed:
        lines.append(T("security.sig_off"))
    lines.append(f"{T('security.audit')}: {T('security.audit_sub') if s.audit else T('security.audit_none')}")
    print(json.dumps({"text": GLYPH_OK if s.level == "ok" else GLYPH_WARN, "tooltip": "\n".join(lines),
                      "class": s.level}, ensure_ascii=False))
    return 0


def scan_now() -> None:
    _run("systemctl", "--user", "start", "--no-block", SCAN_UNIT)


def schedule_scan() -> None:
    _run("systemctl", "--user", "enable", "--now", TIMER_UNIT)


def run_audit() -> None:
    """The audit in a terminal of its own: it uses sudo (ufw, rkhunter, lynis),
    so it has to be somewhere a password can be typed, and held open to read."""
    try:
        subprocess.Popen(["kitty", "--class", "vivac-audit", "--hold", "-e", "workstation-security-audit"],
                         start_new_session=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    except OSError:
        pass


def main() -> int:
    from .kit import T, gtk_kit, mix

    k = gtk_kit()
    Gtk, Gdk, GLib = k.Gtk, k.Gdk, k.GLib
    panel = k.Panel("security", GLYPH_OK if status().level == "ok" else GLYPH_WARN, T("security.title"), "",
                    hints=[("Tab", T("security.key.move")), ("Enter", T("security.key.activate")),
                           ("Esc", T("security.key.close"))], width=486)
    state = {"sig": None, "root": None, "scan_hint": 0}
    pal = dict(panel.p)
    pal["alertText"] = mix(pal["alert"], pal["text"], 0.43)
    pal["alertSoft"] = mix(pal["bg"], pal["alert"], 0.18)
    pal["successSoft"] = mix(pal["bg"], pal["success"], 0.18)
    pal["successText"] = mix(pal["success"], pal["text"], 0.2)
    MARK = {"ok": "\u2713", "warn": "\u26a0", "alert": "\u2716"}  # a shape for each level, never colour alone

    def style() -> None:
        p = pal
        css = f"""
.vivac .sec-hero {{ background: {p['surface']}; border-radius: 12px; padding: 16px; box-shadow: inset 0 0 0 1px {p['alert']}; }}
.vivac .sec-hero.ok {{ box-shadow: inset 0 0 0 1px {p['success']}; }}
.vivac .sec-shield {{ min-width: 72px; min-height: 72px; border-radius: 20px; background: {p['alertSoft']};
  box-shadow: inset 0 0 0 2px {p['alert']}; color: {p['alertText']}; font-size: 40px; }}
.vivac .sec-hero.ok .sec-shield {{ background: {p['successSoft']}; box-shadow: inset 0 0 0 2px {p['success']};
  color: {p['successText']}; }}
.vivac .sec-big {{ font-size: 22px; font-weight: 700; color: {p['text']}; }}
.vivac .sec-small {{ font-size: 12px; color: {p['textSecondary']}; }}
.vivac .sec-issues {{ padding-top: 8px; border-top: 1px solid {p['line']}; }}
.vivac .sec-issue {{ font-size: 13px; color: {p['text']}; min-height: 26px; }}
.vivac .sec-issue-g {{ font-size: 14px; color: {p['alert']}; }}
.vivac .sec-sec {{ font-size: 12px; letter-spacing: 1px; font-weight: 700; color: {p['muted']}; }}
.vivac .sec-note {{ font-size: 12px; color: {p['textSecondary']}; }}
.vivac .sec-card {{ background: {p['surface']}; border-radius: 12px; padding: 12px; }}
.vivac .sec-card.warn {{ box-shadow: inset 3px 0 0 {p['alert']}; }}
.vivac .sec-tile {{ min-width: 38px; min-height: 38px; border-radius: 10px; background: {p['surfaceAlt']}; }}
.vivac .sec-tile-g {{ font-size: 18px; color: {p['accent']}; }}
.vivac .sec-name {{ font-size: 14px; font-weight: 700; color: {p['text']}; }}
.vivac .sec-sub {{ font-size: 12px; color: {p['textSecondary']}; }}
.vivac .sec-pill {{ font-size: 12px; font-weight: 700; border-radius: 11px; padding: 0 9px; min-height: 22px;
  background: {p['surfaceAlt']}; color: {p['text']}; }}
.vivac .sec-pill.ok {{ background: {p['successSoft']}; color: {p['successText']}; }}
.vivac .sec-pill.warn, .vivac .sec-pill.alert {{ background: {p['alertSoft']}; color: {p['alertText']}; }}
.vivac button.sec-btn {{ border-radius: 10px; padding: 0 12px; min-height: 34px; border: none; box-shadow: none;
  background: {p['surfaceAlt']}; color: {p['text']}; font-size: 12px; }}
.vivac button.sec-btn:hover {{ background: {p['actionFill']}; color: {p['actionText']}; }}
.vivac button.sec-btn.primary {{ background: {p['actionFill']}; color: {p['actionText']}; font-weight: 700; }}
.vivac button.sec-btn.primary:hover {{ background: {p['focusRing']}; }}
.vivac button.sec-btn:focus-visible {{ box-shadow: 0 0 0 2px {p['bg']}, 0 0 0 4px {p['focusRing']}; }}
.vivac button.sec-btn:disabled {{ opacity: 0.5; }}
"""
        prov = Gtk.CssProvider()
        prov.load_from_string(css)
        Gtk.StyleContext.add_provider_for_display(Gdk.Display.get_default(), prov,
                                                  Gtk.STYLE_PROVIDER_PRIORITY_USER)

    def clear(box):
        child = box.get_first_child()
        while child:
            nxt = child.get_next_sibling()
            box.remove(child)
            child = nxt

    def label(text: str, *classes: str, xalign: float = 0.0, **kw):
        w = Gtk.Label(label=text, xalign=xalign, **kw)
        for c in classes:
            w.add_css_class(c)
        return w

    def vbox(spacing: int = 0, *classes: str, **kw):
        b = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=spacing, **kw)
        for c in classes:
            b.add_css_class(c)
        return b

    def pill(level: str, text: str):
        return label(f"{MARK[level]} {text}", "sec-pill", *([level] if level != "ok" else ["ok"]),
                     valign=Gtk.Align.CENTER, xalign=0.5)

    def buttons(*items, primary: bool = True):
        box = Gtk.Box(spacing=8)
        box.set_margin_top(2)
        for n, (glyph, text, fn, sensitive) in enumerate(items):
            inner = Gtk.Box(spacing=8)
            inner.append(Gtk.Label(label=glyph))
            inner.append(Gtk.Label(label=text))
            b = Gtk.Button(child=inner)
            b.add_css_class("sec-btn")
            if primary and n == 0 and sensitive:
                b.add_css_class("primary")
            b.set_sensitive(sensitive)
            b.connect("clicked", lambda *_, fn=fn: fn())
            box.append(b)
        return box

    def card(glyph: str, name: str, lines: list[str], end, level: str = "ok", actions=None):
        c = vbox(12, "sec-card")
        if level != "ok":
            c.add_css_class("warn")
        head = Gtk.Box(spacing=12)
        tile = Gtk.CenterBox(valign=Gtk.Align.START)
        tile.add_css_class("sec-tile")
        tile.set_center_widget(label(glyph, "sec-tile-g", xalign=0.5))
        head.append(tile)
        col = vbox(1, hexpand=True, valign=Gtk.Align.CENTER)
        col.append(label(name, "sec-name", ellipsize=3))
        for line in lines:
            col.append(label(line, "sec-sub", wrap=True))
        head.append(col)
        if end is not None:
            end.set_valign(Gtk.Align.START)
            head.append(end)
        c.append(head)
        if actions is not None:
            c.append(actions)
        return c

    def section(text: str, note: str = ""):
        row = Gtk.Box()
        row.set_margin_top(4)
        row.append(label(text.upper(), "sec-sec", hexpand=True))
        if note:
            row.append(label(note, "sec-note", xalign=1))
        return row

    def fill(force=False):
        s = status()
        sig = (s.level, s.fw_name, s.fw_active, s.last_ts, s.last_result, s.timer_active, s.timer_next,
               s.av_running, s.freshclam_active, s.av_installed, bool(s.audit))
        if not force and sig == state["sig"]:
            return True
        state["sig"] = sig
        root = state["root"]
        clear(root)
        names = {"ok": T("security.hero.ok"), "warn": T("security.hero.warn"), "alert": T("security.hero.alert")}
        panel.subtitle.set_label(T("security.sub.ok") if not s.issues else T("security.sub.issues", len(s.issues)))

        hero = vbox(10, "sec-hero")
        if s.level == "ok":
            hero.add_css_class("ok")
        top = Gtk.Box(spacing=16)
        top.append(label(GLYPH_OK if s.level == "ok" else GLYPH_WARN, "sec-shield", xalign=0.5,
                         valign=Gtk.Align.CENTER))
        col = vbox(3, valign=Gtk.Align.CENTER, hexpand=True)
        col.append(label(names[s.level], "sec-big", wrap=True))
        col.append(label(T("security.sub.ok") if not s.issues else T("security.hero.issues", len(s.issues)),
                         "sec-small"))
        top.append(col)
        hero.append(top)
        if s.issues:
            issues = vbox(2, "sec-issues")
            for level, key, args in s.issues:
                line = Gtk.Box(spacing=10)
                line.append(label(MARK[level], "sec-issue-g", xalign=0.5))
                line.append(label(T(key, *args), "sec-issue", wrap=True, hexpand=True))
                issues.append(line)
            hero.append(issues)
        body = vbox(10)
        body.append(hero)

        body.append(section(T("security.firewall")))
        fw_end = pill(s.fw_level, {"ok": T("security.badge.on"), "warn": T("security.badge.review"),
                                   "alert": T("security.badge.off")}[s.fw_level])
        body.append(card("\U000F0238", s.fw_name or T("security.firewall"), [firewall_line(s)], fw_end, s.fw_level))

        body.append(section(T("security.antivirus")))
        av_lines = [x for x in (antivirus_line(s), schedule_line(s) if s.av_installed else "") if x]
        acts = []
        if s.av_installed:
            acts.append(("\U000F0450", T("security.working") + " \u2026" if s.av_running else T("security.scan_now"),
                         lambda: (scan_now(), GLib.timeout_add(600, lambda: (fill(True), False)[1])), not s.av_running))
            if not s.timer_active:
                acts.append(("\U000F00F0", T("security.schedule"), lambda: (schedule_scan(), fill(True)), True))
        av_end = pill(s.av_level, "OK" if s.av_level == "ok" else T("security.badge.review"))
        body.append(card("\U000F0565", "ClamAV", av_lines, av_end, s.av_level, buttons(*acts) if acts else None))

        body.append(section(T("security.audit"), T("security.on_demand")))
        audit = card("\U000F0EDF", "workstation-security-audit",
                     [T("security.audit_sub") if s.audit else T("security.audit_none")], None, "ok",
                     buttons(("\U000F040A", T("security.run_audit"),
                              lambda: (run_audit(), panel.window.close()), bool(s.audit)), primary=False))
        body.append(audit)
        clear(root)
        root.append(k.scroller(body, 760))
        return True

    def build(_panel):
        style()
        root = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=8)
        root.set_margin_top(12)
        state["root"] = root
        fill(True)
        GLib.timeout_add_seconds(3, fill)  # a scan starting or ending while it is open
        return root

    panel.on_build = build
    return panel.run()

if __name__ == "__main__":
    sys.exit(main())
