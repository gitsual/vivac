"""OSD: the level indicator that follows a volume key.

The Windows side's New-VivacVolumeOsd / Show-VivacVolumeOsd, here driven by
the key itself: `vivac-panel osd volume up|down|mute` changes the default
output's volume (wpctl when present, pactl otherwise) and then shows a small
capsule with a glyph, a bar and the level, which closes by itself after a
moment. `vivac-panel osd volume` alone only shows the current level.

One indicator at a time. The capsule is owned by a Gtk.Application with a
unique id: the first invocation becomes the primary instance and shows it; one
that comes while it is open does not open another, GApplication forwards its
command line (`show LEVEL MUTED`) to the primary, which updates the capsule
and restarts the timer. The volume is changed in the invoking process, before
any of that, so the key works with no display too.

Unlike the other panels it never takes the focus nor closes on losing it
(Hyprland's no_focus rule keeps it from stealing it on Wayland).
"""
from __future__ import annotations

import os
import re
import shutil
import subprocess
from dataclasses import dataclass

WPCTL = os.environ.get("VIVAC_WPCTL", "wpctl")
PACTL = os.environ.get("VIVAC_PACTL", "pactl")
STEP = int(os.environ.get("VIVAC_VOLUME_STEP", "5") or 5)
SHOW_MS = 1200
ACTIONS = ("up", "down", "mute")

GLYPHS = {"off": "\U000F0581", "low": "\U000F057F", "mid": "\U000F0580", "high": "\U000F057E", "mute": "\U000F075F"}


@dataclass
class Level:
    percent: int
    muted: bool


def _run(args: list[str]) -> str | None:
    try:
        done = subprocess.run(args, capture_output=True, text=True, timeout=4)
    except (OSError, subprocess.TimeoutExpired):
        return None
    return done.stdout if done.returncode == 0 else None


def _backend() -> str | None:
    if shutil.which(WPCTL):
        return "wpctl"
    if shutil.which(PACTL):
        return "pactl"
    return None


def read() -> Level | None:
    """The default output's level and mute, or None with nothing to ask."""
    backend = _backend()
    if backend == "wpctl":
        out = _run([WPCTL, "get-volume", "@DEFAULT_AUDIO_SINK@"])
        match = re.search(r"Volume:\s*([\d.]+)", out or "")
        return Level(round(float(match[1]) * 100), "[MUTED]" in out) if match else None
    if backend == "pactl":
        vol = _run([PACTL, "get-sink-volume", "@DEFAULT_SINK@"])
        mute = _run([PACTL, "get-sink-mute", "@DEFAULT_SINK@"])
        percents = [int(p) for p in re.findall(r"(\d+)%", vol or "")]
        return Level(max(percents), "yes" in (mute or "")) if percents else None
    return None


def change(action: str) -> Level | None:
    """up / down by one step (up stops at 100% and unmutes), mute toggles.
    Returns what the output reads afterwards."""
    if action not in ACTIONS:
        raise ValueError(f"unknown volume action {action!r}")
    backend = _backend()
    if backend is None:
        return None
    if backend == "wpctl":
        sink = "@DEFAULT_AUDIO_SINK@"
        if action == "mute":
            _run([WPCTL, "set-mute", sink, "toggle"])
        else:
            if action == "up":
                _run([WPCTL, "set-mute", sink, "0"])
            sign = "+" if action == "up" else "-"
            # -l 1.0: a raise never goes beyond 100% (from a louder level set
            # elsewhere it lands on 100%)
            _run([WPCTL, "set-volume", "-l", "1.0", sink, f"{STEP}%{sign}"])
    else:
        sink = "@DEFAULT_SINK@"
        if action == "mute":
            _run([PACTL, "set-sink-mute", sink, "toggle"])
        else:
            now = read()
            if now is None:
                return None
            if action == "up":
                _run([PACTL, "set-sink-mute", sink, "0"])
                target = min(100, now.percent + STEP)
            else:
                target = max(0, now.percent - STEP)
            _run([PACTL, "set-sink-volume", sink, f"{target}%"])
    return read()


def glyph(percent: int, muted: bool) -> str:
    if muted:
        return GLYPHS["mute"]
    if percent <= 0:
        return GLYPHS["off"]
    return GLYPHS["low"] if percent < 34 else GLYPHS["mid"] if percent < 67 else GLYPHS["high"]


# ------------------------------------------------------------------ the capsule

BAR_W = 180
TICKS = 26  # a notch per ~4%; the OSD's ceiling is 100%


def output_name() -> str:
    """The default output's short name ("Starship/Matisse"), "" when the
    sound server does not answer."""
    from . import sound

    default = next((d for d in sound.devices("sink") if d.default), None)
    return sound.short(default.description).split(" \u00b7 ")[0] if default else ""


def css(p: dict[str, str]) -> str:
    return f"""
.vivac .osd {{ background: alpha({p['bg']}, 0.97); color: {p['text']}; border-radius: 36px;
  box-shadow: inset 0 0 0 2px {p['accent']}; padding: 0 20px; }}
.vivac .osd .osd-badge {{ min-width: 40px; min-height: 40px; border-radius: 20px; background: {p['surface']}; }}
.vivac .osd .osd-glyph {{ font-size: 22px; color: {p['accent']}; }}
.vivac .osd.muted .osd-glyph {{ color: {p['alert']}; }}
.vivac .osd .osd-name {{ font-size: 12px; color: {p['textSecondary']}; }}
.vivac .osd .osd-pct {{ font-size: 24px; font-weight: 700; min-width: 56px; }}
.vivac .osd.muted .osd-pct {{ color: {p['alert']}; font-size: 12px; }}
"""


def show(level: Level) -> int:
    """Open the capsule for the level, or update the one already open (this is
    the primary instance; a second invocation reaches here through
    command-line). Returns the application's exit status."""
    from .draw import widgets
    from .kit import T, css as kit_css, gtk_kit, palette

    k = gtk_kit()
    Gtk, Gdk, GLib = k.Gtk, k.Gdk, k.GLib
    import gi

    gi.require_version("Gio", "2.0")
    from gi.repository import Gio

    p = palette()
    drawn = widgets(Gtk, p)
    app = Gtk.Application(application_id="org.vivac.panel.osd", flags=Gio.ApplicationFlags.HANDLES_COMMAND_LINE)
    ui: dict = {}

    def draw(lv: Level) -> None:
        frame = ui["frame"]
        frame.remove_css_class("muted")
        if lv.muted:
            frame.add_css_class("muted")
        ui["glyph"].set_label(glyph(lv.percent, lv.muted))
        name = output_name()
        ui["name"].set_label(name)
        ui["name"].set_visible(bool(name))
        if lv.muted:
            ui["pct"].set_label(T("osd.muted"))
        else:
            ui["pct"].set_markup(f'{lv.percent}<span size="x-small" foreground="{p["textSecondary"]}">%</span>')
        ui["level"].set(min(100, lv.percent) / 100, muted=lv.muted)
        if ui.get("timer"):
            GLib.source_remove(ui["timer"])
        ui["timer"] = GLib.timeout_add(SHOW_MS, lambda: (ui.update(timer=0), ui["win"].close(), False)[2])

    def command_line(application, cmdline) -> int:
        argv = cmdline.get_arguments()[1:]
        if len(argv) == 3 and argv[0] == "show" and argv[1].isdigit():
            lv = Level(int(argv[1]), argv[2] == "1")
            if "win" not in ui:
                build()
            draw(lv)
            ui["win"].present()
        return 0

    def build() -> None:
        provider = Gtk.CssProvider()
        provider.load_from_string(kit_css(p) + css(p))
        Gtk.StyleContext.add_provider_for_display(Gdk.Display.get_default(), provider,
                                                  Gtk.STYLE_PROVIDER_PRIORITY_USER)
        win = Gtk.ApplicationWindow(application=app, title=T("osd.title"))
        win.add_css_class("vivac")
        win.set_decorated(False)
        win.set_resizable(False)
        win.set_focusable(False)
        win.set_default_size(380, 72)
        frame = Gtk.Box(spacing=14, valign=Gtk.Align.FILL)
        frame.add_css_class("osd")
        frame.set_size_request(380, 72)
        badge = Gtk.CenterBox(valign=Gtk.Align.CENTER)
        badge.add_css_class("osd-badge")
        g = Gtk.Label()
        g.add_css_class("osd-glyph")
        badge.set_center_widget(g)
        col = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=6, valign=Gtk.Align.CENTER, hexpand=True)
        name = Gtk.Label(xalign=0, ellipsize=3)
        name.add_css_class("osd-name")
        meter = drawn.Level(ticks=TICKS, height=14)
        col.append(name)
        col.append(meter)
        pct = Gtk.Label(xalign=1, valign=Gtk.Align.CENTER)
        pct.add_css_class("osd-pct")
        for w in (badge, col, pct):
            frame.append(w)
        win.set_child(frame)
        win.connect("close-request", lambda *_: (ui.pop("win", None), False)[1])
        ui.update(win=win, frame=frame, glyph=g, level=meter, name=name, pct=pct)

    app.connect("command-line", command_line)
    return app.run(["vivac-osd", "show", str(level.percent), "1" if level.muted else "0"])


def main(*args: str) -> int:
    """vivac-panel osd volume [up|down|mute]"""
    if not args or args[0] != "volume" or len(args) > 2 or (len(args) == 2 and args[1] not in ACTIONS):
        import sys

        print("usage: vivac-panel osd volume [up|down|mute]", file=sys.stderr)
        return 2
    level = change(args[1]) if len(args) == 2 else read()
    if level is None:
        return 1
    return show(level)
