#!/usr/bin/env bash
set -Eeuo pipefail

# vivac-panel forecast, its backend without a display or a network: an
# Open-Meteo answer saved here is parsed into now + days (rounded, WMO codes
# grouped into a condition), the place comes from the weather_location setting
# (coordinates as they are, off = none, auto = the public IP through a fetcher),
# the answer is cached so opening again is instant, offline falls back to the
# last cache and says it is stale, and the bar's line is read from the cache.

repo_root="${REPO_ROOT:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)}"
fail() {
	printf '%s\n' "$1" >&2
	exit 1
}
sandbox="$(mktemp -d "${TMPDIR:-/tmp}/vivac-forecast.XXXXXX")"
trap 'rm -rf -- "$sandbox"' EXIT
mkdir -p "$sandbox/run" "$sandbox/cfg/vivac"
export XDG_RUNTIME_DIR="$sandbox/run" XDG_CONFIG_HOME="$sandbox/cfg" VIVAC_LANG=en
export VIVAC_NO_NET=1 VIVAC_FORECAST_CACHE="$sandbox/cache.json"
export SETTINGS_FILE="$sandbox/cfg/vivac/settings"

# A made-up place and a short week: three days, a few hours.
cat >"$sandbox/sample.json" <<'JSON'
{"current":{"temperature_2m":12.4,"apparent_temperature":10.6,"relative_humidity_2m":71,"wind_speed_10m":14.2,"weather_code":61,"is_day":1,"time":"2026-11-23T10:00"},
 "hourly":{"time":["2026-11-23T10:00","2026-11-23T11:00","2026-11-23T12:00"],"temperature_2m":[12.4,13.1,14.0],"precipitation_probability":[80,60,10],"weather_code":[61,3,0],"is_day":[1,1,1]},
 "daily":{"time":["2026-11-23","2026-11-24","2026-11-25"],"weather_code":[61,0,95],"temperature_2m_max":[14.0,17.5,11.2],"temperature_2m_min":[8.1,6.0,7.5],"precipitation_probability_max":[80,5,90],"sunrise":["2026-11-23T08:01","2026-11-24T08:02","2026-11-25T08:03"],"sunset":["2026-11-23T17:50","2026-11-24T17:49","2026-11-25T17:48"],"uv_index_max":[1.6,2.4,1.0]}}
JSON
export SAMPLE="$sandbox/sample.json"

out="$(/usr/bin/python3 - "$repo_root/lib" <<'PY'
import json, os, sys, time
sys.path.insert(0, sys.argv[1])
from vivacpanel import forecast as f
raw = json.load(open(os.environ["SAMPLE"]))
fc = f.parse(raw)
print("now", fc.temp, fc.feels, fc.condition, fc.humidity, fc.wind, fc.is_day)
print("days", [(d.date, d.condition, d.high, d.low, d.rain) for d in fc.days])
print("facts", fc.rain, fc.uv, fc.sunrise, fc.sunset)
print("hours", [(h.hour, h.temp, h.rain, h.condition) for h in fc.hours])
print("kind", f.kind(0, True)[1], f.kind(0, False)[1], f.kind(3, True)[1], f.kind(45, True)[1], f.kind(53, True)[1],
      f.kind(66, True)[1], f.kind(73, True)[1], f.kind(81, True)[1], f.kind(99, True)[1])
print("glyph", f.kind(0, True)[0] != f.kind(0, False)[0])
print("place coords", f.resolve_place("1.5,-2.25", None))
print("place off", f.resolve_place("off", None))
print("place auto", f.resolve_place("auto", lambda url: {"loc": "1.5,2.5", "city": "Testville", "region": "TS"}))
def offline(url):
    raise OSError("no network")
print("place auto offline", f.resolve_place("auto", offline))
place = f.Place(1.5, 2.5, "Testville, TS")
calls = []
def fetcher(url):
    calls.append(url)
    return raw
r = f.load(place, fetcher, now=1000)
print("first", r.stale, len(calls), r.forecast.temp, r.at)
r = f.load(place, fetcher, now=1000 + 600)
print("cached", r.stale, len(calls))
r = f.load(place, fetcher, now=1000 + 3600)
print("refetched", r.stale, len(calls))
r = f.load(place, offline, now=1000 + 7200)
print("offline", r.stale, r.forecast.temp, r.at)
r = f.load(f.Place(9.0, 9.0, "Elsewhere"), offline, now=1000 + 7200)
print("other place offline", r)
print("url", "latitude=1.5" in f.url(place), "forecast_days=7" in f.url(place), "timezone=auto" in f.url(place))
print("cache perms", oct(os.stat(os.environ["VIVAC_FORECAST_CACHE"]).st_mode & 0o777))
print("sun", f.sun_state("12:07", "08:10", "17:52"), f.sun_state("06:00", "08:10", "17:52"),
      f.sun_state("18:00", "08:10", "17:52"), f.sun_state("", "08:10", "17:52"), f.sun_state("12:00", "17:00", "08:00"))
print("uv", [f.uv_level(n) for n in (0, 2, 3, 5, 6, 7, 8, 10, 11, 14)])
print("scale", f.week_scale([f.Day("d", "c", "g", 13, 2, 0), f.Day("d", "c", "g", 10, 1, 0)]), f.week_scale([]))
print("hm", f.hm_minutes("08:10"), f.hm_minutes("24:00"), f.hm_minutes("x"))
PY
)"
grep -qF "now 12 11 rain 71 14 True" <<<"$out" || fail "current conditions: $out"
grep -qF "days [('2026-11-23', 'rain', 14, 8, 80), ('2026-11-24', 'clear', 18, 6, 5), ('2026-11-25', 'thunder', 11, 8, 90)]" <<<"$out" || fail "days: $out"
grep -qF "facts 80 2 08:01 17:50" <<<"$out" || fail "facts: $out"
grep -qF "hours [('10', 12, 80, 'rain'), ('11', 13, 60, 'cloudy'), ('12', 14, 10, 'clear')]" <<<"$out" || fail "hours: $out"
grep -qF "kind clear clear cloudy fog drizzle rain snow showers thunder" <<<"$out" || fail "WMO grouping: $out"
grep -qF "glyph True" <<<"$out" || fail "day and night glyphs must differ: $out"
grep -qF "place coords Place(lat=1.5, lon=-2.25, name='1.5, -2.25')" <<<"$out" || fail "coordinates setting: $out"
grep -qF "place off None" <<<"$out" || fail "off must give no place: $out"
grep -qF "place auto Place(lat=1.5, lon=2.5, name='Testville, TS')" <<<"$out" || fail "auto place: $out"
grep -qF "place auto offline None" <<<"$out" || fail "auto offline: $out"
grep -qF "first False 1 12 1000" <<<"$out" || fail "first load: $out"
grep -qF "cached False 1" <<<"$out" || fail "a fresh cache must not ask again: $out"
grep -qF "refetched False 2" <<<"$out" || fail "an old cache must be refreshed: $out"
grep -qF "offline True 12 4600" <<<"$out" || fail "offline must fall back to the last cache, stale: $out"
grep -qF "other place offline None" <<<"$out" || fail "a cache of another place must not be shown: $out"
grep -qF "url True True True" <<<"$out" || fail "request parameters: $out"
grep -qF "cache perms 0o600" <<<"$out" || fail "cache must be private: $out"

# The bar's line comes from the cache, with the place set by coordinates.
printf 'weather_location=1.5,2.5\n' >"$SETTINGS_FILE"
/usr/bin/python3 - "$repo_root/lib" <<'PY'
import json, os, sys, time
sys.path.insert(0, sys.argv[1])
from vivacpanel import forecast as f
raw = json.load(open(os.environ["SAMPLE"]))
f.save_cache(f.Place(1.5, 2.5, "1.5, 2.5"), raw, int(time.time()))
PY
line="$(/usr/bin/python3 "$repo_root/dotfiles/ricer/.local/bin/vivac-panel" waybar forecast)"
/usr/bin/python3 -c 'import json,sys; d=json.loads(sys.argv[1]); assert "12°" in d["text"], d; assert d["class"] == "rain", d; assert "Today" in d["tooltip"] and "14°" in d["tooltip"], d' "$line" || fail "waybar line: $line"
printf 'weather_location=off\n' >"$SETTINGS_FILE"
line="$(/usr/bin/python3 "$repo_root/dotfiles/ricer/.local/bin/vivac-panel" waybar forecast)"
/usr/bin/python3 -c 'import json,sys; d=json.loads(sys.argv[1]); assert d["text"] == "", d' "$line" || fail "off must hide the module: $line"
grep -qF "('day', 0.4072164948453608, 345) ('before', 0.0, 130) ('after', 1.0, 0) ('unknown', 0.0, 0) ('unknown', 0.0, 0)" <<<"$out" || fail "sun before, after, unknown: $out"
grep -qF "uv ['low', 'low', 'moderate', 'moderate', 'high', 'high', 'very_high', 'very_high', 'extreme', 'extreme']" <<<"$out" || fail "UV bands: $out"
grep -qF "scale (0, 14) (0, 1)" <<<"$out" || fail "the week's bars share one scale: $out"
grep -qF "hm 490 None None" <<<"$out" || fail "clock times: $out"
printf 'ok: forecast panel backend\n'
