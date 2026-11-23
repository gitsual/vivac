"""vivac-panel theme: the theme grid of the common design (Comun-Tema).

It replaces the rofi list of vivac-theme with a GTK 4 grid: one card per
palette with a mini desktop painted from the palette's own tokens (no
pictures), five real colours and the worn theme marked. The catalogue is
read from lib/themes.sh and the palettes from data/, never copied here. The
last card makes a palette from a picture (vivac-theme from-image).
"""
from __future__ import annotations

import re
import subprocess
from dataclasses import dataclass
from pathlib import Path

from .kit import T, read_kv, repo_root, settings, theme_file

COLUMNS = 4
# The five swatches, in the order of the design: accent, ok, info, urgent, text.
SWATCH_KEYS = (("COLOR_ACCENT", "C0A060"), ("COLOR_OK", "50A080"), ("COLOR_INFO", "5090C0"),
               ("COLOR_URGENT", "C05050"), ("COLOR_FG", "E0E0E0"))


@dataclass
class Theme:
    name: str
    title: str
    essence: str
    colours: list[str]
    tokens: dict[str, str]


def _colour(raw: dict[str, str], key: str, fallback: str) -> str:
    value = raw.get(key, "")
    return "#" + (value if re.fullmatch(r"[0-9A-Fa-f]{6}", value) else fallback).upper()


def catalogue_names() -> list[str]:
    root = repo_root()
    script = f"source '{root}/lib/kv.sh'; source '{root}/lib/themes.sh'; theme_catalogue '{root}'"
    try:
        out = subprocess.run(["bash", "-c", script], capture_output=True, text=True, timeout=10).stdout
    except (OSError, subprocess.SubprocessError):
        return []
    return [line for line in out.splitlines() if line]


def _header(path: Path, tag: str) -> str:
    try:
        for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
            if line.startswith(f"# @{tag}: "):
                return line.split(": ", 1)[1].strip()
    except OSError:
        pass
    return ""


def themes() -> list[Theme]:
    out = []
    for name in catalogue_names():
        path = theme_file(name)
        if path is None:
            continue
        raw = read_kv(path)
        tokens = {
            "bg": _colour(raw, "COLOR_BG", "1E1E2E"), "surface": _colour(raw, "COLOR_SURFACE", "2A2A3A"),
            "surfaceAlt": _colour(raw, "COLOR_SURFACE_ALT", "3A3A4A"), "accent": _colour(raw, "COLOR_ACCENT", "C0A060"),
            "ok": _colour(raw, "COLOR_OK", "50A080"), "urgent": _colour(raw, "COLOR_URGENT", "C05050"),
            "muted": _colour(raw, "COLOR_MUTED", "888888"),
        }
        out.append(Theme(name, _header(path, "title") or name, _header(path, "essence"),
                         [_colour(raw, k, d) for k, d in SWATCH_KEYS], tokens))
    return out


def current() -> str:
    return settings().get("theme", "bad-romance")


def apply_command(name: str) -> list[str]:
    return [str(repo_root() / "scripts" / "apply-theme.sh"), "--theme", name]


def _theme_tool() -> str:
    return str(Path.home() / ".local" / "bin" / "vivac-theme")


def picture_command(image: str) -> list[str]:
    return [_theme_tool(), "from-image", image, "--apply"]


def step(index: int, delta: int, count: int) -> int:
    return max(0, min(count - 1, index + delta))


def pictures_dir() -> Path:
    try:
        out = subprocess.run(["xdg-user-dir", "PICTURES"], capture_output=True, text=True, timeout=3).stdout.strip()
    except (OSError, subprocess.SubprocessError):
        out = ""
    return Path(out) if out and Path(out) != Path.home() else Path.home() / "Pictures"


def extra_css(p: dict[str, str]) -> str:
    return f"""
.vivac .tcard {{ background: {p['surface']}; border-radius: 12px; border: none; box-shadow: none; padding: 8px; color: {p['text']}; }}
.vivac .tcard:hover {{ background: {p['surfaceAlt']}; }}
.vivac .tcard.sel {{ box-shadow: 0 0 0 2px {p['bg']}, 0 0 0 4px {p['focusRing']}; }}
.vivac .tcard.worn {{ box-shadow: inset 0 0 0 2px {p['accent']}; }}
.vivac .tcard.worn.sel {{ box-shadow: inset 0 0 0 2px {p['accent']}, 0 0 0 2px {p['bg']}, 0 0 0 4px {p['focusRing']}; }}
.vivac .tname {{ font-size: 13px; font-weight: 700; }}
.vivac .tessence {{ font-size: 11px; color: {p['textSecondary']}; }}
.vivac .tuse {{ font-size: 11px; color: {p['accent']}; }}
.vivac .picture {{ background: {p['surface']}; border-radius: 12px; padding: 10px 12px; border: none; box-shadow: none; }}
.vivac .picture:hover {{ background: {p['surfaceAlt']}; }}
.vivac .picture.sel {{ box-shadow: 0 0 0 2px {p['bg']}, 0 0 0 4px {p['focusRing']}; }}
"""


def main() -> int:
    from .draw import rgb
    from .gfx import helpers
    from .kit import gtk_kit, palette

    k = gtk_kit()
    Gtk, Gdk, GLib = k.Gtk, k.Gdk, k.GLib
    p = palette()
    g = helpers(Gtk, p)
    items = themes()
    worn = current()
    picture_index = len(items)  # the extra card after the last theme
    start = next((i for i, t in enumerate(items) if t.name == worn), 0)
    state = {"sel": start}
    cards: list = []
    current_title = next((t.title for t in items if t.name == worn), worn)
    current_essence = next((t.essence for t in items if t.name == worn), "")

    panel = k.Panel("theme", "\U000F03D8", T("theme.panel.title"),
                    T("theme.panel.subtitle", current_title, current_essence),
                    [("←↑↓→", T("theme.hint.move")), ("⏎", T("theme.hint.apply")),
                     ("I", T("theme.hint.picture")), ("Esc", T("theme.hint.close"))], width=900)
    panel.centred = True

    def preview(theme: Theme):
        area = Gtk.DrawingArea()
        area.set_content_width(190)
        area.set_content_height(100)

        def draw(_a, cr, w, h):
            t = theme.tokens
            g.rounded(cr, 0, 0, w, h, 8)
            cr.clip()
            cr.set_source_rgba(*rgb(t["bg"]))
            cr.paint()
            cr.set_source_rgba(*rgb(t["accent"]))  # the bar's line
            cr.rectangle(8, 8, w - 16, 3)
            cr.fill()
            cr.set_source_rgba(*rgb(t["urgent"]))  # the moon
            cr.arc(w * 0.74, h * 0.42, 15, 0, 6.2832)
            cr.fill()
            for colour, base, peak in ((t["surfaceAlt"], 0.72, 0.38), (t["surface"], 0.9, 0.62)):
                cr.set_source_rgba(*rgb(colour))
                cr.move_to(0, h)
                cr.line_to(0, h * base)
                cr.line_to(w * 0.28, h * peak)
                cr.line_to(w * 0.55, h * (base - 0.02))
                cr.line_to(w * 0.78, h * (peak + 0.08))
                cr.line_to(w, h * base)
                cr.line_to(w, h)
                cr.close_path()
                cr.fill()
        area.set_draw_func(draw)
        return area

    def swatches(theme: Theme):
        box = Gtk.Box(spacing=6)
        for c in theme.colours:
            dot = Gtk.DrawingArea()
            dot.set_content_width(14)
            dot.set_content_height(14)
            dot.set_draw_func(lambda _a, cr, w, h, c=c: (cr.set_source_rgba(*rgb(c)), cr.arc(w / 2, h / 2, 7, 0, 6.2832), cr.fill()))
            box.append(dot)
        return box

    def paint():
        for i, card in enumerate(cards):
            (card.add_css_class if i == state["sel"] else card.remove_css_class)("sel")

    def activate(i: int):
        if i == picture_index:
            choose_picture()
            return
        if items[i].name != worn:
            subprocess.Popen(apply_command(items[i].name), start_new_session=True,
                             stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        panel.window.close()

    def choose_picture():
        panel.close_on_blur = False
        dialog = Gtk.FileDialog(title=T("theme.panel.pick_title"))
        flt = Gtk.FileFilter()
        flt.set_name("PNG, JPEG")
        for mime in ("image/png", "image/jpeg"):
            flt.add_mime_type(mime)
        store = Gio_list(flt)
        dialog.set_filters(store)
        folder = pictures_dir()
        if folder.is_dir():
            dialog.set_initial_folder(Gio_file(str(folder)))

        def done(d, res):
            try:
                f = d.open_finish(res)
            except GLib.Error:
                return
            subprocess.Popen(picture_command(f.get_path()), start_new_session=True,
                             stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            panel.window.close()
        dialog.open(panel.window, None, done)

    def Gio_list(flt):
        from gi.repository import Gio
        store = Gio.ListStore.new(Gtk.FileFilter)
        store.append(flt)
        return store

    def Gio_file(path):
        from gi.repository import Gio
        return Gio.File.new_for_path(path)

    def build(_panel):
        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL)
        panel.header_end.append(k.badge(T("theme.panel.count", len(items))))
        grid = Gtk.Grid(column_spacing=8, row_spacing=8, column_homogeneous=True)
        grid.set_margin_top(16)
        for i, th in enumerate(items):
            btn = Gtk.Button()
            btn.add_css_class("tcard")
            if th.name == worn:
                btn.add_css_class("worn")
            col = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=4)
            col.append(preview(th))
            name = Gtk.Label(label=th.title, xalign=0)
            name.add_css_class("tname")
            col.append(name)
            row = Gtk.Box()
            ess = Gtk.Label(label=th.essence, xalign=0, hexpand=True)
            ess.add_css_class("tessence")
            row.append(ess)
            if th.name == worn:
                use = Gtk.Label(label="\U000F04CE " + T("theme.panel.current"))
                use.add_css_class("tuse")
                row.append(use)
            col.append(row)
            col.append(swatches(th))
            btn.set_child(col)
            btn.set_focusable(False)
            btn.connect("clicked", lambda _b, i=i: (state.__setitem__("sel", i), activate(i)))
            cards.append(btn)
            grid.attach(btn, i % COLUMNS, i // COLUMNS, 1, 1)
        box.append(grid)
        pic = Gtk.Button()
        pic.add_css_class("picture")
        pic.set_margin_top(12)
        inner = k.row("\U000F02E9", T("theme.panel.picture"), T("theme.panel.picture_sub"), end=_key(Gtk, "I"))
        pic.set_child(inner)
        pic.set_focusable(False)
        pic.connect("clicked", lambda _b: activate(picture_index))
        cards.append(pic)
        box.append(pic)
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
        n = len(cards)
        moves = {Gdk.KEY_Left: -1, Gdk.KEY_Right: 1, Gdk.KEY_Up: -COLUMNS, Gdk.KEY_Down: COLUMNS}
        if keyval in moves:
            sel, delta = state["sel"], moves[keyval]
            if sel == picture_index and delta == -COLUMNS:
                state["sel"] = max(0, len(items) - COLUMNS)  # back up into the grid
            elif sel + delta >= len(items) and delta > 0 and sel < picture_index:
                state["sel"] = picture_index if delta == COLUMNS else sel
            else:
                state["sel"] = step(sel, delta, len(items)) if sel < picture_index else sel
            paint()
            return True
        if keyval in (Gdk.KEY_Return, Gdk.KEY_KP_Enter):
            activate(state["sel"])
            return True
        if keyval in (Gdk.KEY_i, Gdk.KEY_I):
            activate(picture_index)
            return True
        return False

    provider = Gtk.CssProvider()
    provider.load_from_string(extra_css(p))
    Gtk.StyleContext.add_provider_for_display(Gdk.Display.get_default(), provider,
                                              Gtk.STYLE_PROVIDER_PRIORITY_USER)
    panel.on_build = build
    return panel.run()


def _key(Gtk, text: str):
    lab = Gtk.Label(label=text)
    lab.add_css_class("key")
    return lab
