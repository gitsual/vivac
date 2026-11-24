#!/usr/bin/env bash
set -Eeuo pipefail

# The phone and sessions panels (vivac-panel phone, vivac-panel sessions),
# without a screen. Phone: the subtitle and the buttons follow what
# `vivac-phone status` says (no KDE Connect, no phone in reach, a phone with
# its battery), the link button only with a link on the clipboard, browse only
# with sshfs, the phone as a screen only with wayvnc, and each button runs
# exactly its `vivac-phone do` line. Sessions: the photo `sesiones ver` prints
# is read into windows by workspace, the bar's line gives when it was taken,
# and restoring is two steps.

repo_root="${REPO_ROOT:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)}"
fail() {
	printf '%s\n' "$1" >&2
	exit 1
}

VIVAC_LANG=en /usr/bin/python3 -I - "$repo_root/lib" <<'PY' || fail 'the phone panel broke its rules'
import sys
sys.path.insert(0, sys.argv[1])
from vivacpanel import phone

none = {"installed": False, "daemon": False, "phones": [], "can_browse": False, "can_screen": False}
assert phone.subtitle(none) == phone.T("phone.not_installed"), phone.subtitle(none)
assert [t.key for t in phone.tiles(none, has_link=False)] == ["manage"]

away = {"installed": True, "daemon": True, "phones": [], "can_browse": True, "can_screen": False}
assert phone.subtitle(away) == phone.T("phone.none")
assert [t.key for t in phone.tiles(away, has_link=True)] == ["manage"]

pixel = {"installed": True, "daemon": True, "can_browse": True, "can_screen": True,
         "phones": [{"id": "a1b2", "name": "Pixel 8", "charge": 54, "charging": True}]}
assert phone.subtitle(pixel) == "Pixel 8 · 54 % · " + phone.T("phone.panel.charging"), phone.subtitle(pixel)
low = dict(pixel, phones=[dict(pixel["phones"][0], charge=12, charging=False)])
assert phone.subtitle(low) == "Pixel 8 · 12 %", phone.subtitle(low)
keys = [t.key for t in phone.tiles(pixel, has_link=False)]
assert keys == ["ring", "send-file", "send-clip", "send-url", "browse", "screen", "manage"], keys
assert not next(t for t in phone.tiles(pixel, has_link=False) if t.key == "send-url").enabled
assert next(t for t in phone.tiles(pixel, has_link=True) if t.key == "send-url").enabled
plain = dict(pixel, can_browse=False, can_screen=False)
assert [t.key for t in phone.tiles(plain, has_link=True)] == ["ring", "send-file", "send-clip", "send-url", "manage"]

tool = "/x/vivac-phone"
assert phone.command("ring", "a1b2", tool=tool) == [tool, "do", "ring", "--device", "a1b2"]
assert phone.command("send-file", "a1b2", "/h/f.txt", tool=tool) == [tool, "do", "send-file", "--device", "a1b2", "/h/f.txt"]
assert phone.command("screen", "a1b2", tool=tool) == [tool, "run", "phone-screen"]
assert phone.is_link("https://example.org/x") and not phone.is_link("file:///etc") and not phone.is_link("hi there")
PY

VIVAC_LANG=en /usr/bin/python3 -I - "$repo_root/lib" <<'PY' || fail 'the sessions panel broke its rules'
import sys
sys.path.insert(0, sys.argv[1])
from vivacpanel import sessions

text = """Foto del 2026-11-23T23:12:36
  [2] Terminal en /home/x
  [2] Claude «Levantar Immich»
  [10] Thunar: Descargas - Thunar
"""
photo = sessions.parse_ver(text)
assert photo.taken == "2026-11-23T23:12:36", photo
assert photo.windows == [(2, "Terminal en /home/x"), (2, "Claude «Levantar Immich»"), (10, "Thunar: Descargas - Thunar")], photo
assert sessions.by_workspace(photo.windows) == [(2, ["Terminal en /home/x", "Claude «Levantar Immich»"]), (10, ["Thunar: Descargas - Thunar"])]
assert sessions.parse_ver("Todavía no hay ninguna foto\n").windows == []

bar = {"tooltip": "Sesiones\nClic: restaurar la última foto\nClic derecho: guardar ahora\nÚltima foto: hace 4 min\nUn clic devuelve 10 ventanas del arranque anterior (hace 12 h)"}
assert sessions.facts(bar) == ["Última foto: hace 4 min", "Un clic devuelve 10 ventanas del arranque anterior (hace 12 h)"], sessions.facts(bar)

tool = "/h/bin/sesiones"
assert sessions.command("save", tool=tool) == [tool, "guardar"]
assert sessions.command("restore", tool=tool) == [tool, "restaurar"]

step = sessions.Restore()
assert step.press() is False and step.armed, 'the first press only asks'
assert step.press() is True, 'the second press restores'
step = sessions.Restore(); step.press(); step.cancel()
assert not step.armed and step.press() is False, 'cancel disarms'
PY

grep -q '"phone"' "$repo_root/dotfiles/ricer/.local/bin/vivac-panel" || fail 'vivac-panel does not know the phone panel'
grep -q '"sessions"' "$repo_root/dotfiles/ricer/.local/bin/vivac-panel" || fail 'vivac-panel does not know the sessions panel'
printf 'phone and sessions panels: buttons follow the phone, each runs its line, the photo is read by workspace, restoring asks first\n'
