"""Calendar: the month under the clock, today marked.

The Windows side's calendar popup (windows/static/zebar/vivac/calendar.js) as a
panel: weeks from Monday with their ISO numbers, today filled in the accent,
the neighbouring months' days receding, a month either way with the arrow
keys or the wheel, and a way back to today. The grid and the names are pure
(no GTK, no locale database), so the tests and the bar can use them.
"""
from __future__ import annotations

import datetime as dt
from dataclasses import dataclass


@dataclass
class Day:
    date: dt.date
    in_month: bool
    weekend: bool


@dataclass
class Week:
    number: int  # ISO week
    days: list[Day]


@dataclass
class Names:
    months: list[str]
    weekdays: list[str]  # Monday first
    weekdays_short: list[str]  # Monday first


_NAMES = {
    "en": Names(
        ["January", "February", "March", "April", "May", "June", "July", "August", "September",
         "October", "November", "December"],
        ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"],
        ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]),
    "es": Names(
        ["enero", "febrero", "marzo", "abril", "mayo", "junio", "julio", "agosto", "septiembre",
         "octubre", "noviembre", "diciembre"],
        ["lunes", "martes", "miércoles", "jueves", "viernes", "sábado", "domingo"],
        ["lun", "mar", "mié", "jue", "vie", "sáb", "dom"]),
}


def names(lang: str) -> Names:
    """Month and weekday names; a language without a table reads in English."""
    return _NAMES.get(lang, _NAMES["en"])


def weekday_name(day: dt.date, lang: str) -> str:
    return names(lang).weekdays[day.weekday()]


def long_date(day: dt.date, lang: str) -> str:
    n = names(lang)
    if lang == "es":
        return f"{n.weekdays[day.weekday()]}, {day.day} de {n.months[day.month - 1]} de {day.year}"
    return f"{n.weekdays[day.weekday()]}, {day.day} {n.months[day.month - 1]} {day.year}"


def month_grid(year: int, month: int) -> list[Week]:
    """Six weeks from the Monday on or before the 1st, as the bar draws them
    (a fixed height, so the panel does not jump from month to month)."""
    first = dt.date(year, month, 1)
    day = first - dt.timedelta(days=first.weekday())
    weeks = []
    for _ in range(6):
        row = []
        for i in range(7):
            row.append(Day(day, day.month == month, i >= 5))
            day += dt.timedelta(days=1)
        weeks.append(Week(row[0].date.isocalendar()[1], row))
    return weeks


def shift_month(year: int, month: int, delta: int) -> tuple[int, int]:
    index = year * 12 + (month - 1) + delta
    return index // 12, index % 12 + 1


def year_progress(today: dt.date) -> tuple[int, int, int, list[float]]:
    """(day of the year, days in the year, days left, how much of each of
    the twelve months is gone: whole ones 1, this one up to today, the rest 0)."""
    import calendar as stdlib
    total = 366 if stdlib.isleap(today.year) else 365
    day = today.timetuple().tm_yday
    month_days = stdlib.monthrange(today.year, today.month)[1]
    months = [1.0 if m < today.month else today.day / month_days if m == today.month else 0.0 for m in range(1, 13)]
    return day, total, total - day, months


def main() -> int:
    from .gfx import helpers
    from .kit import SETTINGS, T, gtk_kit, mix, session_language

    lang = session_language(SETTINGS)
    n = names(lang)
    k = gtk_kit()
    Gtk, Gdk, GLib = k.Gtk, k.Gdk, k.GLib
    p_ = k.Panel("calendar", "\U000F00ED", T("cal.title"), "",
                 hints=[("←  →", T("cal.key.nav")), ("T", T("cal.key.today")), ("Esc", T("cal.key.close"))],
                 width=460)
    today0 = dt.date.today()
    state = {"year": today0.year, "month": today0.month, "today": today0}
    pal = p_.p
    g = helpers(Gtk, pal)
    rgb, text, rounded = g.rgb, g.text, g.rounded
    dim = mix(pal["textSecondary"], pal["surface"], 0.55)  # the days of the neighbouring months

    class YearBar(Gtk.DrawingArea):
        """The year as twelve segments, each as full as its month is gone,
        the initial of the month under it, this month's in bold."""

        def __init__(self) -> None:
            super().__init__()
            self.set_content_height(34)
            self.set_hexpand(True)
            self.months = [0.0] * 12
            self.current = 0
            self.set_draw_func(self._draw)

        def set(self, months: list[float], current: int) -> None:
            self.months, self.current = months, current
            self.queue_draw()

        def _draw(self, _a, cr, w, h) -> None:
            gap = 4
            sw = (w - gap * 11) / 12
            for i, frac in enumerate(self.months):
                x = i * (sw + gap)
                rounded(cr, x, 0, sw, 8, 4)
                cr.set_source_rgba(*rgb(pal["surfaceAlt"], 0.8))
                cr.fill()
                if frac > 0:
                    cr.save()
                    rounded(cr, x, 0, sw, 8, 4)
                    cr.clip()
                    cr.rectangle(x, 0, sw * frac, 8)
                    cr.set_source_rgba(*rgb(pal["accent"], 1.0 if i == self.current else 0.8))
                    cr.fill()
                    cr.restore()
                text(cr, n.months[i][:1].upper(), x + sw / 2, 24, 11,
                     pal["text"] if i == self.current else pal["textSecondary"], bold=i == self.current,
                     anchor="middle")

    class MonthGrid(Gtk.DrawingArea):
        """The month: week numbers, the days from Monday, the weekend columns
        shaded, the current week banded, today filled with a ring."""

        def __init__(self) -> None:
            super().__init__()
            self.set_content_height(300)
            self.set_hexpand(True)
            self.weeks: list[Week] = []
            self.today = today0
            self.set_draw_func(self._draw)

        def set(self, weeks, today) -> None:
            self.weeks, self.today = weeks, today
            self.queue_draw()

        def _draw(self, _a, cr, w, h) -> None:
            inner = w - 24
            wk_w = 40
            col_w = (inner - wk_w) / 7
            x0, top = 12, 12
            head_h, gap, row_h = 20, 4, 42
            rows_top = top + head_h + gap
            # weekend columns, then the current week band
            for c in (5, 6):
                rounded(cr, x0 + wk_w + c * col_w, rows_top - 2, col_w, 6 * row_h + 4, 8)
                cr.set_source_rgba(*rgb(pal["bg"], 0.35))
                cr.fill()
            for r, week in enumerate(self.weeks):
                if any(d.date == self.today for d in week.days):
                    rounded(cr, x0, rows_top + r * row_h, inner, row_h, 10)
                    cr.set_source_rgba(*rgb(pal["surfaceAlt"]))
                    cr.fill()
            text(cr, T("cal.week_abbr"), x0 + wk_w / 2, top + head_h / 2, 11, pal["muted"], anchor="middle")
            for i in range(7):
                text(cr, n.weekdays_short[i].capitalize()[:3], x0 + wk_w + (i + 0.5) * col_w, top + head_h / 2, 12,
                     pal["accent"] if i >= 5 else pal["textSecondary"], bold=True, anchor="middle")
            for r, week in enumerate(self.weeks):
                cy = rows_top + r * row_h + row_h / 2
                current = any(d.date == self.today for d in week.days)
                text(cr, str(week.number), x0 + wk_w / 2, cy, 12, pal["accent"], bold=current, anchor="middle")
                for c, d in enumerate(week.days):
                    cx = x0 + wk_w + (c + 0.5) * col_w
                    if d.date == self.today:
                        rounded(cr, cx - 24, cy - 20, 48, 40, 12)
                        cr.set_source_rgba(*rgb(pal["focusRing"]))
                        cr.fill()
                        rounded(cr, cx - 22, cy - 18, 44, 36, 10)
                        cr.set_source_rgba(*rgb(pal["bg"]))
                        cr.fill()
                        rounded(cr, cx - 20, cy - 16, 40, 32, 8)
                        cr.set_source_rgba(*rgb(pal["actionFill"]))
                        cr.fill()
                        text(cr, str(d.date.day), cx, cy, 14, pal["actionText"], bold=True, anchor="middle")
                        continue
                    colour = dim if not d.in_month else pal["accent"] if d.weekend else pal["text"]
                    text(cr, str(d.date.day), cx, cy, 14, colour, anchor="middle")

    def style() -> None:
        p = pal
        css = f"""
.vivac .cal-hero {{ background: {p['surface']}; border-radius: 12px; padding: 14px 16px; }}
.vivac .cal-big {{ font-size: 84px; font-weight: 700; color: {p['accent']}; letter-spacing: -3px; }}
.vivac .cal-hero-day {{ font-size: 22px; font-weight: 700; color: {p['text']}; }}
.vivac .cal-hero-date {{ font-size: 12px; color: {p['textSecondary']}; }}
.vivac .cal-foot {{ font-size: 12px; color: {p['text']}; }}
.vivac .cal-foot b {{ font-weight: 700; }}
.vivac .cal-title {{ font-size: 15px; font-weight: 700; color: {p['textSecondary']}; }}
.vivac button.cal-nav {{ min-width: 36px; min-height: 34px; padding: 0; border-radius: 10px; border: none; box-shadow: none;
  background: {p['surface']}; color: {p['text']}; }}
.vivac button.cal-nav:hover {{ background: {p['surfaceAlt']}; }}
.vivac button.cal-nav:focus-visible {{ box-shadow: 0 0 0 2px {p['bg']}, 0 0 0 4px {p['focusRing']}; }}
.vivac button.cal-today {{ min-height: 34px; padding: 0 12px; border-radius: 10px; border: none; box-shadow: none;
  background: {p['surfaceAlt']}; color: {p['textSecondary']}; font-size: 12px; }}
.vivac button.cal-today:hover {{ background: {p['actionFill']}; color: {p['actionText']}; }}
.vivac button.cal-today:disabled {{ opacity: 1; }}
.vivac .cal-grid {{ background: {p['surface']}; border-radius: 12px; }}
"""
        prov = Gtk.CssProvider()
        prov.load_from_string(css)
        Gtk.StyleContext.add_provider_for_display(Gdk.Display.get_default(), prov,
                                                  Gtk.STYLE_PROVIDER_PRIORITY_USER)

    def label(text_: str, *classes: str, xalign: float = 0.5, markup: bool = False, **kw):
        w = Gtk.Label(xalign=xalign, **kw)
        (w.set_markup if markup else w.set_label)(text_)
        for c in classes:
            w.add_css_class(c)
        return w

    def build(panel):
        style()
        root = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=10)
        root.set_margin_top(12)
        state["root"] = root
        fill()
        # Keys and wheel go on the window once it exists.
        GLib.idle_add(attach)
        return root

    def go(delta: int | None) -> None:
        if delta is None:
            t = dt.date.today()
            state["year"], state["month"] = t.year, t.month
        else:
            state["year"], state["month"] = shift_month(state["year"], state["month"], delta)
        fill()

    def attach():
        win = p_.window
        if win is None:
            return True  # the window is set just after the body is built
        keys = Gtk.EventControllerKey()
        keys.set_propagation_phase(Gtk.PropagationPhase.CAPTURE)

        def pressed(_c, keyval, _code, _st):
            if keyval in (Gdk.KEY_Left, Gdk.KEY_Page_Up, Gdk.KEY_h):
                go(-1)
            elif keyval in (Gdk.KEY_Right, Gdk.KEY_Page_Down, Gdk.KEY_l):
                go(1)
            elif keyval in (Gdk.KEY_Up, Gdk.KEY_k):
                go(-12)
            elif keyval in (Gdk.KEY_Down, Gdk.KEY_j):
                go(12)
            elif keyval in (Gdk.KEY_t, Gdk.KEY_T, Gdk.KEY_Home):
                go(None)
            else:
                return False
            return True
        keys.connect("key-pressed", pressed)
        win.add_controller(keys)
        wheel = Gtk.EventControllerScroll.new(Gtk.EventControllerScrollFlags.VERTICAL)
        wheel.connect("scroll", lambda _c, _dx, dy: (go(-1 if dy < 0 else 1), True)[1])
        win.add_controller(wheel)
        return False

    def fill() -> None:
        root = state["root"]
        child = root.get_first_child()
        while child:
            nxt = child.get_next_sibling()
            root.remove(child)
            child = nxt
        today = dt.date.today()
        state["today"] = today
        year, month = state["year"], state["month"]
        p_.subtitle.set_label(f"{n.months[month - 1].capitalize()} {year}")

        hero = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=6)
        hero.add_css_class("cal-hero")
        top = Gtk.Box(spacing=14)
        top.append(label(str(today.day), "cal-big", xalign=0, valign=Gtk.Align.CENTER))
        col = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=2, valign=Gtk.Align.CENTER, hexpand=True)
        col.append(label(weekday_name(today, lang).capitalize(), "cal-hero-day", xalign=0))
        col.append(label(long_date(today, lang).split(", ", 1)[1], "cal-hero-date", xalign=0))
        badge = k.badge(T("cal.week", today.isocalendar()[1]), "info")
        badge.set_halign(Gtk.Align.START)
        badge.set_margin_top(4)
        col.append(badge)
        top.append(col)
        hero.append(top)
        day, total, left, months = year_progress(today)
        bar = YearBar()
        bar.set(months, today.month - 1)
        hero.append(bar)
        foot = Gtk.Box()
        foot.append(label(T("cal.day_of", f"<b>{day}</b>", total), "cal-foot", xalign=0, markup=True, hexpand=True))
        foot.append(label(T("cal.days_left_one") if left == 1 else T("cal.days_left", f"<b>{left}</b>"),
                          "cal-foot", xalign=1, markup=True))
        hero.append(foot)
        root.append(hero)

        nav = Gtk.Box(spacing=6)
        prev = Gtk.Button(label="\U000F0141")  # chevron-left
        prev.add_css_class("cal-nav")
        prev.set_tooltip_text(T("cal.prev"))
        prev.connect("clicked", lambda *_: go(-1))
        nxt_b = Gtk.Button(label="\U000F0142")  # chevron-right
        nxt_b.add_css_class("cal-nav")
        nxt_b.set_tooltip_text(T("cal.next"))
        nxt_b.connect("clicked", lambda *_: go(1))
        title = label(f"{n.months[month - 1].capitalize()} {year}", "cal-title", xalign=0.5)
        title.set_hexpand(True)
        back = Gtk.Button(label=T("cal.today"))
        back.add_css_class("cal-today")
        back.connect("clicked", lambda *_: go(None))
        back.set_sensitive((year, month) != (today.year, today.month))
        for w in (prev, title, nxt_b, back):
            nav.append(w)
        root.append(nav)

        grid = MonthGrid()
        grid.add_css_class("cal-grid")
        grid.set(month_grid(year, month), today)
        root.append(grid)

    def tick():
        if dt.date.today() != state["today"]:
            fill()
        return True

    p_.on_build = build
    GLib.timeout_add_seconds(30, tick)
    return p_.run()
