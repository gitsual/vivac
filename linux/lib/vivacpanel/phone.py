"""vivac-panel phone: the phone through KDE Connect, as a panel of the common
design, where the bar's phone button used to open a rofi menu.

What it shows and does comes from vivac-phone and nothing else: `status`
(the phones in reach and their battery, what this machine can do besides)
and `do ACTION --device ID` (ring, send a file, the clipboard or the link on
it, browse the phone's files), so the bar, this panel and the bridge menu
act the same. Buttons with a number key, as the power panel has them; the
outcome is said in a line under them, the panel stays open.
"""
from __future__ import annotations

import json
import re
import subprocess
from dataclasses import dataclass
from pathlib import Path

from .kit import T

GLYPH = {"phone": "\U000F011C", "ring": "\U000F009A", "send-file": "\U000F0552", "send-clip": "\U000F014C",
         "send-url": "\U000F0337", "browse": "\U000F024B", "screen": "\U000F0379", "manage": "\U000F0493"}
LABEL = {"ring": "phone.panel.ring", "send-file": "phone.panel.send_file", "send-clip": "phone.panel.send_clip",
         "send-url": "phone.panel.send_url", "browse": "phone.panel.browse", "screen": "phone.panel.screen",
         "manage": "phone.panel.manage"}
COLUMNS = 3
LINK = re.compile(r"^https?://\S+$")


@dataclass
class Tile:
    key: str
    label: str
    glyph: str
    enabled: bool


def tool() -> str:
    return str(Path.home() / ".local" / "bin" / "vivac-phone")


def load_status(path: str | None = None) -> dict:
    """`vivac-phone status`, or the empty view when it does not answer."""
    empty = {"installed": False, "daemon": False, "phones": [], "can_browse": False, "can_screen": False}
    try:
        out = subprocess.run([path or tool(), "status"], capture_output=True, text=True, timeout=15).stdout
        data = json.loads(out)
        return data if isinstance(data, dict) else empty
    except (OSError, subprocess.SubprocessError, ValueError):
        return empty


def first_phone(st: dict) -> dict | None:
    phones = st.get("phones") or []
    return phones[0] if phones else None


def subtitle(st: dict) -> str:
    if not st.get("installed"):
        return T("phone.not_installed")
    p = first_phone(st)
    if p is None:
        return T("phone.none")
    parts = [p["name"]]
    if isinstance(p.get("charge"), int) and p["charge"] >= 0:
        parts.append(f"{p['charge']} %")
        if p.get("charging"):
            parts.append(T("phone.panel.charging"))
    return " · ".join(parts)


def is_link(text: str) -> bool:
    return bool(LINK.match(text or ""))


def tiles(st: dict, has_link: bool) -> list[Tile]:
    """The buttons, in order: what a phone in reach allows, then pairing,
    which is always there (it is also the way in when no phone is)."""
    keys: list[str] = []
    if st.get("installed") and first_phone(st) is not None:
        keys += ["ring", "send-file", "send-clip", "send-url"]
        if st.get("can_browse"):
            keys.append("browse")
        if st.get("can_screen"):
            keys.append("screen")
    keys.append("manage")
    return [Tile(k, T(LABEL[k]), GLYPH[k], k != "send-url" or has_link) for k in keys]


def command(key: str, device: str, file: str = "", tool: str | None = None) -> list[str]:
    path = tool or globals()["tool"]()
    if key == "screen":
        return [path, "run", "phone-screen"]
    line = [path, "do", key, "--device", device]
    return line + [file] if file else line


def clipboard_text() -> str:
    try:
        return subprocess.run(["wl-paste", "--no-newline", "--type", "text"], capture_output=True,
                              text=True, timeout=2).stdout
    except (OSError, subprocess.SubprocessError):
        return ""


def extra_css(p: dict[str, str]) -> str:
    return f"""
.vivac .ptile {{ background: {p['surface']}; border-radius: 12px; border: none; box-shadow: none;
  min-height: 104px; padding: 0; color: {p['text']}; }}
.vivac .ptile:hover {{ background: {p['surfaceAlt']}; }}
.vivac .ptile:disabled {{ opacity: 0.38; }}
.vivac .ptile.sel {{ background: {p['surfaceAlt']}; box-shadow: 0 0 0 2px {p['bg']}, 0 0 0 4px {p['focusRing']}; }}
.vivac .ptile .pglyph {{ font-size: 28px; color: {p['accent']}; }}
.vivac .ptile .pname {{ font-size: 13px; font-weight: 700; }}
.vivac .outcome {{ font-size: 13px; color: {p['textSecondary']}; margin-top: 10px; }}
.vivac .outcome.ok {{ color: {p['success']}; }}
.vivac .outcome.bad {{ color: {p['alert']}; }}
"""


def main() -> int:
    from .kit import gtk_kit, palette

    k = gtk_kit()
    Gtk, Gdk, GLib = k.Gtk, k.Gdk, k.GLib
    st = load_status()
    items = tiles(st, is_link(clipboard_text()))
    phone = first_phone(st)
    state = {"sel": 0}
    buttons: list = []
    outcome = None

    panel = k.Panel("phone", GLYPH["phone"], T("phone.title"), subtitle(st),
                    [("1-%d" % len(items), T("power.hint.choose")), ("←→", T("power.hint.move")),
                     ("⏎", T("power.hint.activate")), ("Esc", T("power.hint.close"))], width=460)

    def say(text: str, ok: bool) -> None:
        outcome.set_label(text.strip())
        outcome.remove_css_class("ok" if not ok else "bad")
        outcome.add_css_class("ok" if ok else "bad")
        outcome.set_visible(bool(text.strip()))

    def paint() -> None:
        for i, b in enumerate(buttons):
            (b.add_css_class if i == state["sel"] else b.remove_css_class)("sel")

    def run_line(line: list[str]) -> None:
        def done(proc):
            out, _ = proc.communicate()
            GLib.idle_add(lambda: (say(out or "", proc.returncode == 0), False)[1])
        try:
            proc = subprocess.Popen(line, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True,
                                    start_new_session=True)
        except OSError as error:
            say(str(error), False)
            return
        import threading
        threading.Thread(target=done, args=(proc,), daemon=True).start()

    def act(i: int) -> None:
        if not items[i].enabled:
            return
        state["sel"] = i
        paint()
        key = items[i].key
        if key == "manage":
            subprocess.Popen(["kdeconnect-app"], start_new_session=True, stdout=subprocess.DEVNULL,
                             stderr=subprocess.DEVNULL)
            panel.window.close()
            return
        if key == "send-file":
            dialog = Gtk.FileDialog(title=T("phone.pick_file"))

            def picked(dlg, result):
                try:
                    f = dlg.open_finish(result)
                except GLib.Error:
                    return
                if f is not None and f.get_path():
                    run_line(command("send-file", phone["id"], f.get_path()))
            dialog.open(panel.window, None, picked)
            return
        run_line(command(key, phone["id"] if phone else ""))

    def build(_panel):
        nonlocal outcome
        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL)
        if phone is not None and isinstance(phone.get("charge"), int) and phone["charge"] >= 0:
            box.append(k.section(T("phone.panel.battery")))
            line = Gtk.Box(spacing=10)
            line.append(k.meter(phone["charge"] / 100, alert=phone["charge"] <= 20 and not phone.get("charging")))
            line.append(k.badge(f"{phone['charge']} %", "ok" if phone.get("charging") else ""))
            box.append(line)
        grid = Gtk.Grid(column_spacing=8, row_spacing=8, column_homogeneous=True)
        grid.set_margin_top(14)
        for i, item in enumerate(items):
            btn = Gtk.Button()
            btn.add_css_class("ptile")
            col = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=6, valign=Gtk.Align.CENTER)
            g = Gtk.Label(label=item.glyph)
            g.add_css_class("pglyph")
            n = Gtk.Label(label=item.label, wrap=True, justify=2, max_width_chars=14)
            n.add_css_class("pname")
            col.append(g)
            col.append(n)
            kb = Gtk.Label(label=str(i + 1))
            kb.add_css_class("key")
            kb.set_halign(Gtk.Align.CENTER)
            col.append(kb)
            btn.set_child(col)
            btn.set_sensitive(item.enabled)
            if item.key == "send-url" and not item.enabled:
                btn.set_tooltip_text(T("phone.no_link"))
            btn.connect("clicked", lambda _b, i=i: act(i))
            btn.set_focusable(False)
            buttons.append(btn)
            grid.attach(btn, i % COLUMNS, i // COLUMNS, 1, 1)
        box.append(grid)
        outcome = Gtk.Label(xalign=0, wrap=True)
        outcome.add_css_class("outcome")
        outcome.set_visible(False)
        box.append(outcome)
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
        if Gdk.KEY_1 <= keyval <= Gdk.KEY_9 and keyval - Gdk.KEY_1 < len(items):
            act(keyval - Gdk.KEY_1)
            return True
        moves = {Gdk.KEY_Left: -1, Gdk.KEY_Right: 1, Gdk.KEY_Up: -COLUMNS, Gdk.KEY_Down: COLUMNS}
        if keyval in moves:
            state["sel"] = max(0, min(len(items) - 1, state["sel"] + moves[keyval]))
            paint()
            return True
        if keyval in (Gdk.KEY_Return, Gdk.KEY_KP_Enter):
            act(state["sel"])
            return True
        return False

    provider = Gtk.CssProvider()
    provider.load_from_string(extra_css(palette()))
    Gtk.StyleContext.add_provider_for_display(Gdk.Display.get_default(), provider, Gtk.STYLE_PROVIDER_PRIORITY_USER)
    panel.on_build = build
    return panel.run()
