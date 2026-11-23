"""Forecast: the weather for the coming days, from Open-Meteo.

The Windows side's forecast popup (windows/static/zebar/vivac/forecast.js) on
the same source: Open-Meteo, no key, for the place in the weather_location
setting (latitude,longitude), or, set to auto, the place the public IP address
points at; off hides it. The answer is kept in $XDG_RUNTIME_DIR (memory, not
disk, and private to the user), so opening the panel is instant and the bar's
line is read from it; offline, the last answer is shown and said to be old.

The pure half here (parsing, the place, the cache) imports no GTK.
"""
from __future__ import annotations

import json
import math
import os
import re
import tempfile
import time
import urllib.parse
import urllib.request
from dataclasses import dataclass, field
from pathlib import Path

MAX_AGE = 20 * 60  # an answer younger than this is not asked for again
IP_AGE = 6 * 3600  # how long the place the IP points at is kept
NAME_AGE = 7 * 86400
UA = "vivac-panel"


@dataclass(frozen=True)
class Place:
    lat: float
    lon: float
    name: str


@dataclass
class Hour:
    hour: str
    time: str
    temp: int
    rain: int
    condition: str
    glyph: str


@dataclass
class Day:
    date: str
    condition: str
    glyph: str
    high: int
    low: int
    rain: int


@dataclass
class Forecast:
    temp: int
    feels: int
    humidity: int
    wind: int
    condition: str
    glyph: str
    is_day: bool
    rain: int
    uv: int
    sunrise: str
    sunset: str
    hours: list[Hour] = field(default_factory=list)
    days: list[Day] = field(default_factory=list)
    time: str = ""


@dataclass
class Result:
    forecast: Forecast
    stale: bool
    at: int
    place: Place


def _round(x) -> int:
    """JavaScript's Math.round, which the Windows popup uses (.5 goes up)."""
    return int(math.floor(float(x) + 0.5))


def kind(code: int, day: bool = True) -> tuple[str, str]:
    """A WMO weather code as (glyph, condition) -- the groups forecast.js uses."""
    if code == 0:
        return ("\U000F0599" if day else "\U000F0594"), "clear"
    if code <= 2:
        return ("\U000F0595" if day else "\U000F0F31"), "partly"
    if code == 3:
        return "\U000F0590", "cloudy"
    if code <= 48:
        return "\U000F0591", "fog"
    if code <= 57:
        return "\U000F0597", "drizzle"
    if code <= 67:
        return ("\U000F0596" if code >= 65 else "\U000F0597"), "rain"
    if code <= 77 or code in (85, 86):
        return "\U000F0598", "snow"
    if code <= 82:
        return "\U000F0596", "showers"
    return "\U000F067E", "thunder"


def parse(raw: dict) -> Forecast:
    """An Open-Meteo answer (the parameters url() asks for) as a Forecast."""
    c, d, h = raw["current"], raw["daily"], raw.get("hourly") or {}
    is_day = c.get("is_day", 1) == 1
    glyph, condition = kind(int(c["weather_code"]), is_day)

    def daily(name: str, i: int, default=0):
        series = d.get(name) or []
        value = series[i] if i < len(series) else None
        return default if value is None else value

    hours = []
    for i, t in enumerate(h.get("time") or []):
        g, cond = kind(int(h["weather_code"][i]), h["is_day"][i] == 1)
        pp = h["precipitation_probability"][i]
        hours.append(Hour(t[11:13], t, _round(h["temperature_2m"][i]), int(pp or 0), cond, g))
    days = []
    for i, date in enumerate(d["time"]):
        g, cond = kind(int(d["weather_code"][i]), True)
        days.append(Day(date, cond, g, _round(d["temperature_2m_max"][i]), _round(d["temperature_2m_min"][i]),
                        int(daily("precipitation_probability_max", i))))
    return Forecast(
        temp=_round(c["temperature_2m"]), feels=_round(c["apparent_temperature"]),
        humidity=_round(c["relative_humidity_2m"]), wind=_round(c["wind_speed_10m"]),
        condition=condition, glyph=glyph, is_day=is_day,
        rain=int(daily("precipitation_probability_max", 0)), uv=_round(daily("uv_index_max", 0)),
        sunrise=str((d.get("sunrise") or [""])[0])[11:16], sunset=str((d.get("sunset") or [""])[0])[11:16],
        hours=hours, days=days, time=str(c.get("time", "")))


def url(place: Place) -> str:
    q = urllib.parse.urlencode({
        "latitude": place.lat, "longitude": place.lon, "timezone": "auto", "forecast_days": "7",
        "wind_speed_unit": "kmh",
        "current": "temperature_2m,apparent_temperature,relative_humidity_2m,wind_speed_10m,weather_code,is_day",
        "hourly": "temperature_2m,precipitation_probability,weather_code,is_day",
        "daily": "weather_code,temperature_2m_max,temperature_2m_min,precipitation_probability_max,"
                 "sunrise,sunset,uv_index_max",
    })
    return f"https://api.open-meteo.com/v1/forecast?{q}"


def http_json(address: str, timeout: float = 6.0):
    request = urllib.request.Request(address, headers={"User-Agent": UA, "Accept": "application/json"})
    with urllib.request.urlopen(request, timeout=timeout) as response:
        return json.loads(response.read().decode("utf-8", "replace"))


def resolve_place(setting: str, fetch=http_json) -> Place | None:
    """The weather_location setting as a place: lat,lon as given, off as none,
    auto as where the public IP points (ipinfo.io, as the Windows bar asks).
    None also when auto cannot be asked."""
    setting = (setting or "auto").strip()
    if setting == "off":
        return None
    m = re.fullmatch(r"(-?\d{1,2}(?:\.\d+)?),(-?\d{1,3}(?:\.\d+)?)", setting)
    if m:
        lat, lon = float(m.group(1)), float(m.group(2))
        return Place(lat, lon, f"{lat:g}, {lon:g}")
    try:
        r = fetch("https://ipinfo.io/json")
        lat, lon = (float(x) for x in str(r["loc"]).split(","))
        return Place(lat, lon, ", ".join(x for x in (r.get("city"), r.get("region")) if x))
    except (OSError, ValueError, KeyError, TypeError, AttributeError):
        return None


def geo_name(place: Place, lang: str, fetch=http_json) -> str | None:
    """Town and province of a place given by coordinates (OpenStreetMap's
    Nominatim, as the Windows popup does); None when it cannot be asked."""
    q = urllib.parse.urlencode({"format": "json", "zoom": 10, "accept-language": lang,
                                "lat": place.lat, "lon": place.lon})
    try:
        a = fetch(f"https://nominatim.openstreetmap.org/reverse?{q}").get("address") or {}
    except (OSError, ValueError, AttributeError):
        return None
    name = ", ".join(x for x in (a.get("city") or a.get("town") or a.get("village") or a.get("municipality"),
                                 a.get("state") or a.get("province")) if x)
    return name or None


# ---- the cache ------------------------------------------------------------

def cache_path() -> Path:
    from .kit import runtime_dir
    return Path(os.environ.get("VIVAC_FORECAST_CACHE") or runtime_dir() / "vivac-forecast.json")


def _read_cache() -> dict:
    try:
        data = json.loads(cache_path().read_text(encoding="utf-8"))
        return data if isinstance(data, dict) else {}
    except (OSError, ValueError):
        return {}


def _write_cache(data: dict) -> None:
    path = cache_path()
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        fd, tmp = tempfile.mkstemp(dir=path.parent, prefix=".vivac-forecast.")
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            json.dump(data, f)
        os.chmod(tmp, 0o600)
        os.replace(tmp, path)
    except OSError:
        pass


def save_cache(place: Place, raw: dict, now: int | None = None) -> None:
    data = _read_cache()
    data.update({"at": int(time.time() if now is None else now),
                 "place": {"lat": place.lat, "lon": place.lon, "name": place.name}, "data": raw})
    _write_cache(data)


def cached(place: Place | None = None) -> Result | None:
    """The last answer kept, if it is for this place (any place when None);
    always marked stale: the caller decides what is old."""
    data = _read_cache()
    try:
        p = data["place"]
        kept = Place(float(p["lat"]), float(p["lon"]), str(p.get("name", "")))
        if place is not None and (kept.lat, kept.lon) != (place.lat, place.lon):
            return None
        return Result(parse(data["data"]), True, int(data["at"]), kept)
    except (KeyError, TypeError, ValueError, IndexError):
        return None


def load(place: Place, fetch=http_json, now: int | None = None, force: bool = False) -> Result | None:
    """The forecast for a place: the cache when it is younger than MAX_AGE,
    otherwise a fresh answer (kept), otherwise the old cache marked stale,
    otherwise None."""
    now = int(time.time() if now is None else now)
    old = cached(place)
    if old and not force and now - old.at < MAX_AGE:
        old.stale = False
        return old
    try:
        raw = fetch(url(place))
        forecast = parse(raw)
    except (OSError, ValueError, KeyError, TypeError, IndexError):
        return old
    keep = place
    if old and old.place.name and old.place.name != f"{place.lat:g}, {place.lon:g}" and not place.name.strip():
        keep = old.place
    save_cache(keep, raw, now)
    return Result(forecast, False, now, keep)


def saved_place(setting: str, now: int | None = None) -> Place | None:
    """The place without asking anyone: coordinates as given (with the town's
    name when it was looked up once), the IP's place as kept."""
    now = int(time.time() if now is None else now)
    data = _read_cache()
    base = resolve_place(setting, lambda _u: (_ for _ in ()).throw(OSError("offline")))
    if base is not None:
        names = data.get("names") or {}
        hit = names.get(f"{base.lat},{base.lon}")
        return Place(base.lat, base.lon, hit["name"]) if hit and now - hit["at"] < NAME_AGE else base
    auto = data.get("auto")
    if setting.strip() in ("", "auto") and auto and now - auto.get("at", 0) < IP_AGE:
        a = auto["place"]
        return Place(a["lat"], a["lon"], a.get("name", ""))
    return None


def current_place(setting: str, lang: str, fetch=http_json, now: int | None = None) -> Place | None:
    """saved_place, asking (and keeping the answer) when it has to."""
    now = int(time.time() if now is None else now)
    place = saved_place(setting, now)
    if place is not None and (place.name != f"{place.lat:g}, {place.lon:g}" or setting.strip() == "auto"
                              or not setting.strip()):
        return place
    data = _read_cache()
    if place is not None:  # coordinates without a town yet
        name = geo_name(place, lang, fetch)
        if name:
            data.setdefault("names", {})[f"{place.lat},{place.lon}"] = {"at": now, "name": name}
            _write_cache(data)
            return Place(place.lat, place.lon, name)
        return place
    found = resolve_place(setting, fetch)
    if found is not None:
        data["auto"] = {"at": now, "place": {"lat": found.lat, "lon": found.lon, "name": found.name}}
        _write_cache(data)
    return found


# ---- the bar ---------------------------------------------------------------

def waybar(args: list[str]) -> int:
    """One line of JSON for the bar's weather module: the glyph and the
    temperature, the days in the tooltip. Hidden (empty text) when the weather
    is off or nothing can be known."""
    from .calendar import names
    from .kit import SETTINGS, T, session_language

    lang = session_language(SETTINGS)
    setting = SETTINGS.get("weather_location", "auto")
    out = {"text": "", "tooltip": "", "class": ""}
    place = current_place(setting, lang) if setting != "off" else None
    result = load(place) if place else None
    if result:
        f = result.forecast
        wd = names(lang).weekdays_short
        lines = [f"{result.place.name}  ·  {T('fc.cond.' + f.condition)}, {f.temp}° ({T('fc.feels')} {f.feels}°)"]
        for i, d in enumerate(f.days):
            import datetime as dt
            label = T("fc.today") if i == 0 else wd[dt.date.fromisoformat(d.date).weekday()].capitalize()
            lines.append(f"{label}  {d.glyph}  {d.low}° / {d.high}°" + (f"  {d.rain}%" if d.rain else ""))
        out = {"text": f"{f.glyph} {f.temp}°C", "tooltip": "\n".join(lines),
               "class": [f.condition, "stale"] if result.stale else f.condition}
    print(json.dumps(out, ensure_ascii=False))
    return 0


# ---- derived readings the redesigned panel draws --------------------------

def hm_minutes(text: str) -> int | None:
    """"08:10" as minutes since midnight; None when it is not a clock time."""
    m = re.fullmatch(r"(\d{1,2}):(\d{2})", (text or "").strip())
    if not m or int(m.group(1)) > 23 or int(m.group(2)) > 59:
        return None
    return int(m.group(1)) * 60 + int(m.group(2))


def sun_state(now: str, sunrise: str, sunset: str) -> tuple[str, float, int]:
    """Where the sun is: ("day", fraction of the daylight gone, minutes left),
    ("before", 0, minutes to sunrise), ("after", 1, 0), or ("unknown", 0, 0)
    when a time is missing. All three are clock times of the place."""
    n, a, b = hm_minutes(now), hm_minutes(sunrise), hm_minutes(sunset)
    if n is None or a is None or b is None or b <= a:
        return "unknown", 0.0, 0
    if n < a:
        return "before", 0.0, a - n
    if n >= b:
        return "after", 1.0, 0
    return "day", (n - a) / (b - a), b - n


def uv_level(uv: int) -> str:
    """The WHO band of a UV index: low, moderate, high, very_high, extreme."""
    return "low" if uv <= 2 else "moderate" if uv <= 5 else "high" if uv <= 7 else "very_high" if uv <= 10 else "extreme"


def week_scale(days: list) -> tuple[int, int]:
    """The temperature span the week's bars share: the lowest low and the
    highest high, a degree beyond each so no bar touches the end."""
    if not days:
        return 0, 1
    return min(d.low for d in days) - 1, max(d.high for d in days) + 1


# ---- the panel -------------------------------------------------------------

def main() -> int:
    import datetime as dt
    import threading

    from .calendar import names
    from .gfx import helpers
    from .kit import SETTINGS, T, gtk_kit, mix, session_language

    lang = session_language(SETTINGS)
    setting = SETTINGS.get("weather_location", "auto")
    k = gtk_kit()
    Gtk, Gdk, GLib = k.Gtk, k.Gdk, k.GLib
    panel = k.Panel("forecast", "\U000F0595", T("fc.title"), "",
                    hints=[("R", T("fc.key.refresh")), ("Esc", T("fc.key.close"))], width=560)
    state = {"busy": False, "result": None, "error": None}
    pal = dict(panel.p)
    pal["infoSoft"] = mix(pal["bg"], pal["info"], 0.18)
    pal["lineStrong"] = mix(pal["bg"], pal["text"], 0.4)
    g = helpers(Gtk, pal)
    rgb, text, rounded, curve = g.rgb, g.text, g.rounded, g.curve

    class SunArc(Gtk.DrawingArea):
        """The sun's day: a dashed half circle from sunrise to sunset, the part
        gone solid, the sun where it is now, the time left in the middle."""

        def __init__(self) -> None:
            super().__init__()
            self.set_content_width(200)
            self.set_content_height(132)
            self.set_valign(Gtk.Align.CENTER)
            self.info = ("unknown", 0.0, "", "", "", "")  # state, fraction, headline, value, rise, set
            self.set_draw_func(self._draw)

        def set(self, info) -> None:
            self.info = info
            self.queue_draw()

        def _draw(self, _a, cr, w, h) -> None:
            import math
            mode, frac, head, value, rise, sett = self.info
            cx, cy, r = w / 2, 96, 82
            cr.set_line_width(1)
            cr.set_source_rgba(*rgb(pal["line"]))
            cr.move_to(6, cy + 0.5)
            cr.line_to(w - 6, cy + 0.5)
            cr.stroke()
            cr.set_line_cap(1)
            cr.set_line_width(2)
            cr.set_dash([2, 5])
            cr.set_source_rgba(*rgb(pal["lineStrong"]))
            cr.arc(cx, cy, r, math.pi, 2 * math.pi)
            cr.stroke()
            cr.set_dash([])
            if mode in ("day", "after") and frac > 0:
                cr.set_line_width(3)
                cr.set_source_rgba(*rgb(pal["accent"]))
                cr.arc(cx, cy, r, math.pi, math.pi + math.pi * frac)
                cr.stroke()
            if mode == "day":
                sx, sy = cx - r * math.cos(math.pi * frac), cy - r * math.sin(math.pi * frac)
                cr.arc(sx, sy, 12, 0, 2 * math.pi)
                cr.set_source_rgba(*rgb(pal["accent"], 0.22))
                cr.fill()
                cr.arc(sx, sy, 8.5, 0, 2 * math.pi)
                cr.set_source_rgba(*rgb(pal["surface"]))
                cr.fill()
                cr.arc(sx, sy, 6.5, 0, 2 * math.pi)
                cr.set_source_rgba(*rgb(pal["accent"]))
                cr.fill()
            if head:
                text(cr, head, cx, 66, 11, pal["textSecondary"], anchor="middle")
            if value:
                text(cr, value, cx, 84, 15, pal["text"], bold=True, anchor="middle")
            text(cr, rise, 0, 112, 12, pal["text"], bold=True)
            text(cr, sett, w, 112, 12, pal["text"], bold=True, anchor="end")
            text(cr, T("fc.sunrise").lower(), 0, 126, 11, pal["textSecondary"])
            text(cr, T("fc.sunset").lower(), w, 126, 11, pal["textSecondary"], anchor="end")

    class HourCurve(Gtk.DrawingArea):
        """The next hours: an icon over each, the temperature on a smooth line
        over a fading fill, the hour under, the chance of rain when it matters."""

        def __init__(self) -> None:
            super().__init__()
            self.set_content_height(148)
            self.set_hexpand(True)
            self.hours: list = []
            self.set_draw_func(self._draw)

        def set(self, hours) -> None:
            self.hours = hours
            self.queue_draw()

        def _draw(self, _a, cr, w, h) -> None:
            import cairo
            hs = self.hours
            if not hs:
                return
            step = w / len(hs)
            lo, hi = min(x.temp for x in hs), max(x.temp for x in hs)
            ys = [79.0 if hi == lo else 100.0 - (x.temp - lo) / (hi - lo) * 42.0 for x in hs]
            pts = [(step * (i + 0.5), ys[i]) for i in range(len(hs))]
            if len(pts) > 1:
                curve(cr, pts)
                cr.set_line_join(1)
                line = cr.copy_path()
                cr.line_to(pts[-1][0], 112)
                cr.line_to(pts[0][0], 112)
                cr.close_path()
                grad = cairo.LinearGradient(0, 40, 0, 112)
                grad.add_color_stop_rgba(0, *rgb(pal["accent"], 0.35))
                grad.add_color_stop_rgba(1, *rgb(pal["accent"], 0.0))
                cr.set_source(grad)
                cr.fill()
                cr.new_path()
                cr.append_path(line)
                cr.set_line_width(2.2)
                cr.set_source_rgba(*rgb(pal["accent"]))
                cr.stroke()
            import math
            for i, (x, y) in enumerate(pts):
                hr = hs[i]
                cr.arc(x, y, 5 if i == 0 else 3.5, 0, 2 * math.pi)
                cr.set_source_rgba(*rgb(pal["accent"] if i == 0 else pal["surface"]))
                cr.fill_preserve()
                cr.set_line_width(2)
                cr.set_source_rgba(*rgb(pal["accent"]))
                cr.stroke()
                text(cr, f"{hr.temp}°", x, y - 12, 13, pal["text"], bold=True, anchor="middle")
                text(cr, hr.glyph, x, 15, 22, pal["accent"], anchor="middle")
                if hr.rain >= 20:
                    text(cr, f"{hr.rain}%", x, 125, 10, pal["info"], bold=hr.rain >= 50, anchor="middle")
                text(cr, hr.hour + "h", x, 140, 12, pal["textSecondary"], anchor="middle")

    class RangeBar(Gtk.DrawingArea):
        """A day's low to high on the week's shared scale, a gradient from
        cool to warm; today also marks the temperature now."""

        def __init__(self) -> None:
            super().__init__()
            self.set_content_height(12)
            self.set_hexpand(True)
            self.set_valign(Gtk.Align.CENTER)
            self.spec = (0, 1, 0, 1, None)
            self.set_draw_func(self._draw)

        def set(self, low, high, lo, hi, now=None) -> None:
            self.spec = (low, high, lo, hi, now)
            self.queue_draw()

        def _draw(self, _a, cr, w, h) -> None:
            import cairo
            import math
            low, high, lo, hi, now = self.spec
            span = max(1, hi - lo)
            ty = (h - 6) / 2
            rounded(cr, 0, ty, w, 6, 3)
            cr.set_source_rgba(*rgb(pal["bg"]))
            cr.fill()
            x0, x1 = w * (low - lo) / span, w * (high - lo) / span
            grad = cairo.LinearGradient(x0, 0, max(x1, x0 + 1), 0)
            grad.add_color_stop_rgba(0, *rgb(pal["info"]))
            grad.add_color_stop_rgba(1, *rgb(pal["accent"]))
            rounded(cr, x0, ty, max(6.0, x1 - x0), 6, 3)
            cr.set_source(grad)
            cr.fill()
            if now is not None:
                x = min(max(w * (now - lo) / span, 6), w - 6)
                cr.arc(x, h / 2, 8, 0, 2 * math.pi)
                cr.set_source_rgba(*rgb(pal["surface"]))
                cr.fill()
                cr.arc(x, h / 2, 6, 0, 2 * math.pi)
                cr.set_source_rgba(*rgb(pal["text"]))
                cr.fill()

    def style() -> None:
        p = pal
        css = f"""
.vivac .fc-refresh {{ background: {p['surface']}; color: {p['textSecondary']}; border-radius: 10px; border: none;
  box-shadow: none; padding: 0 10px; min-height: 30px; font-size: 12px; }}
.vivac .fc-refresh:hover {{ background: {p['surfaceAlt']}; color: {p['text']}; }}
.vivac .fc-card {{ background: {p['surface']}; border-radius: 12px; padding: 14px; }}
.vivac .fc-hero {{ background: {p['surface']}; border-radius: 12px; padding: 16px; }}
.vivac .fc-glyph-big {{ font-size: 80px; color: {p['accent']}; min-width: 92px; }}
.vivac .fc-temp {{ font-size: 60px; font-weight: 700; color: {p['text']}; letter-spacing: -2px; }}
.vivac .fc-cond {{ font-size: 15px; font-weight: 700; color: {p['text']}; }}
.vivac .fc-feels {{ font-size: 12px; color: {p['textSecondary']}; }}
.vivac .fc-stat {{ background: {p['surface']}; border-radius: 12px; padding: 10px 12px; }}
.vivac .fc-stat-k {{ font-size: 11px; letter-spacing: 1px; font-weight: 700; color: {p['textSecondary']}; }}
.vivac .fc-stat-g {{ font-size: 13px; color: {p['accent']}; }}
.vivac .fc-stat-v {{ font-size: 19px; font-weight: 700; color: {p['text']}; }}
.vivac .fc-stat-u {{ font-size: 12px; color: {p['textSecondary']}; }}
.vivac .fc-uv {{ min-height: 6px; border-radius: 2px; background: {p['surfaceAlt']}; }}
.vivac .fc-uv.on {{ background: {p['accent']}; }}
.vivac .fc-sec {{ font-size: 12px; letter-spacing: 1px; font-weight: 700; color: {p['muted']}; }}
.vivac .fc-count {{ font-size: 12px; font-weight: 700; color: {p['text']}; }}
.vivac .fc-note {{ font-size: 12px; color: {p['textSecondary']}; }}
.vivac .fc-day {{ border-radius: 10px; padding: 0 10px; min-height: 32px; }}
.vivac .fc-day.today {{ background: {p['surfaceAlt']}; }}
.vivac .fc-day-n {{ font-size: 13px; color: {p['text']}; }}
.vivac .fc-day.today .fc-day-n {{ font-weight: 700; color: {p['accent']}; }}
.vivac .fc-day-g {{ font-size: 18px; color: {p['accent']}; }}
.vivac .fc-day-c {{ font-size: 12px; color: {p['textSecondary']}; }}
.vivac .fc-day-lo {{ font-size: 12px; color: {p['textSecondary']}; }}
.vivac .fc-day-hi {{ font-size: 13px; font-weight: 700; color: {p['text']}; }}
.vivac .fc-rain {{ font-size: 11px; font-weight: 700; border-radius: 10px; padding: 0 7px; min-height: 20px;
  background: {p['surfaceAlt']}; color: {p['text']}; }}
.vivac .fc-rain.wet {{ background: {p['infoSoft']}; color: {p['info']}; }}
.vivac .fc-key {{ font-size: 12px; color: {p['text']}; background: {p['bg']}; border-radius: 7px; padding: 1px 8px;
  box-shadow: inset 0 0 0 1px {p['line']}; }}
"""
        prov = Gtk.CssProvider()
        prov.load_from_string(css)
        Gtk.StyleContext.add_provider_for_display(Gdk.Display.get_default(), prov,
                                                  Gtk.STYLE_PROVIDER_PRIORITY_USER)

    def label(text_: str, *classes: str, xalign: float = 0.5, **kw):
        w = Gtk.Label(label=text_, xalign=xalign, **kw)
        for c in classes:
            w.add_css_class(c)
        return w

    def message(text_: str):
        return label(text_, "empty", xalign=0, wrap=True)

    def clear(box) -> None:
        child = box.get_first_child()
        while child:
            nxt = child.get_next_sibling()
            box.remove(child)
            child = nxt

    def vbox(spacing: int = 0, *classes: str, **kw):
        b = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=spacing, **kw)
        for c in classes:
            b.add_css_class(c)
        return b

    def section(title: str, count: int, note: str):
        row = Gtk.Box(spacing=8)
        row.append(label(title.upper(), "fc-sec", xalign=0))
        row.append(label(str(count), "fc-count", xalign=0))
        row.append(label(note, "fc-note", xalign=1, hexpand=True))
        return row

    def minutes_text(m: int) -> str:
        return T("fc.hm", m // 60, m % 60) if m >= 60 else T("fc.min_only", m)

    def stat(glyph: str, key: str, value: str, unit: str, bar=None, extra=None):
        card = vbox(6, "fc-stat", hexpand=True)
        head = Gtk.Box(spacing=6)
        head.append(label(glyph, "fc-stat-g"))
        head.append(label(key.upper(), "fc-stat-k"))
        card.append(head)
        val = Gtk.Box(spacing=4)
        val.append(label(value, "fc-stat-v"))
        val.append(label(unit, "fc-stat-u", valign=Gtk.Align.END))
        val.get_last_child().set_margin_bottom(2)
        card.append(val)
        if bar is not None:
            b = g.Bar("info")
            b.set(bar)
            card.append(b)
        if extra is not None:
            card.append(extra)
        return card

    def draw() -> None:
        root = state["root"]
        clear(root)
        r, err = state["result"], state["error"]
        if setting == "off":
            panel.subtitle.set_label("")
            root.append(message(T("fc.disabled")))
            return
        if r is None:
            panel.subtitle.set_label(T("fc.loading") if state["busy"] else "")
            if not state["busy"]:
                root.append(message(T(err or "fc.unavailable")))
            return
        f = r.forecast
        stamp_text = time.strftime("%H:%M", time.localtime(r.at))
        panel.subtitle.set_label(f"{r.place.name} · {T('fc.stale_at', stamp_text) if r.stale else T('fc.updated', stamp_text)}")
        content = vbox(10)

        # hero: the weather now, and where the sun is
        hero = Gtk.Box(spacing=18)
        hero.add_css_class("fc-hero")
        hero.append(label(f.glyph, "fc-glyph-big"))
        col = vbox(2, valign=Gtk.Align.CENTER, hexpand=True)
        col.append(label(f"{f.temp}°", "fc-temp", xalign=0))
        col.append(label(T("fc.cond." + f.condition), "fc-cond", xalign=0))
        col.append(label(f"{T('fc.feels')} {f.feels}°", "fc-feels", xalign=0))
        if r.stale:
            col.append(k.badge(T("fc.offline"), "warn"))
            col.get_last_child().set_halign(Gtk.Align.START)
            col.get_last_child().set_margin_top(4)
        hero.append(col)
        now_hm = f.time[11:16] if len(f.time) >= 16 else time.strftime("%H:%M")
        mode, frac, left = sun_state(now_hm, f.sunrise, f.sunset)
        head, value = ("", "")
        if mode == "day":
            head, value = T("fc.sun_left"), minutes_text(left)
        elif mode == "before":
            head, value = T("fc.sun_in"), minutes_text(left)
        elif mode == "after":
            head, value = "", T("fc.night")
        arc = SunArc()
        arc.set((mode, frac, head, value, f.sunrise or "-", f.sunset or "-"))
        hero.append(arc)
        content.append(hero)

        # four cards: humidity, wind, rain, UV
        cards = Gtk.Box(spacing=8, homogeneous=True)
        level = uv_level(f.uv)
        segs = Gtk.Box(spacing=2, homogeneous=True)
        for i in range(11):
            s = Gtk.Box()
            s.add_css_class("fc-uv")
            if i < f.uv:
                s.add_css_class("on")
            segs.append(s)
        cards.append(stat("\U000F058C", T("fc.humidity"), str(f.humidity), "%", bar=f.humidity / 100))
        cards.append(stat("\U000F059D", T("fc.wind"), str(f.wind), "km/h", bar=f.wind / 50))
        cards.append(stat("\U000F0597", T("fc.rain"), str(f.rain), "%", bar=f.rain / 100))
        cards.append(stat("\U000F0599", "UV", str(f.uv), T("fc.uv." + level), extra=segs))
        content.append(cards)

        # the next hours
        stamp = f.time[:13] if len(f.time) >= 13 else time.strftime("%Y-%m-%dT%H")
        i0 = next((i for i, h in enumerate(f.hours) if h.time[:13] == stamp), 0)
        coming = f.hours[i0 + 1:i0 + 9]
        if coming:
            card = vbox(6, "fc-card")
            card.append(section(T("fc.next_hours"), len(coming), T("fc.temp_c")))
            curve_w = HourCurve()
            curve_w.set(coming)
            card.append(curve_w)
            content.append(card)

        # the week
        card = vbox(6, "fc-card")
        card.set_margin_bottom(0)
        card.append(section(T("fc.week"), len(f.days), T("fc.range")))
        lo, hi = week_scale(f.days)
        for i, d in enumerate(f.days):
            name = T("fc.today") if i == 0 else names(lang).weekdays[dt.date.fromisoformat(d.date).weekday()].capitalize()
            row = Gtk.Box(spacing=8)
            row.add_css_class("fc-day")
            if i == 0:
                row.add_css_class("today")
            n = label(name, "fc-day-n", xalign=0)
            n.set_size_request(82, -1)
            row.append(n)
            gl = label(d.glyph, "fc-day-g")
            gl.set_size_request(22, -1)
            row.append(gl)
            c = label(T("fc.cond." + d.condition), "fc-day-c", xalign=0, ellipsize=3)
            c.set_size_request(80, -1)
            row.append(c)
            slot = Gtk.Box(halign=Gtk.Align.END)
            slot.set_size_request(50, -1)
            if d.rain:
                pill = label(("\U000F058C " if True else "") + f"{d.rain}%", "fc-rain", valign=Gtk.Align.CENTER)
                if d.rain >= 50:
                    pill.add_css_class("wet")
                slot.append(pill)
            row.append(slot)
            low_l = label(f"{d.low}°", "fc-day-lo", xalign=1)
            low_l.set_size_request(24, -1)
            row.append(low_l)
            rb = RangeBar()
            rb.set(d.low, d.high, lo, hi, f.temp if i == 0 else None)
            row.append(rb)
            hi_l = label(f"{d.high}°", "fc-day-hi", xalign=1)
            hi_l.set_size_request(30, -1)
            row.append(hi_l)
            card.append(row)
        content.append(card)
        root.append(k.scroller(content, 840))

    def refresh(force: bool = False) -> None:
        if state["busy"] or setting == "off":
            return
        state["busy"] = True

        def work():
            place = current_place(setting, lang)
            result = load(place, force=force) if place else None
            error = None if place else ("fc.no_place" if setting.strip() in ("", "auto") else "fc.unavailable")

            def done():
                state["busy"] = False
                if result is not None:
                    state["result"], state["error"] = result, None
                elif state["result"] is None:
                    state["error"] = error or "fc.unavailable"
                draw()
                return False
            GLib.idle_add(done)
        threading.Thread(target=work, daemon=True).start()

    def build(_panel):
        style()
        root = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=4)
        root.set_margin_top(12)
        state["root"] = root
        btn = Gtk.Button()
        inner = Gtk.Box(spacing=8)
        inner.append(Gtk.Label(label="\U000F0450"))
        inner.append(label("R", "fc-key"))
        btn.set_child(inner)
        btn.add_css_class("fc-refresh")
        btn.set_tooltip_text(T("fc.key.refresh"))
        btn.connect("clicked", lambda *_: refresh(force=True))
        panel.header_end.append(btn)
        place = saved_place(setting)
        state["result"] = cached(place) if place else None
        if state["result"] is not None:
            # What is kept shows at once; it is asked again only when it is old.
            state["result"].stale = int(time.time()) - state["result"].at >= MAX_AGE
        draw()
        if state["result"] is None or state["result"].stale:
            refresh()
        GLib.idle_add(attach)
        return root

    def attach():
        win = panel.window
        if win is None:
            return True
        keys = Gtk.EventControllerKey()
        keys.set_propagation_phase(Gtk.PropagationPhase.CAPTURE)

        def pressed(_c, keyval, _code, _st):
            if keyval in (Gdk.KEY_r, Gdk.KEY_R, Gdk.KEY_F5):
                refresh(force=True)
                return True
            return False
        keys.connect("key-pressed", pressed)
        win.add_controller(keys)
        return False

    panel.on_build = build
    return panel.run()
