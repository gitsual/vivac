"""Drawn pieces the redesigned panels share: a ring gauge, a sparkline, a
level bar with ticks, a stacked bar. Each is a Gtk.DrawingArea painted with
Cairo from the palette tokens, with a set() to change its value and redraw.

The Windows side draws the same pieces in WPF (Ellipse arcs, Polyline), so a
panel reads alike on both systems; the geometry here is the reference.
"""
from __future__ import annotations

import math


def rgb(hex_colour: str, alpha: float = 1.0) -> tuple[float, float, float, float]:
    h = hex_colour.lstrip("#")
    return (int(h[0:2], 16) / 255, int(h[2:4], 16) / 255, int(h[4:6], 16) / 255, alpha)


def widgets(Gtk, p: dict[str, str]):
    """The drawn widgets, bound to GTK and the palette."""

    class Ring(Gtk.DrawingArea):
        """A ring: track, an arc for the fraction (0..1), from 12 o'clock
        clockwise. `kind` alert turns the arc to the alert colour."""

        def __init__(self, size: int = 96, thickness: int = 10, fraction: float = 0.0, kind: str = "") -> None:
            super().__init__()
            self.set_content_width(size)
            self.set_content_height(size)
            self.thickness, self.fraction, self.kind = thickness, fraction, kind
            self.set_draw_func(self._draw)

        def set(self, fraction: float, kind: str | None = None) -> None:
            self.fraction = max(0.0, min(1.0, fraction))
            if kind is not None:
                self.kind = kind
            self.queue_draw()

        def _draw(self, _area, cr, w, h) -> None:
            r = min(w, h) / 2 - self.thickness / 2
            cx, cy = w / 2, h / 2
            cr.set_line_width(self.thickness)
            cr.set_line_cap(1)  # round
            cr.set_source_rgba(*rgb(p["surfaceAlt"]))
            cr.arc(cx, cy, r, 0, 2 * math.pi)
            cr.stroke()
            if self.fraction > 0:
                colour = p["alert"] if self.kind == "alert" else p["accent"]
                cr.set_source_rgba(*rgb(colour))
                start = -math.pi / 2
                cr.arc(cx, cy, r, start, start + 2 * math.pi * self.fraction)
                cr.stroke()

    class Spark(Gtk.DrawingArea):
        """A sparkline over the last N values (0..1), filled under the line."""

        def __init__(self, width: int = 200, height: int = 48, values: list[float] | None = None,
                     keep: int = 60) -> None:
            super().__init__()
            self.set_content_width(width)
            self.set_content_height(height)
            self.set_hexpand(True)
            self.values = list(values or [])
            self.keep = keep
            self.set_draw_func(self._draw)

        def push(self, value: float) -> None:
            self.values.append(max(0.0, min(1.0, value)))
            self.values = self.values[-self.keep:]
            self.queue_draw()

        def _draw(self, _area, cr, w, h) -> None:
            cr.set_source_rgba(*rgb(p["line"], 0.6))
            cr.set_line_width(1)
            for frac in (0.5, 1.0):
                y = round(h - (h - 2) * frac) + 0.5
                cr.move_to(0, y)
                cr.line_to(w, y)
            cr.stroke()
            vals = self.values
            if len(vals) < 2:
                return
            step = w / (self.keep - 1)
            x0 = w - step * (len(vals) - 1)
            pts = [(x0 + i * step, h - 1 - (h - 2) * v) for i, v in enumerate(vals)]
            cr.move_to(pts[0][0], h)
            for x, y in pts:
                cr.line_to(x, y)
            cr.line_to(pts[-1][0], h)
            cr.close_path()
            cr.set_source_rgba(*rgb(p["accent"], 0.18))
            cr.fill()
            cr.move_to(*pts[0])
            for x, y in pts[1:]:
                cr.line_to(x, y)
            cr.set_source_rgba(*rgb(p["accent"]))
            cr.set_line_width(2)
            cr.stroke()

    class Level(Gtk.DrawingArea):
        """A level bar of `ticks` notches (a vumeter or a capped level): the
        first fraction lit in accent, past `danger` (0..1) in alert."""

        def __init__(self, ticks: int = 28, height: int = 8, fraction: float = 0.0,
                     danger: float | None = None, muted: bool = False) -> None:
            super().__init__()
            self.set_content_height(height)
            self.set_hexpand(True)
            self.ticks, self.fraction, self.danger, self.muted = ticks, fraction, danger, muted
            self.set_draw_func(self._draw)

        def set(self, fraction: float, muted: bool | None = None) -> None:
            self.fraction = max(0.0, min(1.0, fraction))
            if muted is not None:
                self.muted = muted
            self.queue_draw()

        def _draw(self, _area, cr, w, h) -> None:
            gap = 2
            tw = (w - gap * (self.ticks - 1)) / self.ticks
            lit = round(self.fraction * self.ticks)
            for i in range(self.ticks):
                x = i * (tw + gap)
                if i < lit and not self.muted:
                    over = self.danger is not None and (i + 1) / self.ticks > self.danger
                    cr.set_source_rgba(*rgb(p["alert"] if over else p["accent"]))
                else:
                    cr.set_source_rgba(*rgb(p["surfaceAlt"]))
                cr.rectangle(x, 0, tw, h)
                cr.fill()

    class Stack(Gtk.DrawingArea):
        """A stacked bar: [(fraction, colour token or #hex)], rest as track."""

        def __init__(self, height: int = 12, parts: list[tuple[float, str]] | None = None) -> None:
            super().__init__()
            self.set_content_height(height)
            self.set_hexpand(True)
            self.parts = parts or []
            self.set_draw_func(self._draw)

        def set(self, parts: list[tuple[float, str]]) -> None:
            self.parts = parts
            self.queue_draw()

        def _draw(self, _area, cr, w, h) -> None:
            radius = h / 2
            cr.new_sub_path()
            cr.arc(radius, radius, radius, math.pi / 2, 3 * math.pi / 2)
            cr.arc(w - radius, radius, radius, -math.pi / 2, math.pi / 2)
            cr.close_path()
            cr.clip()
            cr.set_source_rgba(*rgb(p["surfaceAlt"]))
            cr.paint()
            x = 0.0
            for frac, colour in self.parts:
                width = w * max(0.0, frac)
                cr.set_source_rgba(*rgb(p.get(colour, colour)))
                cr.rectangle(x, 0, width, h)
                cr.fill()
                x += width

    class NS:
        pass

    ns = NS()
    ns.Ring, ns.Spark, ns.Level, ns.Stack = Ring, Spark, Level, Stack
    return ns
