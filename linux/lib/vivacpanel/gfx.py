"""Drawing helpers the redesigned panels share beyond draw.py: text through
Pango, rounded rectangles, a smooth line through points, and a thin bar.
Cairo/Pango only; GTK is passed in, as draw.widgets does, so the module
imports nothing graphical at load.
"""
from __future__ import annotations

import math

from .draw import rgb

FAMILY = "JetBrainsMono Nerd Font Propo, JetBrains Mono, monospace"


def helpers(Gtk, pal: dict):
    """text(), rounded(), curve(), shadow-free Bar, over this palette."""
    import gi

    gi.require_version("Pango", "1.0")
    gi.require_version("PangoCairo", "1.0")
    from gi.repository import Pango, PangoCairo

    def text(cr, s: str, x: float, y: float, size: float, colour: str, bold: bool = False,
             anchor: str = "start") -> float:
        """Draw s with its vertical middle at y; x is its start, middle or end.
        Returns the width drawn."""
        layout = PangoCairo.create_layout(cr)
        d = Pango.FontDescription()
        d.set_family(FAMILY)
        d.set_weight(Pango.Weight.BOLD if bold else Pango.Weight.NORMAL)
        d.set_absolute_size(size * Pango.SCALE)
        layout.set_font_description(d)
        layout.set_text(s, -1)
        w, h = layout.get_pixel_size()
        x -= w / 2 if anchor == "middle" else w if anchor == "end" else 0
        cr.move_to(x, y - h / 2)
        cr.set_source_rgba(*rgb(pal.get(colour, colour)))
        PangoCairo.show_layout(cr, layout)
        cr.new_path()  # move_to left a current point that the next arc would join
        return w

    def rounded(cr, x: float, y: float, w: float, h: float, r: float) -> None:
        r = min(r, w / 2, h / 2)
        cr.new_sub_path()
        cr.arc(x + w - r, y + r, r, -math.pi / 2, 0)
        cr.arc(x + w - r, y + h - r, r, 0, math.pi / 2)
        cr.arc(x + r, y + h - r, r, math.pi / 2, math.pi)
        cr.arc(x + r, y + r, r, math.pi, 3 * math.pi / 2)
        cr.close_path()

    def curve(cr, pts: list[tuple[float, float]]) -> None:
        """A smooth line through pts (Catmull-Rom as Beziers), from a move_to."""
        cr.move_to(*pts[0])
        for i in range(len(pts) - 1):
            p0, p1, p2 = pts[max(i - 1, 0)], pts[i], pts[i + 1]
            p3 = pts[min(i + 2, len(pts) - 1)]
            cr.curve_to(p1[0] + (p2[0] - p0[0]) / 6, p1[1] + (p2[1] - p0[1]) / 6,
                        p2[0] - (p3[0] - p1[0]) / 6, p2[1] - (p3[1] - p1[1]) / 6, p2[0], p2[1])

    class Bar(Gtk.DrawingArea):
        """A thin bar, a fraction of the track in one colour."""

        def __init__(self, colour: str = "accent", height: int = 6) -> None:
            super().__init__()
            self.set_content_height(height)
            self.set_hexpand(True)
            self.set_valign(Gtk.Align.CENTER)
            self.fraction, self.colour = 0.0, colour
            self.set_draw_func(self._draw)

        def set(self, fraction: float, colour: str | None = None) -> None:
            self.fraction = max(0.0, min(1.0, fraction))
            if colour:
                self.colour = colour
            self.queue_draw()

        def _draw(self, _a, cr, w, h) -> None:
            rounded(cr, 0, 0, w, h, h / 2)
            cr.set_source_rgba(*rgb(pal["surfaceAlt"]))
            cr.fill()
            if self.fraction > 0:
                rounded(cr, 0, 0, max(h, w * self.fraction), h, h / 2)
                cr.set_source_rgba(*rgb(pal.get(self.colour, self.colour)))
                cr.fill()

    class NS:
        pass

    ns = NS()
    ns.text, ns.rounded, ns.curve, ns.Bar, ns.rgb = text, rounded, curve, Bar, rgb
    return ns
