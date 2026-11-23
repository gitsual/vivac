"""Sound: the devices and every application playing, each with its own level.

The Windows side's Show-Sound (windows/lib/Surfaces.psm1) on PipeWire: the
default output's level up top, then the outputs and inputs (a click makes one
the default), then one row per application with its icon, its level and its
mute, an application with several streams being one row that moves them all.
Everything goes through pactl, which pipewire-pulse answers; nothing here
holds state the sound server does not.
"""
from __future__ import annotations

import json
import os
import subprocess
from dataclasses import dataclass, field

PACTL = os.environ.get("VIVAC_PACTL", "pactl")


def _pactl(*args: str) -> str:
    try:
        return subprocess.run([PACTL, *args], capture_output=True, text=True, timeout=4).stdout
    except (OSError, subprocess.TimeoutExpired):
        return ""


def _percent(volume: dict) -> int:
    """The loudest channel, as pactl reports it ("40%")."""
    best = 0
    for channel in (volume or {}).values():
        try:
            best = max(best, int(str(channel.get("value_percent", "0")).rstrip("%")))
        except (ValueError, AttributeError):
            continue
    return best


@dataclass
class Device:
    flow: str  # "sink" | "source"
    name: str
    description: str
    volume: int
    muted: bool
    default: bool


@dataclass
class App:
    name: str
    icon: str
    volume: int
    muted: bool
    streams: list[int] = field(default_factory=list)
    playing: bool = True  # False when every stream is paused (corked)


def short(description: str) -> str:
    """A device's name without what every name repeats: "Starship/Matisse HD
    Audio Controller Estéreo analógico" reads "Starship/Matisse · Estéreo
    analógico". The full name stays in the tooltip."""
    for noise in (" High Definition Audio Controller", " HD Audio Controller", " Audio Controller"):
        if noise in description:
            head, _, tail = description.partition(noise)
            return f"{head} · {tail.strip()}" if tail.strip() else head
    return description


def _json(*args: str) -> list:
    try:
        data = json.loads(_pactl("-f", "json", *args) or "[]")
    except json.JSONDecodeError:
        return []
    return data if isinstance(data, list) else []


def devices(flow: str) -> list[Device]:
    """Outputs (sink) or inputs (source); a sink's monitor is not an input."""
    default = _pactl(f"get-default-{flow}").strip()
    out = []
    for d in _json("list", f"{flow}s"):
        if not isinstance(d, dict):
            continue
        if flow == "source" and (d.get("monitor_of_sink") not in (None, "", "n/a")
                                 or str(d.get("name", "")).endswith(".monitor")):
            continue
        out.append(Device(flow, str(d.get("name", "")), str(d.get("description") or d.get("name", "")),
                          _percent(d.get("volume")), bool(d.get("mute")), d.get("name") == default))
    return out


def apps() -> list[App]:
    """One entry per application; its level is its loudest stream's."""
    groups: dict[str, App] = {}
    for s in _json("list", "sink-inputs"):
        if not isinstance(s, dict):
            continue
        props = s.get("properties") or {}
        if props.get("media.role") == "event" or props.get("application.id") == "org.PulseAudio.pavucontrol":
            continue
        name = props.get("application.name") or props.get("application.process.binary") or props.get("media.name") or "?"
        icon = props.get("application.icon_name") or props.get("application.process.binary") or ""
        app = groups.setdefault(name, App(name, str(icon).lower(), 0, True))
        app.streams.append(int(s.get("index", -1)))
        app.volume = max(app.volume, _percent(s.get("volume")))
        app.muted = app.muted and bool(s.get("mute"))
        live = not s.get("corked")
        app.playing = live if len(app.streams) == 1 else (app.playing or live)
    return sorted(groups.values(), key=lambda a: a.name.lower())


def set_default(flow: str, name: str) -> None:
    _pactl(f"set-default-{flow}", name)


def set_device_volume(flow: str, name: str, percent: int) -> None:
    _pactl(f"set-{flow}-volume", name, f"{max(0, min(150, percent))}%")


def set_device_mute(flow: str, name: str, muted: bool) -> None:
    _pactl(f"set-{flow}-mute", name, "1" if muted else "0")


def set_app_volume(app: App, percent: int) -> None:
    for index in app.streams:
        _pactl("set-sink-input-volume", str(index), f"{max(0, min(150, percent))}%")


def set_app_mute(app: App, muted: bool) -> None:
    for index in app.streams:
        _pactl("set-sink-input-mute", str(index), "1" if muted else "0")


GLYPH_OUT, GLYPH_IN, GLYPH_APP, GLYPH_MUTE = "\U000F057E", "\U000F036C", "\U000F075A", "\U000F075F"
CAP = 150  # the sound server's ceiling the panel allows; 100 is the unity mark


def _css(p: dict[str, str]) -> str:
    return f"""
.vivac .snd-card {{ background: {p['surface']}; border-radius: 12px; padding: 14px; }}
.vivac .snd-app {{ background: {p['surface']}; border-radius: 12px; padding: 10px 12px 8px 12px; }}
.vivac .snd-cap-label {{ font-size: 12px; font-weight: 700; letter-spacing: 1px; color: {p['muted']}; }}
.vivac .snd-side {{ font-size: 12px; color: {p['textSecondary']}; }}
.vivac .snd-count {{ font-size: 12px; color: {p['text']}; background: {p['bg']}; border-radius: 8px; padding: 0 7px; }}
.vivac .snd-count.on-bg {{ background: {p['surface']}; }}
.vivac button.snd-chip {{ min-height: 28px; padding: 0 10px; border-radius: 8px; border: none; box-shadow: none;
  background: {p['surfaceAlt']}; color: {p['text']}; font-size: 12px; }}
.vivac button.snd-chip:hover {{ background: {p['line']}; }}
.vivac button.snd-chip.sel {{ background: {p['actionFill']}; color: {p['actionText']}; font-weight: 700;
  box-shadow: 0 0 0 2px {p['bg']}, 0 0 0 4px {p['focusRing']}; }}
.vivac .snd-chip-vol {{ color: {p['textSecondary']}; }}
.vivac .snd-big {{ font-size: 36px; font-weight: 700; color: {p['text']}; }}
.vivac .snd-big.dim {{ color: {p['muted']}; }}
.vivac .snd-tag {{ font-size: 12px; color: {p['textSecondary']}; background: {p['bg']}; border-radius: 8px; padding: 2px 8px; }}
.vivac .snd-scale {{ font-size: 12px; color: {p['textSecondary']}; }}
.vivac button.snd-mute {{ min-width: 32px; min-height: 32px; padding: 0; border-radius: 8px; border: none; box-shadow: none;
  background: {p['surfaceAlt']}; color: {p['accent']}; font-size: 16px; }}
.vivac button.snd-mute.big {{ min-width: 40px; min-height: 40px; border-radius: 10px; font-size: 20px; }}
.vivac button.snd-mute:hover {{ background: {p['line']}; }}
.vivac button.snd-mute.on {{ background: {p['alert']}; color: {p['bg']}; }}
.vivac .snd-tile {{ min-width: 36px; min-height: 36px; border-radius: 10px; background: {p['surfaceAlt']}; color: {p['accent']}; font-size: 18px; }}
.vivac .snd-tile.live {{ box-shadow: 0 0 0 2px {p['bg']}, 0 0 0 4px {p['success']}; }}
.vivac .snd-tile.quiet {{ color: {p['muted']}; }}
.vivac .snd-name {{ font-size: 13px; font-weight: 700; }}
.vivac .snd-name.quiet {{ color: {p['textSecondary']}; }}
.vivac .snd-state {{ font-size: 12px; }}
.vivac .snd-state.playing {{ color: {p['success']}; }}
.vivac .snd-state.silenced {{ color: {p['alert']}; }}
.vivac .snd-state.paused {{ color: {p['textSecondary']}; }}
.vivac .snd-pct {{ font-size: 15px; font-weight: 700; }}
.vivac .snd-pct.struck {{ color: {p['textSecondary']}; text-decoration: line-through; }}
.vivac button.snd-head {{ background: {p['surface']}; color: {p['textSecondary']}; border-radius: 8px; border: none;
  box-shadow: none; min-height: 28px; padding: 0 10px; font-size: 12px; }}
.vivac button.snd-head:hover {{ background: {p['surfaceAlt']}; color: {p['text']}; }}
.vivac expander.snd-fold title {{ color: {p['textSecondary']}; font-size: 12px; padding: 4px 0; }}
.vivac expander.snd-fold title:hover {{ color: {p['text']}; }}
"""


def fader_widget(Gtk, p: dict[str, str]):
    """A slider 0..CAP drawn as in the board: accent up to the value, the
    zone past 100 tinted alert, a tick at 100 and a round knob. Drag, click,
    arrow keys; `on_change(percent)` only when the whole number changes."""
    from gi.repository import Pango

    from .draw import rgb

    class Fader(Gtk.DrawingArea):
        PAD = 8

        def __init__(self, value: int, on_change, muted: bool = False, on_drag=None) -> None:
            super().__init__()
            self.set_content_height(26)
            self.set_hexpand(True)
            self.set_focusable(True)
            self.value, self.muted = max(0, min(CAP, value)), muted
            self.on_change, self.on_drag = on_change, on_drag
            self.set_draw_func(self._draw)
            drag = Gtk.GestureDrag()
            drag.connect("drag-begin", self._begin)
            drag.connect("drag-update", self._update)
            drag.connect("drag-end", lambda *_: self.on_drag and self.on_drag(False))
            self.add_controller(drag)
            keys = Gtk.EventControllerKey()
            keys.connect("key-pressed", self._key)
            self.add_controller(keys)
            self._start = 0.0

        def _x_to_value(self, x: float) -> int:
            span = max(1, self.get_width() - 2 * self.PAD)
            return round(max(0.0, min(1.0, (x - self.PAD) / span)) * CAP)

        def _begin(self, _g, x, _y) -> None:
            self._start = x
            if self.on_drag:
                self.on_drag(True)
            self.grab_focus()
            self.move_to(self._x_to_value(x))

        def _update(self, _g, ox, _oy) -> None:
            self.move_to(self._x_to_value(self._start + ox))

        def _key(self, _c, keyval, _code, _state) -> bool:
            from gi.repository import Gdk
            step = {Gdk.KEY_Left: -1, Gdk.KEY_Right: 1, Gdk.KEY_Down: -1, Gdk.KEY_Up: 1,
                    Gdk.KEY_Page_Down: -10, Gdk.KEY_Page_Up: 10}.get(keyval)
            if step is None:
                return False
            self.move_to(self.value + step)
            return True

        def move_to(self, value: int) -> None:
            value = max(0, min(CAP, value))
            if value != self.value:
                self.value = value
                self.queue_draw()
                self.on_change(value)

        def _draw(self, _a, cr, w, h) -> None:
            import math
            span = w - 2 * self.PAD
            x_val = self.PAD + span * self.value / CAP
            x_100 = self.PAD + span * 100 / CAP
            ty, th = (h - 10) / 2, 10
            cr.save()
            cr.new_sub_path()
            cr.arc(5, ty + 5, 5, math.pi / 2, 3 * math.pi / 2)
            cr.arc(w - 5, ty + 5, 5, -math.pi / 2, math.pi / 2)
            cr.close_path()
            cr.clip()
            cr.set_source_rgba(*rgb(p["surfaceAlt"]))
            cr.paint()
            cr.set_source_rgba(*rgb(p["alert"], 0.28))
            cr.rectangle(x_100, ty, w - x_100, th)
            cr.fill()
            cr.set_source_rgba(*rgb(p["muted"] if self.muted else p["accent"]))
            cr.rectangle(0, ty, x_val, th)
            cr.fill()
            cr.restore()
            cr.set_source_rgba(*rgb(p["textSecondary"], 0.7))
            cr.rectangle(x_100 - 1, ty - 3, 2, th + 6)
            cr.fill()
            cr.set_source_rgba(*rgb(p["bg"]))
            cr.arc(x_val, h / 2, 10, 0, 2 * math.pi)
            cr.fill()
            cr.set_source_rgba(*rgb(p["text"]))
            cr.arc(x_val, h / 2, 8, 0, 2 * math.pi)
            cr.fill()
            if self.has_focus():
                cr.set_source_rgba(*rgb(p["focusRing"]))
                cr.set_line_width(2)
                cr.arc(x_val, h / 2, 11, 0, 2 * math.pi)
                cr.stroke()

    class Ruler(Gtk.DrawingArea):
        """0 / 50 / 100 / 150 under a Fader, at the positions its knob takes."""

        def __init__(self) -> None:
            super().__init__()
            self.set_content_height(16)
            self.set_hexpand(True)
            self.set_draw_func(self._draw)

        def _draw(self, _a, cr, w, h) -> None:
            span = w - 2 * Fader.PAD
            colour = rgb(p["textSecondary"])
            for value in (0, 50, 100, 150):
                lay = self.create_pango_layout(str(value))
                lay.set_font_description(Pango.FontDescription("JetBrainsMono Nerd Font Propo 9"))
                tw = lay.get_pixel_size()[0]
                x = Fader.PAD + span * value / CAP
                x = 0 if value == 0 else (w - tw if value == CAP else x - tw / 2)
                cr.set_source_rgba(*colour)
                cr.move_to(x, 0)
                from gi.repository import PangoCairo
                PangoCairo.show_layout(cr, lay)

    Fader.Ruler = Ruler
    return Fader


def main() -> int:
    from .kit import T, gtk_kit

    k = gtk_kit()
    Gtk, GLib = k.Gtk, k.GLib
    panel = k.Panel("sound", GLYPH_OUT, T("sound.title"), "",
                    hints=[(T("sound.key.click"), T("sound.key.default")),
                           (T("sound.key.icon"), T("sound.key.mute")),
                           ("Esc", T("sound.key.close"))], width=440)
    p = panel.p
    provider = Gtk.CssProvider()
    provider.load_from_string(_css(p))
    Gtk.StyleContext.add_provider_for_display(k.Gdk.Display.get_default(), provider,
                                              Gtk.STYLE_PROVIDER_PRIORITY_USER + 1)
    Fader = fader_widget(Gtk, p)
    state = {"sig": None, "dragging": False, "inputs_open": False}

    def label(text: str, *classes: str, xalign: float = 0, **kw):
        lab = Gtk.Label(label=text, xalign=xalign, **kw)
        for c in classes:
            lab.add_css_class(c)
        return lab

    def mute_button(muted: bool, glyph: str, on_mute, big: bool = False):
        b = Gtk.Button(label=GLYPH_MUTE if muted else glyph)
        b.add_css_class("snd-mute")
        if big:
            b.add_css_class("big")
        if muted:
            b.add_css_class("on")
        b.set_valign(Gtk.Align.CENTER)
        b.set_tooltip_text(T("sound.muted_short") if muted else T("sound.key.mute"))
        b.connect("clicked", lambda *_: (on_mute(not muted), refresh(force=True)))
        return b

    def drag(on: bool) -> None:
        state["dragging"] = on

    def section_head(title: str, count: int, side=None, on_bg: bool = False):
        box = Gtk.Box(spacing=8)
        box.append(label(title.upper(), "snd-cap-label"))
        box.append(label(str(count), "snd-count", *(["on-bg"] if on_bg else []), valign=Gtk.Align.CENTER))
        spacer = Gtk.Box(hexpand=True)
        box.append(spacer)
        if side is not None:
            box.append(side)
        return box

    def build(_panel):
        pavu = Gtk.Button(label="pavucontrol")
        pavu.add_css_class("snd-head")
        pavu.set_tooltip_text(T("sound.more"))
        pavu.connect("clicked", lambda *_: (subprocess.Popen(["pavucontrol"], start_new_session=True),
                                            panel.window.close()))
        panel.header_end.append(pavu)
        root = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=14)
        root.set_margin_top(14)
        state["root"] = root
        fill(root)
        return root

    def output_card(outs: list[Device]):
        default = next((d for d in outs if d.default), None)
        card = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=10)
        card.add_css_class("snd-card")
        card.append(section_head(T("sound.output"), len(outs),
                                 label(T("sound.default"), "snd-side")))
        if not outs:
            card.append(label(T("sound.none"), "empty"))
            return card
        chips = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=6)
        line, used = None, 0
        for d in outs:
            text = short(d.description) + ("" if d.default else (" " + (T("sound.muted_short") if d.muted else f"{d.volume}%")))
            need = chips.create_pango_layout(text).get_pixel_size()[0] + (36 if d.default else 28)
            inner = Gtk.Box(spacing=6)
            if d.default:
                inner.append(Gtk.Label(label="\u2713"))
            inner.append(Gtk.Label(label=short(d.description), ellipsize=3))
            if not d.default:
                inner.append(label(T("sound.muted_short") if d.muted else f"{d.volume}%", "snd-chip-vol"))
            chip = Gtk.Button(child=inner)
            chip.add_css_class("snd-chip")
            if d.default:
                chip.add_css_class("sel")
            chip.set_tooltip_text(d.description)
            chip.connect("clicked", lambda *_, d=d: (set_default(d.flow, d.name), refresh(force=True)))
            if line is None or used + need + 6 > 380:
                line, used = Gtk.Box(spacing=6), 0
                chips.append(line)
            line.append(chip)
            used += need + 6
        card.append(chips)
        if default:
            top = Gtk.Box(spacing=12)
            top.append(mute_button(default.muted, GLYPH_OUT,
                                   lambda m: set_device_mute("sink", default.name, m), big=True))
            big = Gtk.Label(xalign=0)
            big.add_css_class("snd-big")
            if default.muted:
                big.add_css_class("dim")

            def show(v):
                big.set_markup(f'{v}<span size="small" foreground="{p["textSecondary"]}">%</span>')
            show(default.volume)
            top.append(big)
            top.append(Gtk.Box(hexpand=True))
            top.append(label(T("sound.cap", CAP), "snd-tag", valign=Gtk.Align.CENTER))
            card.append(top)
            card.append(Fader(default.volume,
                              lambda v: (set_device_volume("sink", default.name, v), show(v)),
                              muted=default.muted, on_drag=drag))
            card.append(Fader.Ruler())
        return card

    def app_card(a: App):
        card = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=6)
        card.add_css_class("snd-app")
        top = Gtk.Box(spacing=12)
        theme = Gtk.IconTheme.get_for_display(k.Gdk.Display.get_default())
        tile = Gtk.CenterBox(valign=Gtk.Align.CENTER)
        tile.add_css_class("snd-tile")
        live = a.playing and not a.muted
        if live:
            tile.add_css_class("live")
        elif a.muted or not a.playing:
            tile.add_css_class("quiet")
        if a.icon and theme.has_icon(a.icon):
            img = Gtk.Image.new_from_icon_name(a.icon)
            img.set_pixel_size(22)
            tile.set_center_widget(img)
        else:
            tile.set_center_widget(Gtk.Label(label=GLYPH_APP))
        top.append(tile)
        col = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=2, valign=Gtk.Align.CENTER, hexpand=True)
        col.append(label(a.name, "snd-name", *(["quiet"] if a.muted else []), ellipsize=3))
        if a.muted:
            state_text, kind = f"{GLYPH_MUTE} {T('sound.silenced')}", "silenced"
        elif a.playing:
            state_text, kind = f"▂▄▆ {T('sound.playing')}", "playing"
        else:
            state_text, kind = T("sound.paused"), "paused"
        if len(a.streams) > 1:
            state_text += f" · {T('sound.app_sub', len(a.streams))}"
        col.append(label(state_text, "snd-state", kind))
        top.append(col)
        pct = label(f"{a.volume}%", "snd-pct", *(["struck"] if a.muted else []), xalign=1,
                    valign=Gtk.Align.CENTER)
        top.append(pct)
        top.append(mute_button(a.muted, GLYPH_APP, lambda m, a=a: set_app_mute(a, m)))
        card.append(top)
        card.append(Fader(a.volume, lambda v, a=a, pct=pct: (set_app_volume(a, v), pct.set_label(f"{v}%")),
                          muted=a.muted, on_drag=drag))
        return card

    def input_card(ins: list[Device]):
        card = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=8)
        card.add_css_class("snd-card")
        card.append(section_head(T("sound.input"), len(ins), on_bg=True))
        if not ins:
            card.append(label(T("sound.none"), "empty"))
            return card

        def entry(d: Device, sub: str):
            box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=6)
            top = Gtk.Box(spacing=12)
            top.append(mute_button(d.muted, GLYPH_IN, lambda m, d=d: set_device_mute(d.flow, d.name, m)))
            col = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, valign=Gtk.Align.CENTER, hexpand=True)
            col.append(label(short(d.description), "snd-name", ellipsize=3))
            col.append(label(sub, "snd-side", ellipsize=3))
            top.append(col)
            pct = label(f"{d.volume}%", "snd-pct", *(["struck"] if d.muted else []), xalign=1)
            top.append(pct)
            box.append(top)
            box.append(Fader(d.volume, lambda v, d=d, pct=pct: (set_device_volume(d.flow, d.name, v),
                                                                 pct.set_label(f"{v}%")),
                             muted=d.muted, on_drag=drag))
            box.set_tooltip_text(d.description)
            return box

        default = next((d for d in ins if d.default), ins[0])
        others = [d for d in ins if d is not default]
        card.append(entry(default, T("sound.default")))
        if others:
            fold = Gtk.Expander(label=T("sound.more_inputs", len(others)))
            fold.add_css_class("snd-fold")
            fold.set_expanded(state["inputs_open"])
            fold.connect("notify::expanded", lambda e, _p: state.__setitem__("inputs_open", e.get_expanded()))
            inner = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=10)
            for d in others:
                row = k.row(GLYPH_IN, short(d.description), T("sound.use"), tooltip=d.description,
                            on_activate=(lambda d=d: (set_default(d.flow, d.name), refresh(force=True))))
                inner.append(row)
            fold.set_child(inner)
            card.append(fold)
        return card

    def fill(root):
        child = root.get_first_child()
        while child:
            nxt = child.get_next_sibling()
            root.remove(child)
            child = nxt
        outs, ins, playing = devices("sink"), devices("source"), apps()
        state["sig"] = ([d.name for d in outs], [d.name for d in ins], [a.name for a in playing])
        default = next((d for d in outs if d.default), None)
        panel.subtitle.set_label(short(default.description) if default else T("sound.none"))

        body = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=14)
        body.append(output_card(outs))
        apps_box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=8)
        head = section_head(T("sound.apps"), len(playing))
        head.get_first_child().set_margin_start(0)
        apps_box.append(head)
        if not playing:
            apps_box.append(label(T("sound.no_apps"), "empty", wrap=True))
        else:
            lst = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=6)
            for a in playing:
                lst.append(app_card(a))
            apps_box.append(lst)
        body.append(apps_box)
        body.append(input_card(ins))
        try:
            mons = k.Gdk.Display.get_default().get_monitors()
            mh = min(mons.get_item(i).get_geometry().height for i in range(mons.get_n_items()))
        except (AttributeError, ValueError, TypeError):
            mh = 1080
        root.append(k.scroller(body, max(300, mh - 60 - 12 - 150)))

    def refresh(force: bool = False):
        if state["dragging"] and not force:
            return False
        if "root" in state:
            fill(state["root"])
        return False

    # Follow the sound server: a stream starting, a device plugged, a level
    # changed elsewhere. Bursts are folded into one redraw.
    pending = {"id": 0}

    def changed(*_):
        if pending["id"]:
            GLib.source_remove(pending["id"])
        pending["id"] = GLib.timeout_add(250, lambda: (pending.__setitem__("id", 0), refresh())[1])

    def watch():
        try:
            proc = subprocess.Popen([PACTL, "subscribe"], stdout=subprocess.PIPE, text=True)
        except OSError:
            return

        def on_line(ch, _cond):
            line = ch.readline()
            if not line:
                return False
            if "sink-input" in line or "'new'" in line or "'remove'" in line or "server" in line:
                changed()
            return True
        GLib.io_add_watch(proc.stdout, GLib.PRIORITY_DEFAULT, GLib.IO_IN | GLib.IO_HUP, on_line)

    panel.on_build = build
    watch()
    return panel.run()
