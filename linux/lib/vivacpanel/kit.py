"""The panel kit: what every vivac panel on Linux shares.

The Windows side draws its panels with WPF (windows/lib/Surfaces.psm1,
Get-KitPanelXaml and New-KitRow); this is the same kit in GTK 4, so a panel
reads the same on both: a header with a glyph, a title and one line of
context, a body of rows, and a footer of keycaps saying what the keys do.

The pure half (settings, language, palette) imports nothing graphical, so the
bar's one-line JSON helpers and the tests can use it without a display. GTK
is imported only by gtk_kit().
"""
from __future__ import annotations

import os
import re
from pathlib import Path

SELF = Path(__file__).resolve()


def repo_root() -> Path:
    """linux/ of the checkout: this file is linux/lib/vivacpanel/kit.py."""
    return Path(os.environ.get("VIVAC_REPO") or SELF.parents[2])


def config_home() -> Path:
    return Path(os.environ.get("XDG_CONFIG_HOME") or Path.home() / ".config")


def runtime_dir() -> Path:
    return Path(os.environ.get("XDG_RUNTIME_DIR") or f"/tmp/vivac-{os.getuid()}")


def read_kv(path: Path) -> dict[str, str]:
    """A flat KEY=value file read as data (lib/kv.sh): comments, blank and
    malformed lines skipped, CR dropped, %XX decoded. Never raises."""
    values: dict[str, str] = {}
    try:
        text = path.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return values
    for line in text.lstrip("﻿").splitlines():
        line = line.rstrip("\r")
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, _, value = line.partition("=")
        if re.fullmatch(r"[A-Za-z_][A-Za-z0-9_.]*", key):
            values[key] = re.sub(r"%([0-9A-Fa-f]{2})", lambda m: chr(int(m.group(1), 16)), value)
    return values


def settings() -> dict[str, str]:
    return read_kv(Path(os.environ.get("SETTINGS_FILE") or config_home() / "vivac" / "settings"))


def session_language(values: dict[str, str]) -> str:
    """VIVAC_LANG, then the language setting unless auto, then LANG, then English."""
    short = re.compile(r"[a-z]{2,3}")
    wanted = os.environ.get("VIVAC_LANG")
    if wanted:
        candidate = re.split(r"[._@]", wanted)[0]
        return candidate if short.fullmatch(candidate) else "en"
    for candidate in (values.get("language", ""), os.environ.get("LANG", "")):
        if candidate == "auto":
            continue
        candidate = re.split(r"[._@]", candidate)[0]
        if short.fullmatch(candidate):
            return candidate
    return "en"


class Text:
    """i18n/<lang>.conf over i18n/en.conf, as lib/i18n.sh reads them. A key
    only English has is marked [en]; {1}, {2}... are replaced as plain text."""

    def __init__(self, language: str) -> None:
        directory = Path(os.environ.get("I18N_DIR") or repo_root() / "i18n")
        self.reference = read_kv(directory / "en.conf")
        self.table = read_kv(directory / f"{language}.conf") if language != "en" else {}

    def __call__(self, key: str, *args: object) -> str:
        if key in self.table:
            text = self.table[key]
        elif key in self.reference:
            text = self.reference[key] if not self.table else "[en] " + self.reference[key]
        else:
            return f"[{key}]"
        for index, arg in enumerate(args, 1):
            text = text.replace("{%d}" % index, str(arg))
        return text


THEMES_DEFAULT = "bad-romance"  # lib/themes.sh
PANEL_TOP = 48  # where Hyprland's vivac-panel rule puts a panel's top edge


def theme_file(name: str) -> Path | None:
    """The palette a theme name resolves to (lib/themes.sh theme_file_for)."""
    root = repo_root()
    if name == THEMES_DEFAULT:
        return root / "data" / "theme.conf"
    if not re.fullmatch(r"[a-z][a-z0-9-]*", name or ""):
        return None
    shipped = root / "data" / "themes" / f"{name}.conf"
    if shipped.is_file():
        return shipped
    data_home = Path(os.environ.get("XDG_DATA_HOME") or Path.home() / ".local" / "share")
    for directory in (config_home() / "vivac" / "themes", data_home / "vivac" / "themes"):
        candidate = directory / f"{name}.conf"
        if candidate.is_file():
            return candidate
    return None


def palette(values: dict[str, str] | None = None) -> dict[str, str]:
    """The worn theme as the tokens the panels use (the same names as the
    design canvas): bg, surface, surfaceAlt, accent, text, textSecondary,
    line, actionFill, actionText, focusRing, alert, info, success."""
    values = settings() if values is None else values
    path = theme_file(values.get("theme", THEMES_DEFAULT)) or repo_root() / "data" / "theme.conf"
    raw = read_kv(path)

    def colour(key: str, fallback: str) -> str:
        value = raw.get(key, "")
        return "#" + (value if re.fullmatch(r"[0-9A-Fa-f]{6}", value) else fallback)

    p = {
        "bg": colour("COLOR_BG", "1E1E2E"),
        "surface": colour("COLOR_SURFACE", "2A2A3A"),
        "surfaceAlt": colour("COLOR_SURFACE_ALT", "3A3A4A"),
        "accent": colour("COLOR_ACCENT", "C0A060"),
        "text": colour("COLOR_FG", "E0E0E0"),
        "textSecondary": colour("COLOR_FG_DIM", "B0B0B0"),
        "line": colour("COLOR_BORDER_INACTIVE", "444444"),
        "alert": colour("COLOR_URGENT", "C05050"),
        "info": colour("COLOR_INFO", "5090C0"),
        "success": colour("COLOR_OK", "50A080"),
        "muted": colour("COLOR_MUTED", "888888"),
    }
    p["actionFill"] = p["accent"]
    p["actionText"] = p["bg"]
    p["focusRing"] = mix(p["accent"], "#FFFFFF", 0.25)
    return p


def mix(a: str, b: str, t: float) -> str:
    """a moved t of the way to b, both #RRGGBB."""
    ca = [int(a[i:i + 2], 16) for i in (1, 3, 5)]
    cb = [int(b[i:i + 2], 16) for i in (1, 3, 5)]
    return "#" + "".join(f"{round(x + (y - x) * t):02X}" for x, y in zip(ca, cb))


def css(p: dict[str, str]) -> str:
    """One stylesheet for every panel: radii 14 panel / 10 control / 8 row,
    spacing on 4/8/12/16/24, selection as actionFill with a focus ring."""
    return f"""
window.vivac {{ background: transparent; }}
.vivac * {{ font-family: "JetBrainsMono Nerd Font Propo", "JetBrains Mono", monospace; }}
.vivac .panel {{ background: {p['bg']}; color: {p['text']}; border-radius: 14px;
  box-shadow: inset 0 0 0 2px {p['accent']}; padding: 16px 16px 12px 16px; }}
.vivac .head-glyph {{ font-size: 22px; color: {p['accent']}; min-width: 36px; min-height: 36px;
  border-radius: 10px; background: {p['surface']}; }}
.vivac .title {{ font-size: 15px; font-weight: 700; color: {p['text']}; }}
.vivac .subtitle {{ font-size: 12px; color: {p['textSecondary']}; }}
.vivac .section {{ font-size: 11px; font-weight: 700; color: {p['accent']}; letter-spacing: 1px;
  margin: 12px 4px 4px 4px; }}
.vivac .count {{ font-size: 11px; color: {p['textSecondary']}; background: {p['surface']};
  border-radius: 8px; padding: 0 6px; }}
.vivac .block {{ background: {p['surface']}; border-radius: 10px; padding: 4px; }}
.vivac .row {{ border-radius: 8px; padding: 6px 8px; min-height: 32px; background: transparent;
  color: {p['text']}; border: none; box-shadow: none; }}
.vivac .row:hover {{ background: {p['surfaceAlt']}; }}
.vivac .row:focus-visible {{ box-shadow: 0 0 0 2px {p['bg']}, 0 0 0 4px {p['focusRing']}; }}
.vivac .row.selected {{ background: {p['actionFill']}; color: {p['actionText']}; }}
.vivac .row.selected .sub, .vivac .row.selected .glyph {{ color: {p['actionText']}; }}
.vivac .row .name {{ font-size: 13px; }}
.vivac .row.selected .name {{ font-weight: 700; }}
.vivac .row .sub {{ font-size: 11px; color: {p['textSecondary']}; }}
.vivac .glyph {{ font-size: 18px; color: {p['accent']}; min-width: 28px; }}
.vivac .tile {{ min-width: 32px; min-height: 32px; border-radius: 8px; background: {p['surfaceAlt']}; }}
.vivac .row.selected .tile {{ background: alpha({p['actionText']}, 0.15); }}
.vivac .badge {{ font-size: 11px; font-weight: 700; border-radius: 8px; padding: 1px 6px;
  background: {p['surfaceAlt']}; color: {p['text']}; }}
.vivac .badge.ok {{ background: alpha({p['success']}, 0.25); color: {p['success']}; }}
.vivac .badge.warn {{ background: alpha({p['accent']}, 0.25); color: {p['accent']}; }}
.vivac .badge.alert {{ background: {p['alert']}; color: {p['bg']}; }}
.vivac .badge.info {{ background: alpha({p['info']}, 0.25); color: {p['info']}; }}
.vivac .muted-row {{ opacity: 0.55; }}
.vivac .empty {{ font-size: 12px; color: {p['textSecondary']}; padding: 8px 10px; }}
.vivac button.icon {{ min-width: 32px; min-height: 32px; padding: 0; border-radius: 8px; border: none;
  background: transparent; color: {p['text']}; box-shadow: none; }}
.vivac button.icon:hover {{ background: {p['surfaceAlt']}; }}
.vivac button.icon.on {{ background: {p['alert']}; color: {p['bg']}; }}
.vivac button.icon:focus-visible {{ box-shadow: 0 0 0 2px {p['bg']}, 0 0 0 4px {p['focusRing']}; }}
.vivac button.action {{ border-radius: 10px; padding: 6px 12px; border: none; box-shadow: none;
  background: {p['surfaceAlt']}; color: {p['text']}; font-size: 12px; }}
.vivac button.action:hover {{ background: {p['actionFill']}; color: {p['actionText']}; }}
.vivac button.action.primary {{ background: {p['actionFill']}; color: {p['actionText']}; font-weight: 700; }}
.vivac button.action.primary:hover {{ background: {p['focusRing']}; }}
.vivac button.action.danger:hover {{ background: {p['alert']}; color: {p['bg']}; }}
.vivac scale trough {{ min-height: 6px; border-radius: 3px; background: {p['surfaceAlt']}; }}
.vivac scale highlight {{ border-radius: 3px; background: {p['accent']}; }}
.vivac scale slider {{ min-width: 16px; min-height: 16px; border-radius: 8px; background: {p['text']};
  border: 2px solid {p['bg']}; box-shadow: none; }}
.vivac scale.muted highlight {{ background: {p['muted']}; }}
.vivac .pct {{ font-size: 12px; color: {p['textSecondary']}; min-width: 40px; }}
.vivac .hero {{ background: {p['surface']}; border-radius: 10px; padding: 12px; }}
.vivac .hero .big {{ font-size: 28px; font-weight: 700; color: {p['text']}; }}
.vivac .footer {{ margin-top: 12px; padding-top: 8px; border-top: 1px solid {p['line']}; }}
.vivac .key {{ font-size: 11px; color: {p['text']}; background: {p['surface']}; border-radius: 6px;
  padding: 1px 6px; box-shadow: inset 0 -2px {p['line']}; }}
.vivac .keylabel {{ font-size: 11px; color: {p['textSecondary']}; }}
.vivac entry.search {{ background: {p['surface']}; color: {p['text']}; border-radius: 10px; border: none;
  min-height: 40px; padding: 0 12px; box-shadow: inset 0 0 0 2px {p['focusRing']}; caret-color: {p['accent']}; }}
.vivac scrolledwindow, .vivac viewport, .vivac list, .vivac listview {{ background: transparent; }}
.vivac .bar-fill {{ background: {p['accent']}; border-radius: 3px; min-height: 6px; }}
.vivac .bar-track {{ background: {p['surfaceAlt']}; border-radius: 3px; min-height: 6px; }}
.vivac .bar-fill.alert {{ background: {p['alert']}; }}
"""


def gtk_kit():
    """Import GTK 4 and return the graphical half of the kit as a namespace.
    Kept out of module import so `vivac-panel waybar ...` never loads GTK."""
    import gi

    gi.require_version("Gtk", "4.0")
    gi.require_version("Gdk", "4.0")
    from gi.repository import Gdk, GLib, Gtk  # noqa: E402

    def available_height(Gdk) -> int:
        """The height under the bar: the monitor's, less the bar's 48 px
        (the Hyprland rule's y) and a 12 px margin at the bottom."""
        try:
            monitors = Gdk.Display.get_default().get_monitors()
            height = min(monitors.get_item(i).get_geometry().height for i in range(monitors.get_n_items()))
        except (AttributeError, ValueError, TypeError):
            height = 1080
        return max(300, height - PANEL_TOP - 12)

    class Panel:
        """A floating window, one per panel kind, class vivac-panel-<kind>
        (Hyprland floats and places it). Esc closes; so does losing focus,
        as a bar popup should; running it again while it is open closes it."""

        def __init__(self, kind: str, glyph: str, title: str, subtitle: str = "",
                     hints: list[tuple[str, str]] | None = None, width: int = 400) -> None:
            self.kind = kind
            self.p = palette()
            self.app = Gtk.Application(application_id=f"org.vivac.panel.{kind}")
            self.app.connect("activate", self._activate)
            self.glyph, self.title, self.subtitle_text = glyph, title, subtitle
            self.hints = hints or []
            self.width = width
            self.window = None
            self.on_build = None  # callable(panel) -> Gtk.Widget body
            self.close_on_blur = True
            self.centred = False  # a launcher sits in the middle of the screen, not under the bar

        def run(self) -> int:
            return self.app.run([])

        def _activate(self, app) -> None:
            if self.window is not None:  # a second launch toggles it closed
                self.window.close()
                return
            provider = Gtk.CssProvider()
            provider.load_from_string(css(self.p))
            Gtk.StyleContext.add_provider_for_display(
                Gdk.Display.get_default(), provider, Gtk.STYLE_PROVIDER_PRIORITY_USER)
            win = Gtk.ApplicationWindow(application=app, title=self.title)
            win.add_css_class("vivac")
            win.set_decorated(False)
            win.set_resizable(False)
            # Its natural width, not the panel's: a wrapping label offered the
            # whole height asks for a much wider line than it needs.
            win.set_default_size(self.width, available_height(Gdk))
            outer = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, valign=Gtk.Align.START)
            outer.add_css_class("panel")
            outer.set_size_request(self.width, -1)
            outer.append(self._header())
            self.body = self.on_build(self) if self.on_build else Gtk.Box()
            outer.append(self.body)
            if self.hints:
                outer.append(hints_bar(self.hints))
            # The window never changes size. Hyprland places a floating window
            # once and keeps its centre when the client resizes it, so a panel
            # whose content arrives late (updates, the forecast) grew upwards
            # over the bar and off the screen. The window is as tall as the
            # space under the bar, transparent, with the panel at its top: the
            # panel grows downwards inside it. A click on the empty part closes
            # it, as a click anywhere else does.
            root = Gtk.Box(orientation=Gtk.Orientation.VERTICAL)
            if self.centred:
                outer.set_valign(Gtk.Align.CENTER)
                outer.set_margin_bottom(PANEL_TOP)  # the middle of the screen, not of the space under the bar
            root.append(outer)
            root.set_size_request(-1, available_height(Gdk))
            empty = Gtk.GestureClick()
            empty.connect("pressed", lambda g, n, x, y: self._click_outside(root, outer, x, y))
            root.add_controller(empty)
            win.set_child(root)
            keys = Gtk.EventControllerKey()
            keys.connect("key-pressed", self._key)
            win.add_controller(keys)
            if self.close_on_blur:
                win.connect("notify::is-active", self._blur)
            self.window = win
            win.present()

        def _header(self):
            box = Gtk.Box(spacing=12)
            g = Gtk.Label(label=self.glyph)
            g.add_css_class("head-glyph")
            box.append(g)
            col = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, valign=Gtk.Align.CENTER)
            t = Gtk.Label(label=self.title, xalign=0)
            t.add_css_class("title")
            self.subtitle = Gtk.Label(label=self.subtitle_text, xalign=0,
                                      ellipsize=3)  # Pango.EllipsizeMode.END
            self.subtitle.add_css_class("subtitle")
            col.append(t)
            col.append(self.subtitle)
            col.set_hexpand(True)
            box.append(col)
            self.header_end = Gtk.Box(spacing=4, valign=Gtk.Align.CENTER)
            box.append(self.header_end)
            return box

        def _click_outside(self, root, outer, x, y):
            ok, px, py = root.translate_coordinates(outer, x, y)
            inside = ok and 0 <= px <= outer.get_width() and 0 <= py <= outer.get_height()
            if not inside and self.window is not None:
                self.window.close()

        def _key(self, _ctl, keyval, _code, _state):
            if keyval == Gdk.KEY_Escape:
                self.window.close()
                return True
            return False

        def _blur(self, win, _param):
            # Only a panel that has had the focus closes on losing it: one
            # opened without it (from a script, say) would close at once.
            if win.is_active():
                self._was_active = True
                return
            if getattr(self, "_was_active", False):
                GLib.timeout_add(150, lambda: (not win.is_active() and win.close(), False)[1])

    def hints_bar(pairs):
        box = Gtk.Box(spacing=12)
        box.add_css_class("footer")
        for key, label in pairs:
            item = Gtk.Box(spacing=6)
            k = Gtk.Label(label=key)
            k.add_css_class("key")
            item.append(k)
            lab = Gtk.Label(label=label)
            lab.add_css_class("keylabel")
            item.append(lab)
            box.append(item)
        return box

    def section(text: str, count: int | None = None):
        box = Gtk.Box(spacing=8)
        lab = Gtk.Label(label=text.upper(), xalign=0)
        lab.add_css_class("section")
        box.append(lab)
        if count is not None:
            c = Gtk.Label(label=str(count), valign=Gtk.Align.CENTER)
            c.add_css_class("count")
            c.set_margin_top(8)
            box.append(c)
        return box

    def row(glyph: str = "", name: str = "", sub: str = "", end=None, icon: str | None = None,
            selected: bool = False, on_activate=None, tooltip: str = ""):
        """A row as New-KitRow draws it: tile (icon or glyph), name over sub,
        something at the end. A button when it does something."""
        inner = Gtk.Box(spacing=12)
        tile = Gtk.CenterBox(valign=Gtk.Align.CENTER, hexpand=False)
        tile.add_css_class("tile")
        if icon:
            img = Gtk.Image.new_from_icon_name(icon)
            img.set_pixel_size(22)
            tile.set_center_widget(img)
        else:
            g = Gtk.Label(label=glyph)
            g.add_css_class("glyph")
            tile.set_center_widget(g)
        inner.append(tile)
        col = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, valign=Gtk.Align.CENTER, hexpand=True)
        n = Gtk.Label(label=name, xalign=0, ellipsize=3)
        n.add_css_class("name")
        col.append(n)
        if sub:
            s = Gtk.Label(label=sub, xalign=0, ellipsize=3)
            s.add_css_class("sub")
            col.append(s)
        inner.append(col)
        if end is not None:
            inner.append(end)
        if on_activate:
            inner.set_halign(Gtk.Align.FILL)
            w = Gtk.Button(child=inner)
            w.connect("clicked", lambda *_: on_activate())
        else:
            w = Gtk.Box()
            w.append(inner)
            inner.set_hexpand(True)
        w.add_css_class("row")
        if selected:
            w.add_css_class("selected")
        if tooltip:
            w.set_tooltip_text(tooltip)
        return w

    def badge(text: str, kind: str = ""):
        b = Gtk.Label(label=text, valign=Gtk.Align.CENTER)
        b.add_css_class("badge")
        if kind:
            b.add_css_class(kind)
        return b

    def meter(fraction: float, alert: bool = False):
        """A thin bar: a track with a fill fraction (0..1) of its width."""
        track = Gtk.Box(hexpand=True, valign=Gtk.Align.CENTER)
        track.add_css_class("bar-track")
        fill = Gtk.Box()
        fill.add_css_class("bar-fill")
        if alert:
            fill.add_css_class("alert")
        frac = max(0.0, min(1.0, fraction))
        fill.set_hexpand(False)

        def size(widget, *_):
            w = track.get_width()
            fill.set_size_request(max(4, int(w * frac)) if frac > 0 else 0, -1)
        track.append(fill)
        track.connect("map", lambda *_: GLib.idle_add(lambda: (size(track), False)[1]))
        return track

    def scroller(child, max_height: int = 520):
        sw = Gtk.ScrolledWindow(hscrollbar_policy=Gtk.PolicyType.NEVER,
                                vscrollbar_policy=Gtk.PolicyType.AUTOMATIC)
        sw.set_propagate_natural_height(True)
        sw.set_max_content_height(max_height)
        sw.set_child(child)
        return sw

    class NS:
        pass

    ns = NS()
    ns.Gtk, ns.Gdk, ns.GLib = Gtk, Gdk, GLib
    ns.Panel, ns.hints_bar, ns.section, ns.row, ns.badge = Panel, hints_bar, section, row, badge
    ns.meter, ns.scroller = meter, scroller
    return ns


SETTINGS = settings()
T = Text(session_language(SETTINGS))
