#!/usr/bin/env bash
# shellcheck disable=SC2016
set -Eeuo pipefail

# vivac-panel menu, its backend without a display: the calculator reads
# arithmetic and nothing else (no eval, no huge powers, comma or point), the
# filter ignores case and accents and wants every word, the order follows what
# is used most, the catalogue is built from the .desktop files and the
# folders and tools that really exist (fakes in a sandbox), the session rows
# ask for confirmation where they end something, and the phone rows exist only
# for a reachable phone.

repo_root="${REPO_ROOT:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)}"
fail() {
	printf '%s\n' "$1" >&2
	exit 1
}
sandbox="$(mktemp -d "${TMPDIR:-/tmp}/vivac-menu.XXXXXX")"
trap 'rm -rf -- "$sandbox"' EXIT

home="$sandbox/home"
mkdir -p "$sandbox/bin" "$sandbox/menubin" "$sandbox/share/applications" "$sandbox/data" \
	"$home/.config/hypr/scripts" "$home/Descargas" "$home/Documentos" "$home/Música" "$home/.local/state/vivac"
: >"$home/.config/hypr/scripts/dispatch.sh"
chmod +x "$home/.config/hypr/scripts/dispatch.sh"
cat >"$home/.config/user-dirs.dirs" <<'DIRS'
XDG_DESKTOP_DIR="$HOME"
XDG_DOWNLOAD_DIR="$HOME/Descargas"
XDG_DOCUMENTS_DIR="$HOME/Documentos"
XDG_MUSIC_DIR="$HOME/Música"
XDG_PICTURES_DIR="$HOME/Imágenes"
DIRS

desktop() { # desktop FILE NAME EXTRA...
	local file="$1" name="$2"
	shift 2
	{
		printf '[Desktop Entry]\nType=Application\nName=%s\nExec=true\nIcon=firefox\n' "$name"
		(($#)) && printf '%s\n' "$@"
	} >"$sandbox/share/applications/$file"
}
desktop cam.desktop 'Cámara Web' 'Keywords=webcam;video;'
desktop term.desktop 'Terminal' 'GenericName=Emulador'
desktop hidden.desktop 'Oculta' 'NoDisplay=true'
desktop gnome.desktop 'Solo GNOME' 'OnlyShowIn=GNOME;'

# The desktop, faked.
for tool in hyprlock systemctl; do printf '#!/usr/bin/env bash\n' >"$sandbox/bin/$tool"; done
chmod +x "$sandbox/bin/"*
# vivac's own tools: reboot-other is not set up, the shared mouse is.
printf '#!/usr/bin/env bash\nexit 1\n' >"$sandbox/menubin/vivac-reboot-other"
printf '#!/usr/bin/env bash\nexit 0\n' >"$sandbox/menubin/vivac-mouse"
chmod +x "$sandbox/menubin/"*
# KDE Connect: one reachable phone.
cat >"$sandbox/bin/kdeconnect-cli" <<'FAKE'
#!/usr/bin/env bash
[[ "$*" == "--list-available --id-name-only" ]] && echo "abc123 Pixel de Ana"
exit 0
FAKE
chmod +x "$sandbox/bin/kdeconnect-cli"

run() {
	env -i PATH="$sandbox/bin:/usr/bin:/bin" HOME="$home" XDG_CONFIG_HOME="$home/.config" \
		XDG_STATE_HOME="$home/.local/state" XDG_DATA_HOME="$sandbox/data" XDG_DATA_DIRS="$sandbox/share" \
		VIVAC_LANG=en VIVAC_MENU_BIN="$sandbox/menubin" VIVAC_KDECONNECT_CLI="$sandbox/bin/kdeconnect-cli" \
		SETTINGS_FILE="$sandbox/settings" \
		/usr/bin/python3 -I - "$repo_root/lib" "$@"
}

# --- the calculator -------------------------------------------------------
out="$(run <<'PY'
import sys
sys.path.insert(0, sys.argv[1])
from vivacpanel import menu
cases = ["2+2", "(1200*0,21)/3", "2^10", "10%3", "1,5*2", "7/2", "-5", "2 * (3 + 4)",
         "1/0", "2**1000000", "9**9**9", "abc", "2", "2//2", "__import__('os')", "2+", "", "1e3+1", "(((", "5 5"]
for c in cases:
    print(repr(c), "->", menu.calculation(c))
print("comma", menu.calculation("7/2", comma=True))
print("big", menu.calculation("123456789*987654321"))
PY
)"
expect() { grep -qxF -- "$1" <<<"$out" || fail "calculator: missing line: $1
$out"; }
expect "'2+2' -> 4"
expect "'(1200*0,21)/3' -> 84"
expect "'2^10' -> 1024"
expect "'10%3' -> 1"
expect "'1,5*2' -> 3"
expect "'7/2' -> 3.5"
expect "'-5' -> -5"
expect "'2 * (3 + 4)' -> 14"
expect "'1/0' -> None"
expect "'2**1000000' -> None"
expect "'9**9**9' -> None"
expect "'abc' -> None"
expect "'2' -> None"
expect "'2//2' -> None"
expect "\"__import__('os')\" -> None"
expect "'2+' -> None"
expect "'' -> None"
expect "'1e3+1' -> None"
expect "'(((' -> None"
expect "'5 5' -> None"
expect "comma 3,5"
expect "big 1.21932631112635e+17"

# --- the filter, the order, the usage file ------------------------------------
out="$(run <<'PY'
import sys
sys.path.insert(0, sys.argv[1])
from vivacpanel import menu
E = menu.Entry
items = [E("apps", "Cámara Web", "app", "cam.desktop", keywords="webcam"),
         E("apps", "Terminal", "app", "term.desktop"),
         E("apps", "Mi Terminal bonita", "app", "t2.desktop"),
         E("settings", "Red e Internet", "run", "nm"),
         E("settings", "Configuración: Red", "run", "net"),
         E("session", "Cerrar sesión", "power", "logout", confirm=True)]
def names(q, uses=None):
    return [e.name for e in menu.search(items, q, uses or {})]
print("camara", names("CAMARA"))
print("webcam", names("webcam"))
print("accent", names("sesion"))
print("words", names("red conf"))
print("words2", names("INT red"))
print("none", names("zzz"))
print("prefix", names("term"))
print("used", names("term", {"app|t2.desktop": 5}))
print("empty", len(names("")))
menu.add_use(items[2]); menu.add_use(items[2]); menu.add_use(items[1])
menu.add_use(items[5])   # power is never counted
menu.add_use(E("recent", "secreto.txt", "path", "/x"))  # a file is never counted
uses = menu.read_usage()
print("uses", sorted(uses.items()))
print("file", open(menu.usage_path()).read().splitlines())
print("order", [e.name for e in menu.by_use(items, uses)][:3])
for i in range(260):
    menu.add_use(E("apps", f"x{i}", "app", f"x{i}.desktop"))
print("capped", len(open(menu.usage_path()).read().splitlines()))
open(menu.usage_path(), "w").write("junk\nx\ty\n3\tapp|ok\n")
print("junk", menu.read_usage())
PY
)"
expect "camara ['Cámara Web']"
expect "webcam ['Cámara Web']"
expect "accent ['Cerrar sesión']"
expect "words ['Configuración: Red']"
expect "words2 ['Red e Internet']"
expect "none []"
expect "prefix ['Terminal', 'Mi Terminal bonita']"
expect "used ['Mi Terminal bonita', 'Terminal']"
expect "empty 6"
expect "uses [('app|t2.desktop', 2), ('app|term.desktop', 1)]"
expect "file ['2\\tapp|t2.desktop', '1\\tapp|term.desktop']"
expect "order ['Mi Terminal bonita', 'Terminal', 'Cámara Web']"
expect "capped 200"
expect "junk {'app|ok': 3}"

# --- the catalogue ---------------------------------------------------------------
out="$(run <<'PY'
import sys
sys.path.insert(0, sys.argv[1])
from vivacpanel import menu
apps = menu.app_entries()
print("apps", [(a.name, a.kind, a.target, a.group) for a in apps])
print("folders", [(f.kind, f.target.replace(sys.argv[1], "")[-14:] if False else f.target.split("/")[-1]) for f in menu.folder_entries()])
print("folder-detail", [f.detail for f in menu.folder_entries()][:1])
session = menu.session_entries()
print("session", [(s.target.rsplit("/", 1)[-1], s.confirm) for s in session])
print("tools", sorted({t.group for t in menu.tool_entries()}), sorted({t.group for t in menu.setting_entries()}))
phone = menu.phone_entries()
print("phone", [(p.kind, p.target) for p in phone])
print("argv-ring", menu.command_for(phone[0], ""))
print("argv-open", menu.command_for(menu.folder_entries()[0], ""))
print("argv-lock", menu.command_for(session[0], ""))
print("argv-reboot", menu.command_for([s for s in session if s.target == "reboot"][0], ""))
print("argv-copy", menu.command_for(menu.Entry("tools", "= 4", "copy", "4"), ""))
print("argv-web", menu.command_for(menu.Entry("tools", "w", "find-web", ""), "a b&c"))
print("catalog-groups", sorted({e.group for e in menu.catalog()}))
PY
)"
expect "apps [('Cámara Web', 'app', 'cam.desktop', 'apps'), ('Terminal', 'app', 'term.desktop', 'apps')]"
expect "folders [('folder', 'home'), ('folder', 'Documentos'), ('folder', 'Descargas'), ('folder', 'Música')]"
grep -q '^folder-detail \[' <<<"$out" || fail "folder detail missing"
expect "session [('lock', False), ('suspend', False), ('logout', True), ('reboot', True), ('poweroff', True), ('vivac-mouse toggle', False)]"
expect "tools ['tools'] ['settings']"
expect "phone [('say', '$sandbox/bin/kdeconnect-cli -d abc123 --ring'), ('say', '$sandbox/bin/kdeconnect-cli -d abc123 --send-clipboard'), ('run', 'vivac-phone menu')]"
grep -q "^argv-ring \['bash', '-c'" <<<"$out" || fail "ring is run through the notifier: $out"
expect "argv-open ['xdg-open', '$home']"
expect "argv-lock ['hyprlock']"
expect "argv-reboot ['systemctl', 'reboot']"
expect "argv-copy ['wl-copy', '4']"
grep -q "^argv-web \['xdg-open', 'https://duckduckgo.com/?q=a%20b%26c'\]" <<<"$out" || fail "web search is escaped: $out"
expect "catalog-groups ['apps', 'folders', 'phone', 'session', 'settings', 'tools']"

# --- a machine with none of it: only what exists -------------------------------
out="$(env -i PATH="/usr/bin:/bin" HOME="$sandbox/empty" XDG_CONFIG_HOME="$sandbox/empty/.config" XDG_STATE_HOME="$sandbox/empty/.state" \
	XDG_DATA_HOME="$sandbox/empty/data" XDG_DATA_DIRS="$sandbox/empty/share" VIVAC_LANG=en VIVAC_MENU_BIN="$sandbox/empty/bin" \
	VIVAC_KDECONNECT_CLI="$sandbox/empty/kdeconnect-cli" SETTINGS_FILE="$sandbox/settings" \
	/usr/bin/python3 -I - "$repo_root/lib" <<'PY'
import sys
sys.path.insert(0, sys.argv[1])
from vivacpanel import menu
print("phone", menu.phone_entries())
print("folders", menu.folder_entries())
print("apps", menu.app_entries())
print("bridge", [s.target for s in menu.session_entries() if s.kind != "power"])
PY
)"
expect "phone []"
expect "folders []"
expect "apps []"
expect "bridge []"

printf 'ok\n'
