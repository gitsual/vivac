#!/usr/bin/env bash
set -Eeuo pipefail

# vivac-panel calendar, its backend without a display: the grid of a known
# month starts on Monday and always has six weeks, each with its ISO number
# (January 2027 opens in week 53 of 2026), the days of the neighbouring months
# are marked as not belonging, names follow the session language, and moving
# a month crosses the year.

repo_root="${REPO_ROOT:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)}"
fail() {
	printf '%s\n' "$1" >&2
	exit 1
}

out="$(/usr/bin/python3 - "$repo_root/lib" <<'PY'
import sys, datetime
sys.path.insert(0, sys.argv[1])
from vivacpanel import calendar as c
weeks = c.month_grid(2027, 1)
print("rows", len(weeks), [len(w.days) for w in weeks])
print("first", weeks[0].number, weeks[0].days[0].date, weeks[0].days[0].in_month, weeks[0].days[4].date, weeks[0].days[4].in_month)
print("second", weeks[1].number, weeks[1].days[0].date)
print("last", weeks[5].number, weeks[5].days[6].date)
print("weekend", [d.weekend for d in weeks[0].days])
feb = c.month_grid(2026, 2)  # starts on a Sunday: its first row is January's tail
print("feb", feb[0].days[0].date, feb[0].days[6].date, feb[0].days[6].in_month)
print("today", [d.date.isoformat() for w in c.month_grid(2026, 11) for d in w.days if d.date == datetime.date(2026, 11, 23)])
print("shift", c.shift_month(2026, 12, 1), c.shift_month(2027, 1, -1), c.shift_month(2026, 5, -1))
print("es", c.names("es").months[10], c.names("es").weekdays_short[0], c.long_date(datetime.date(2026, 11, 23), "es"))
print("en", c.names("en").months[10], c.names("en").weekdays_short[6], c.long_date(datetime.date(2026, 11, 23), "en"))
print("xx", c.names("xx").months[0])
print("weekday", c.weekday_name(datetime.date(2026, 11, 23), "es"))
yd, ytot, yleft, ym = c.year_progress(datetime.date(2026, 11, 23))
print("year", yd, ytot, yleft, ym[:10] == [1.0] * 10, round(ym[10], 3), ym[11])
print("leap", c.year_progress(datetime.date(2028, 12, 31))[:3], c.year_progress(datetime.date(2026, 1, 1))[:3])
PY
)"
grep -qF "rows 6 [7, 7, 7, 7, 7, 7]" <<<"$out" || fail "grid is not six weeks of seven: $out"
grep -qF "first 53 2026-12-28 False 2027-01-01 True" <<<"$out" || fail "first week: $out"
grep -qF "second 1 2027-01-04" <<<"$out" || fail "second week: $out"
grep -qF "last 5 2027-02-07" <<<"$out" || fail "last week: $out"
grep -qF "weekend [False, False, False, False, False, True, True]" <<<"$out" || fail "weekend flags: $out"
grep -qF "feb 2026-01-26 2026-02-01 True" <<<"$out" || fail "Monday-first grid: $out"
grep -qF "today ['2026-11-23']" <<<"$out" || fail "today not in its month: $out"
grep -qF "shift (2027, 1) (2026, 12) (2026, 4)" <<<"$out" || fail "month shift: $out"
grep -qF "es noviembre lun lunes, 23 de noviembre de 2026" <<<"$out" || fail "Spanish names: $out"
grep -qF "en November Sun Monday, 23 November 2026" <<<"$out" || fail "English names: $out"
grep -qF "xx January" <<<"$out" || fail "unknown language must fall back to English: $out"
grep -qF "weekday lunes" <<<"$out" || fail "weekday name: $out"
grep -qF "year 327 365 38 True 0.767 0.0" <<<"$out" || fail "year progress: $out"
grep -qF "leap (366, 366, 0) (1, 365, 364)" <<<"$out" || fail "leap year and the first day: $out"
printf 'ok: calendar panel backend\n'
