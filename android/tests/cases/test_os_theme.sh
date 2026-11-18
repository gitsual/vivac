#!/usr/bin/env bash
set -Eeuo pipefail

# The vivac theme sources are consistent: every overlay is a well-formed static
# RRO, the fonts the framework overlay names exist in the font config (or as
# an alias), the product hook lists exactly the modules that exist, the font
# files resolve, and the pinned palette is the vivac one.

repo_root="${REPO_ROOT:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)}"
patches="$repo_root/os/patches"
theme="$patches/vendor/adevtool/vivac-files/config/mk/google_devices/device/shiba/vivac-theme"
fonts="$patches/frameworks/base/vivac-files/data/fonts/vivac"
fwk="$theme/VivacThemeFramework/res/values"

fail() {
	printf '%s\n' "$1" >&2
	exit 1
}

python3 -I - "$patches" "$theme" "$fonts" "$fwk" <<'PY' || exit 1
import json, re, sys, os
import xml.etree.ElementTree as ET

patches, theme, fonts, fwk = sys.argv[1:5]
A = "{http://schemas.android.com/apk/res/android}"
err = []

mods = sorted(d for d in os.listdir(theme) if os.path.isdir(os.path.join(theme, d)))
targets = {"VivacThemeFramework": "android", "VivacThemeSystemUI": "com.android.systemui", "VivacThemeSettings": "com.android.settings"}
if mods != sorted(targets):
    err.append("overlay modules are %s" % mods)
for m, tgt in targets.items():
    root = ET.parse(os.path.join(theme, m, "AndroidManifest.xml")).getroot()
    ov = root.find("overlay")
    if ov is None or ov.get(A + "isStatic") != "true" or ov.get(A + "targetPackage") != tgt:
        err.append("%s: not a static overlay on %s" % (m, tgt))
    bp = open(os.path.join(theme, m, "Android.bp")).read()
    if 'name: "%s"' % m not in bp or "product_specific: true" not in bp:
        err.append("%s: Android.bp does not define the product RRO" % m)
    for f in os.listdir(os.path.join(theme, m, "res", "values")):
        ET.parse(os.path.join(theme, m, "res", "values", f))

# fonts named by the framework overlay resolve to a family or an alias
cfg = ET.parse(os.path.join(fwk, "config.xml")).getroot()
named = {e.get("name"): (e.text or "") for e in cfg.findall("string")}
families = {f["name"] for f in json.load(open(os.path.join(fonts, "font_config.json")))}
aliases = re.findall(r'"name": "([^"]+)", "to"', open(os.path.join(patches, "frameworks/base/0001-vivac-fonts.patch")).read())
for k, v in named.items():
    if k.endswith("FontFamily") or k.endswith("FontFamilyMedium"):
        if v not in families and v not in aliases:
            err.append("%s=%s is neither a family nor an alias" % (k, v))
files = {f["file"] for fam in json.load(open(os.path.join(fonts, "font_config.json"))) for f in fam["fonts"]}
for f in files:
    p = os.path.join(fonts, f)
    if not os.path.isfile(p) or os.path.getsize(p) < 1000:
        err.append("font file does not resolve: %s" % f)
    if ('name: "%s"' % f) not in open(os.path.join(fonts, "Android.bp")).read():
        err.append("font %s has no prebuilt_font" % f)

# product hook lists every overlay and font module, nothing else
hook = open(os.path.join(patches, "vendor/adevtool/0001-vivac-theme-product.patch")).read()
listed = set(re.findall(r"^\+\s+([\w.\-]+)(?: \\)?$", hook, re.M))
if listed != set(targets) | files:
    err.append("product hook lists %s" % sorted(listed))

# dark by default, pinned vivac coral seed, only vivac palette anchors in the ramps
if cfg.find("integer[@name='config_defaultNightMode']").text != "2":
    err.append("not dark by default")
if "*|TONAL_SPOT|#E1777D" not in [i.text for i in cfg.find("string-array[@name='theming_defaults']")]:
    err.append("theming_defaults is not the vivac coral seed")
cols = {c.get("name"): c.text for c in ET.parse(os.path.join(fwk, "colors.xml")).getroot()}
for k, v in {"system_accent1_200": "#E1777D", "system_neutral1_900": "#18131B", "system_neutral1_800": "#2D1F2D", "system_accent3_200": "#6CA4B1", "system_neutral1_100": "#E8D5AB"}.items():
    if cols.get(k) != v:
        err.append("%s is %s, want %s" % (k, cols.get(k), v))

if err:
    print("\n".join(err), file=sys.stderr)
    sys.exit(1)
PY
[[ -e "$patches/frameworks/base/0001-vivac-fonts.patch" ]] || fail "missing fonts patch"
