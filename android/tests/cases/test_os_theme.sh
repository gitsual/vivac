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

# notifications: vivac card colours, radii, border layer and fonts
night = {c.get("name"): c.text for c in ET.parse(os.path.join(fwk, "..", "values-night", "colors.xml")).getroot()}
for k, v in {"materialColorSurfaceContainerHigh": "#2D1F2D", "materialColorSurfaceContainerHighest": "#362836", "materialColorSurface": "#18131B",
             "materialColorOnSurface": "#E8D5AB", "materialColorOnSurfaceVariant": "#C0AD95", "materialColorOutlineVariant": "#43363F",
             "materialColorPrimary": "#F0A3A6", "customColorSurfaceEffect1": "#2D1F2D"}.items():
    if night.get(k) != v:
        err.append("values-night %s is %s, want %s" % (k, night.get(k), v))
for k in ("notification_primary_text_color_dark", "notification_secondary_text_color_dark"):
    if cols.get(k) != "#E8D5AB":
        err.append("%s is %s, want #E8D5AB" % (k, cols.get(k)))
sui = os.path.join(theme, "VivacThemeSystemUI", "res")
dim = {d.get("name"): d.text for d in ET.parse(os.path.join(sui, "values", "dimens.xml")).getroot()}
if dim.get("notification_corner_radius") != "24dp" or dim.get("notification_corner_radius_small") != "16dp":
    err.append("notification radii are not 24dp / 16dp")
bg = ET.parse(os.path.join(sui, "drawable", "notification_material_bg.xml")).getroot()
layers = [i.find("shape") for i in bg.findall("item")]
if len(layers) != 3 or layers[0].find("solid") is None or layers[1].find("solid") is None:
    err.append("notification_material_bg must keep tint layer 0 and state layer 1")
elif layers[2].find("stroke") is None or layers[2].find("stroke").get(A + "color") != "#43363F" or layers[2].find("stroke").get(A + "width") != "1dp":
    err.append("notification_material_bg has no last 1dp #43363F border layer")
if any(i.get(A + "id") for i in bg.findall("item")):
    err.append("notification_material_bg declares a layer id (would not match SystemUI's)")
sty = {s.get("name"): s for s in ET.parse(os.path.join(fwk, "styles.xml")).getroot()}
want_styles = ("TextAppearance.DeviceDefault.Notification", "TextAppearance.DeviceDefault.Notification.Title", "TextAppearance.DeviceDefault.Notification.Info")
for n in want_styles:
    if n not in sty:
        err.append("missing style %s" % n)
if all(n in sty for n in want_styles):
    fam = {n: sty[n].find("item[@name='android:fontFamily']").text for n in sty}
    for n, want in {"TextAppearance.DeviceDefault.Notification.Info": "jetbrains-mono", "TextAppearance.DeviceDefault.Notification": "@string/config_bodyFontFamily"}.items():
        if fam.get(n) != want:
            err.append("%s font is %s, want %s" % (n, fam.get(n), want))

if err:
    print("\n".join(err), file=sys.stderr)
    sys.exit(1)
PY
[[ -e "$patches/frameworks/base/0001-vivac-fonts.patch" ]] || fail "missing fonts patch"
