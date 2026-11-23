#!/usr/bin/env bash
# Renders the bar and its panels with headless Chromium and canned Zebar data,
# for looking at them without Zebar or Windows.
#   shot.sh <outdir> [theme]     (theme: a file name under data/themes, default metropolis)
# It copies static/zebar/vivac to a scratch folder, swaps zebar-client.js for
# fake-zebar-client.js, renders styles.css from the template with the theme and
# config.js with the Spanish labels, serves it and takes the PNGs:
# bar, calendar, forecast, system-<cpu|memory|disk|gpu>.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd); repo=$(cd "$here/../../.." && pwd)
out=${1:?outdir}; theme=${2:-metropolis}
work=$(mktemp -d); mkdir -p "$out"
cp "$repo"/static/zebar/vivac/* "$work"/; cp "$here/fake-zebar-client.js" "$work/zebar-client.js"
python3 -I - "$repo" "$work" "$theme" <<'PY'
import re, sys, json
repo, work, theme = sys.argv[1:]
kv = lambda p: dict(l.strip().split('=', 1) for l in open(p, encoding='utf-8') if re.match(r'^[A-Z_]+=', l))
colors = kv(f'{repo}/data/themes/{theme}.conf')
def sub(m):
    k, f = m.group(1), m.group(2)
    v = colors[k]
    return ', '.join(str(int(v[i:i+2], 16)) for i in (0, 2, 4)) if f == 'rgb' else v
css = re.sub(r'@(COLOR_[A-Z_]+)(?::(\w+))?@', sub, open(f'{repo}/templates/zebar/vivac/styles.css.in', encoding='utf-8').read())
open(f'{work}/styles.css', 'w', encoding='utf-8').write(css)
labels = {}
for p in (f'{repo}/i18n/es.conf', sys.argv[0] if False else None):
    pass
import glob, os
files = [f'{repo}/i18n/es.conf'] + sorted(glob.glob(os.environ.get('VIVAC_EXTRA_I18N', '') + '/i18n-win-*-es.conf'))
for p in files:
    for l in open(p, encoding='utf-8'):
        m = re.match(r'^bar\.([a-z0-9_]+)=(.*)$', l.rstrip('\n'))
        if m: labels[m.group(1)] = m.group(2)
cfg = {'repo': 'C:\\\\vivac', 'pipe': 'vivac-test', 'locale': 'es', 'weather': {}, 'labels': labels,
       'modules': ['wireless', 'wired', 'phone', 'cpu', 'memory', 'disk', 'gpu', 'usb', 'audio', 'bluetooth', 'security', 'theme', 'power', 'updates']}
open(f'{work}/config.js', 'w', encoding='utf-8').write('export const config = ' + json.dumps(cfg, ensure_ascii=False) + ';\n')
PY
bg=$(rg -o '^COLOR_BG=\w+' "$repo/data/themes/$theme.conf" | head -1 | cut -d= -f2)
port=$((20000 + RANDOM % 9000))
python3 -m http.server "$port" --directory "$work" >/dev/null 2>&1 & srv=$!
trap 'kill $srv 2>/dev/null; rm -rf "$work"' EXIT; sleep 1
shot() { chromium --headless=new --no-sandbox --hide-scrollbars --force-device-scale-factor=1 --default-background-color="${bg}FF" \
  --window-size="$2" --virtual-time-budget=6000 --screenshot="$out/$1.png" "http://127.0.0.1:$port/$3" >/dev/null 2>&1; }
shot bar 1920,48 index.html
shot calendar 468,700 calendar.html
shot forecast 580,880 forecast.html
for t in cpu memory disk gpu; do shot "system-$t" 540,830 "system.html?tab=$t"; done
ls "$out"
