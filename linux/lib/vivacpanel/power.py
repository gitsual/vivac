"""vivac-panel power: the session menu of the common design (Comun-Energia).

Six tiles with a number key (lock, log out, suspend, reboot, power off,
restart in Windows); what ends the session asks a second time, in a red bar
under the grid, instead of acting on the first touch. It replaces nwg-bar,
which draws the same icons but cannot ask for confirmation. The commands are
literals here: a translation changes what a tile says, never what it does.
"""
from __future__ import annotations

import subprocess
from dataclasses import dataclass
from pathlib import Path

from .kit import T

GLYPH = {"lock": "\U000F033E", "logout": "\U000F0343", "suspend": "\U000F04B2",
         "reboot": "\U000F0709", "poweroff": "\U000F0425", "windows": "\U000F05B3"}
LABEL = {"lock": "power.lock", "logout": "power.logout", "suspend": "power.suspend",
         "reboot": "power.reboot", "poweroff": "power.poweroff", "windows": "power.go_windows"}
CONFIRM = {"reboot": "power.confirm.reboot", "poweroff": "power.confirm.poweroff",
           "windows": "power.confirm.windows"}
DESTRUCTIVE = ("reboot", "poweroff")
COLUMNS = 3


@dataclass
class Entry:
    key: str
    label: str
    glyph: str
    destructive: bool


def _home() -> Path:
    return Path.home()


def windows_available() -> bool:
    tool = _home() / ".local" / "bin" / "vivac-reboot-other"
    try:
        return subprocess.run([str(tool), "--available"], capture_output=True, timeout=5).returncode == 0
    except (OSError, subprocess.SubprocessError):
        return False


def entries() -> list[Entry]:
    keys = ["lock", "logout", "suspend", "reboot", "poweroff"]
    if windows_available():
        keys.append("windows")
    return [Entry(k, T(LABEL[k]), GLYPH[k], k in DESTRUCTIVE) for k in keys]


def command(key: str) -> list[str]:
    return {
        "lock": ["hyprlock"],
        "logout": [str(_home() / ".config" / "hypr" / "scripts" / "dispatch.sh"), "exit"],
        "suspend": ["systemctl", "suspend"],
        "reboot": ["systemctl", "reboot"],
        "poweroff": ["systemctl", "poweroff"],
        "windows": [str(_home() / ".local" / "bin" / "vivac-reboot-other")],
    }[key]


def confirm_text(key: str) -> str:
    return T(CONFIRM.get(key, "power.confirm.poweroff"))


def step(index: int, delta: int, count: int) -> int:
    """Where a move of delta lands: stays on the grid, never wraps."""
    return max(0, min(count - 1, index + delta))


def needs_confirmation(key: str) -> bool:
    return key in DESTRUCTIVE or key == "windows"


def run(key: str) -> None:
    subprocess.Popen(command(key), start_new_session=True,
                     stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def extra_css(p: dict[str, str]) -> str:
    return f"""
.vivac .ptile {{ background: {p['surface']}; border-radius: 12px; border: none; box-shadow: none;
  min-height: 130px; padding: 0; color: {p['text']}; }}
.vivac .ptile:hover {{ background: {p['surfaceAlt']}; }}
.vivac .ptile.sel {{ background: {p['surfaceAlt']}; box-shadow: 0 0 0 2px {p['bg']}, 0 0 0 4px {p['focusRing']}; }}
.vivac .ptile .pglyph {{ font-size: 34px; color: {p['accent']}; }}
.vivac .ptile.danger .pglyph {{ color: {p['alert']}; }}
.vivac .ptile .pname {{ font-size: 14px; font-weight: 700; }}
.vivac .ptile .pbar {{ background: {p['alert']}; border-radius: 2px; min-height: 4px; margin: 0 18px 8px 18px; }}
.vivac .confirm {{ background: alpha({p['alert']}, 0.18); border-radius: 10px; padding: 10px 14px;
  box-shadow: inset 0 0 0 1px {p['alert']}; margin-top: 12px; }}
.vivac .confirm .ctext {{ font-size: 14px; font-weight: 700; color: {p['alert']}; }}
"""


def main() -> int:
    from .kit import gtk_kit, palette

    k = gtk_kit()
    Gtk, Gdk, GLib = k.Gtk, k.Gdk, k.GLib
    items = entries()
    state = {"sel": 3 if len(items) > 3 else 0, "pending": None}
    tiles: list = []

    panel = k.Panel("power", "\U000F0425", T("power.title"), T("power.subtitle"),
                    [("1-%d" % len(items), T("power.hint.choose")), ("←→", T("power.hint.move")),
                     ("⏎", T("power.hint.activate")), ("Esc", T("power.hint.close"))], width=560)
    panel.centred = True

    def paint() -> None:
        for i, tile in enumerate(tiles):
            (tile.add_css_class if i == state["sel"] else tile.remove_css_class)("sel")
        pending = state["pending"]
        confirm.set_visible(pending is not None)
        if pending is not None:
            ctext.set_label(confirm_text(pending))

    def act(i: int) -> None:
        state["sel"] = i
        key = items[i].key
        if needs_confirmation(key) and state["pending"] != key:
            state["pending"] = key
            paint()
            return
        run(key)
        panel.window.close()

    def build(_panel):
        nonlocal confirm, ctext
        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL)
        grid = Gtk.Grid(column_spacing=8, row_spacing=8, column_homogeneous=True)
        grid.set_margin_top(16)
        for i, e in enumerate(items):
            btn = Gtk.Button()
            btn.add_css_class("ptile")
            if e.destructive:
                btn.add_css_class("danger")
            col = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=6, valign=Gtk.Align.CENTER)
            g = Gtk.Label(label=e.glyph)
            g.add_css_class("pglyph")
            n = Gtk.Label(label=e.label)
            n.add_css_class("pname")
            col.append(g)
            col.append(n)
            kb = _key(Gtk, str(i + 1))
            kb.set_halign(Gtk.Align.CENTER)
            col.append(kb)
            if e.destructive:
                bar = Gtk.Box()
                bar.add_css_class("pbar")
                col.append(bar)
            btn.set_child(col)
            btn.connect("clicked", lambda _b, i=i: act(i))
            btn.set_focusable(False)
            tiles.append(btn)
            grid.attach(btn, i % COLUMNS, i // COLUMNS, 1, 1)
        box.append(grid)
        confirm = Gtk.Box(spacing=10)
        confirm.add_css_class("confirm")
        confirm.append(Gtk.Label(label="\U000F0026"))
        ctext = Gtk.Label(xalign=0, hexpand=True)
        ctext.add_css_class("ctext")
        confirm.append(ctext)
        confirm.append(_key(Gtk, "⏎"))
        confirm.append(Gtk.Label(label=T("power.confirm_yes")))
        confirm.append(_key(Gtk, "Esc"))
        confirm.append(Gtk.Label(label=T("power.confirm_no")))
        confirm.set_visible(False)
        box.append(confirm)
        paint()
        GLib.idle_add(attach)
        return box

    def attach():
        keys = Gtk.EventControllerKey()
        keys.set_propagation_phase(Gtk.PropagationPhase.CAPTURE)
        keys.connect("key-pressed", on_key)
        panel.window.add_controller(keys)
        return False

    def on_key(_c, keyval, _code, _mods):
        if keyval == Gdk.KEY_Escape and state["pending"] is not None:
            state["pending"] = None
            paint()
            return True
        if Gdk.KEY_1 <= keyval <= Gdk.KEY_9 and keyval - Gdk.KEY_1 < len(items):
            act(keyval - Gdk.KEY_1)
            return True
        moves = {Gdk.KEY_Left: -1, Gdk.KEY_Right: 1, Gdk.KEY_Up: -COLUMNS, Gdk.KEY_Down: COLUMNS}
        if keyval in moves:
            state["pending"] = None
            state["sel"] = step(state["sel"], moves[keyval], len(items))
            paint()
            return True
        if keyval in (Gdk.KEY_Return, Gdk.KEY_KP_Enter):
            act(state["sel"])
            return True
        return False

    confirm = ctext = None
    provider = Gtk.CssProvider()
    provider.load_from_string(extra_css(palette()))
    Gtk.StyleContext.add_provider_for_display(Gdk.Display.get_default(), provider,
                                              Gtk.STYLE_PROVIDER_PRIORITY_USER)
    panel.on_build = build
    return panel.run()


def _key(Gtk, text: str):
    lab = Gtk.Label(label=text)
    lab.add_css_class("key")
    return lab
