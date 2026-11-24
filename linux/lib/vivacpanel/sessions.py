"""vivac-panel sessions: the owner's session photos (~/bin/sesiones, not part
of vivac: the bar shows its button only with bar_owner_scripts=yes) as a
panel of the common design, where the button used to ask in rofi.

What it shows comes from the tool itself: `sesiones waybar` says when the
last photo was taken and what a restore brings back, `sesiones ver` lists the
photo's windows, read here by workspace. Restoring reopens every window in
the photo, open or not, so it takes a second press, the way the power panel
asks before a restart; saving is one press.
"""
from __future__ import annotations

import json
import os
import re
import subprocess
from dataclasses import dataclass, field
from pathlib import Path

from .kit import T

GLYPH = {"sessions": "\U000F0193", "restore": "\U000F0450", "save": "\U000F0193", "workspace": "\U000F0570"}
WINDOW_LINE = re.compile(r"^\s*\[(\d+)\]\s+(.+?)\s*$")
TAKEN_LINE = re.compile(r"^\S.*?(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}(?::\d{2})?)")


@dataclass
class Photo:
    taken: str = ""
    windows: list[tuple[int, str]] = field(default_factory=list)


class Restore:
    """Two presses: the first arms (the panel says what comes back), the
    second restores. Esc or another button disarms."""

    def __init__(self) -> None:
        self.armed = False

    def press(self) -> bool:
        if self.armed:
            self.armed = False
            return True
        self.armed = True
        return False

    def cancel(self) -> None:
        self.armed = False


def tool() -> str:
    return os.environ.get("VIVAC_SESIONES") or str(Path.home() / "bin" / "sesiones")


def available() -> bool:
    return os.access(tool(), os.X_OK)


def parse_ver(text: str) -> Photo:
    photo = Photo()
    for line in text.splitlines():
        m = WINDOW_LINE.match(line)
        if m:
            photo.windows.append((int(m.group(1)), m.group(2)))
            continue
        t = TAKEN_LINE.match(line)
        if t and not photo.taken:
            photo.taken = t.group(1)
    return photo


def by_workspace(windows: list[tuple[int, str]]) -> list[tuple[int, list[str]]]:
    groups: dict[int, list[str]] = {}
    for ws, title in windows:
        groups.setdefault(ws, []).append(title)
    return sorted(groups.items())


def facts(bar: dict) -> list[str]:
    """The lines of the bar's tooltip that describe the photo, not the ones
    that explain the clicks (the panel has its own buttons for those)."""
    lines = str(bar.get("tooltip", "")).splitlines()[1:]
    return [line for line in lines if line and not re.match(r"^(Clic|Click)\b", line)]


def command(action: str, tool: str | None = None) -> list[str]:
    path = tool or globals()["tool"]()
    return [path, {"save": "guardar", "restore": "restaurar"}[action]]


def _run(args: list[str], timeout: int = 20) -> str:
    try:
        return subprocess.run(args, capture_output=True, text=True, timeout=timeout).stdout
    except (OSError, subprocess.SubprocessError):
        return ""


def load() -> tuple[Photo, list[str]]:
    photo = parse_ver(_run([tool(), "ver"]))
    try:
        bar = json.loads(_run([tool(), "waybar"]) or "{}")
    except ValueError:
        bar = {}
    return photo, facts(bar if isinstance(bar, dict) else {})


def extra_css(p: dict[str, str]) -> str:
    return f"""
.vivac .confirm {{ background: alpha({p['alert']}, 0.18); border-radius: 10px; padding: 10px 14px;
  box-shadow: inset 0 0 0 1px {p['alert']}; margin-top: 12px; }}
.vivac .confirm .ctext {{ font-size: 13px; font-weight: 700; color: {p['alert']}; }}
.vivac .fact {{ font-size: 13px; color: {p['textSecondary']}; }}
.vivac .wsname {{ font-size: 12px; font-weight: 700; color: {p['accent']}; }}
.vivac .wtitle {{ font-size: 13px; color: {p['text']}; }}
.vivac .outcome {{ font-size: 13px; color: {p['success']}; margin-top: 10px; }}
"""


def main() -> int:
    from .kit import gtk_kit, palette

    k = gtk_kit()
    Gtk, Gdk, GLib = k.Gtk, k.Gdk, k.GLib
    restore = Restore()
    photo, lines = load() if available() else (Photo(), [])
    widgets: dict = {}

    subtitle = lines[0] if lines else (T("sessions.none") if available() else T("sessions.missing"))
    panel = k.Panel("sessions", GLYPH["sessions"], T("sessions.title"), subtitle,
                    [("R", T("sessions.restore")), ("G", T("sessions.save")), ("Esc", T("power.hint.close"))],
                    width=460)

    def paint() -> None:
        widgets["confirm"].set_visible(restore.armed)

    def do_restore() -> None:
        if not photo.windows:
            return
        if not restore.press():
            paint()
            return
        log = Path.home() / ".sesiones" / "sesiones.log"
        log.parent.mkdir(parents=True, exist_ok=True)
        with open(log, "a", encoding="utf-8") as out:
            subprocess.Popen(command("restore"), start_new_session=True, stdout=out, stderr=out)
        panel.window.close()

    def do_save() -> None:
        restore.cancel()
        paint()
        ok = subprocess.run(command("save"), capture_output=True, timeout=60).returncode == 0 if available() else False
        subprocess.run(["pkill", "-RTMIN+9", "waybar"], capture_output=True)
        widgets["outcome"].set_label(T("sessions.saved") if ok else T("sessions.save_failed"))
        widgets["outcome"].set_visible(True)

    def build(_panel):
        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=4)
        for line in lines[1:]:
            f = Gtk.Label(label=line, xalign=0, wrap=True)
            f.add_css_class("fact")
            box.append(f)
        if photo.windows:
            box.append(k.section(T("sessions.windows"), len(photo.windows)))
            listing = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=6)
            for ws, titles in by_workspace(photo.windows):
                head = Gtk.Label(label=T("sessions.workspace", ws), xalign=0)
                head.add_css_class("wsname")
                listing.append(head)
                for title in titles:
                    t = Gtk.Label(label=title, xalign=0, ellipsize=3)
                    t.add_css_class("wtitle")
                    t.set_margin_start(12)
                    listing.append(t)
            box.append(k.scroller(listing, 360))
        actions = Gtk.Box(spacing=8, homogeneous=True)
        actions.set_margin_top(12)
        r = Gtk.Button(label=T("sessions.restore"))
        r.add_css_class("action")
        r.add_css_class("primary")
        r.set_sensitive(bool(photo.windows))
        r.connect("clicked", lambda *_: do_restore())
        s = Gtk.Button(label=T("sessions.save"))
        s.add_css_class("action")
        s.set_sensitive(available())
        s.connect("clicked", lambda *_: do_save())
        actions.append(r)
        actions.append(s)
        box.append(actions)
        confirm = Gtk.Box(spacing=10)
        confirm.add_css_class("confirm")
        ctext = Gtk.Label(label=T("sessions.confirm", len(photo.windows)), xalign=0, hexpand=True, wrap=True)
        ctext.add_css_class("ctext")
        confirm.append(ctext)
        confirm.set_visible(False)
        widgets["confirm"] = confirm
        box.append(confirm)
        outcome = Gtk.Label(xalign=0)
        outcome.add_css_class("outcome")
        outcome.set_visible(False)
        widgets["outcome"] = outcome
        box.append(outcome)
        GLib.idle_add(attach)
        return box

    def attach():
        keys = Gtk.EventControllerKey()
        keys.set_propagation_phase(Gtk.PropagationPhase.CAPTURE)
        keys.connect("key-pressed", on_key)
        panel.window.add_controller(keys)
        return False

    def on_key(_c, keyval, _code, _mods):
        if keyval == Gdk.KEY_Escape and restore.armed:
            restore.cancel()
            paint()
            return True
        if keyval in (Gdk.KEY_r, Gdk.KEY_R, Gdk.KEY_Return, Gdk.KEY_KP_Enter):
            do_restore()
            return True
        if keyval in (Gdk.KEY_g, Gdk.KEY_G):
            do_save()
            return True
        return False

    provider = Gtk.CssProvider()
    provider.load_from_string(extra_css(palette()))
    Gtk.StyleContext.add_provider_for_display(Gdk.Display.get_default(), provider, Gtk.STYLE_PROVIDER_PRIORITY_USER)
    panel.on_build = build
    return panel.run()
