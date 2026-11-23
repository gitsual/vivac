"""Menu: everything you can start, in one searchable panel.

The Windows side's Show-Menu (windows/lib/Surfaces.psm1) on Arch: the apps of
the .desktop files, the user's folders, the files used last, vivac's own
settings and tools, the session (lock, suspend, restart, power off, restart in
Windows) and the phone, in categories; a search that ignores case and accents
and wants every word typed; a calculator when what is typed is arithmetic; an
order that follows what is opened most.

The pure half (catalogue, search, calculator, usage file, the command each
entry runs) imports nothing graphical, so the tests read it without a
display. Only entries that really exist are offered: a folder that is not
there, a tool that is not installed, a phone that does not answer are left
out, never shown disabled.
"""
from __future__ import annotations

import ast
import math
import os
import re
import shlex
import shutil
import socket
import subprocess
import unicodedata
import xml.etree.ElementTree as ET
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path
from urllib.parse import quote, unquote, urlparse

GROUPS = ("apps", "recent", "folders", "settings", "tools", "session", "phone")
USAGE_KINDS = ("app", "folder", "run")  # what is counted: never a file, never a session action
USAGE_LIMIT = 200
RECENT_LIMIT = 15

# Material Design icons of the Nerd Font, the family the other panels use.
GLYPH = {
    "all": "\U000F0570", "apps": "\U000F003B", "recent": "\U000F02DA", "folders": "\U000F024B",
    "settings": "\U000F0493", "tools": "\U000F05B7", "session": "\U000F0425", "phone": "\U000F011C",
    "menu": "\U000F035C", "folder": "\U000F024B", "file": "\U000F0214", "home": "\U000F02DC",
    "lock": "\U000F033E", "suspend": "\U000F04B2", "logout": "\U000F0343", "reboot": "\U000F0709",
    "poweroff": "\U000F0425", "windows": "\U000F05B3", "calc": "\U000F00EC", "web": "\U000F059F",
    "run": "\U000F018D", "sound": "\U000F057E", "security": "\U000F0498", "theme": "\U000F03D8",
    "system": "\U000F0379", "clipboard": "\U000F0147", "calendar": "\U000F00ED", "weather": "\U000F0595",
    "usb": "\U000F0553", "ask": "\U000F06A9", "drop_in": "\U000F0167", "drop_out": "\U000F0170",
    "link": "\U000F0337", "wake": "\U000F0425", "mouse": "\U000F037D", "hermes": "\U000F06A9",
    "send": "\U000F048A", "ring": "\U000F00A2", "clip_send": "\U000F0147",
}


# ---------------------------------------------------------------- text helpers

def fold(text: str) -> str:
    """Lower case without accents: what matching compares."""
    decomposed = unicodedata.normalize("NFD", text.lower())
    return "".join(c for c in decomposed if unicodedata.category(c) != "Mn")


def _t(key: str, *args: object) -> str:
    from .kit import T

    return T(key, *args)


def _label(key: str, *args: object) -> str:
    """A table text, or nothing when the key is not in it yet (never "[key]")."""
    text = _t(key, *args)
    return "" if text.startswith("[") and text.endswith("]") else text


# ------------------------------------------------------------------ calculator

_ARITHMETIC = re.compile(r"[\d\s.,+\-*/()%^]+")
_MAX_EXPONENT = 1000


def _evaluate(node: ast.AST) -> float:
    """Arithmetic over numbers and nothing else; any other node is refused."""
    if isinstance(node, ast.Constant) and type(node.value) in (int, float):
        return float(node.value)
    if isinstance(node, ast.UnaryOp) and isinstance(node.op, (ast.USub, ast.UAdd)):
        value = _evaluate(node.operand)
        return -value if isinstance(node.op, ast.USub) else value
    if isinstance(node, ast.BinOp):
        left, right = _evaluate(node.left), _evaluate(node.right)
        op = node.op
        if isinstance(op, ast.Add):
            return left + right
        if isinstance(op, ast.Sub):
            return left - right
        if isinstance(op, ast.Mult):
            return left * right
        if isinstance(op, ast.Div):
            return left / right
        if isinstance(op, ast.Mod):
            return left % right
        if isinstance(op, ast.Pow):
            if abs(right) > _MAX_EXPONENT:
                raise ValueError("exponent too large")
            return float(left ** right)  # TypeError on a complex result
    raise ValueError("not arithmetic")


def calculate(query: str) -> float | None:
    """The value of what is typed when it is an expression: + - * / % ** ^,
    parentheses, decimals with a comma or a point. Nothing is evaluated that
    is not arithmetic: the text is parsed, never executed."""
    q = query.strip()
    if len(q) > 200 or not _ARITHMETIC.fullmatch(q) or not re.search(r"\d", q) \
            or not re.search(r"[+\-*/%^]", q):
        return None
    expr = re.sub(r"(?<![\d.])0+(?=\d)", "", q.replace(",", ".").replace("^", "**"))
    try:
        value = _evaluate(ast.parse(expr, mode="eval").body)
    except (SyntaxError, ValueError, TypeError, ZeroDivisionError, OverflowError, RecursionError, MemoryError):
        return None
    return value if math.isfinite(value) else None


def calculation(query: str, comma: bool = False) -> str | None:
    """The result as text (15 significant digits), with a decimal comma when asked."""
    value = calculate(query)
    if value is None:
        return None
    text = format(value, ".15g")
    return text.replace(".", ",") if comma else text


# ---------------------------------------------------------------------- entries

@dataclass
class Entry:
    group: str
    name: str
    kind: str      # app | folder | path | run | power | bridge | say | copy | run-text | find-web
    target: str
    confirm: bool = False
    glyph: str = ""
    icon: str = ""
    detail: str = ""
    keywords: str = ""
    say: tuple = ()  # (title, said on success, said on failure) for kind "say"


def home() -> Path:
    return Path.home()


def shorten(path: Path | str) -> str:
    path = Path(path)
    try:
        return "~" if path == home() else "~/" + str(path.relative_to(home()))
    except ValueError:
        return str(path)


def bin_dir() -> Path:
    return Path(os.environ.get("VIVAC_MENU_BIN") or home() / ".local" / "bin")


def resolve(name: str, fallback: Path | None = None) -> str | None:
    """Where vivac's tool NAME is: beside the others, on the PATH, or in the
    checkout; the bare name when only a bridge-less tool is wanted."""
    candidate = bin_dir() / name
    if candidate.exists():
        return str(candidate)
    found = shutil.which(name)
    if found:
        return found
    if fallback is not None and fallback.exists():
        return str(fallback)
    return None


def _repo_tool(name: str) -> Path:
    from .kit import repo_root

    return repo_root() / "dotfiles" / "ricer" / ".local" / "bin" / name


def _state_dir() -> Path:
    return Path(os.environ.get("XDG_STATE_HOME") or home() / ".local" / "state") / "vivac"


def _tool_ok(name: str, *args: str) -> bool:
    """A vivac tool beside the others whose own check (--available) says yes."""
    path = bin_dir() / name
    if not path.exists():
        return False
    try:
        return subprocess.run([str(path), *args], capture_output=True, timeout=4).returncode == 0
    except (OSError, subprocess.TimeoutExpired):
        return False


# ------------------------------------------------------------------------ apps

def app_entries() -> list[Entry]:
    """The applications of the .desktop files, as the session shows them."""
    try:
        import gi

        gi.require_version("Gio", "2.0")
        from gi.repository import Gio
    except (ImportError, ValueError):
        return []
    out: list[Entry] = []
    for info in Gio.AppInfo.get_all():
        if not info.should_show():
            continue
        icon = info.get_icon()
        icon_name = ""
        if isinstance(icon, Gio.ThemedIcon):
            names = icon.get_names()
            icon_name = names[0] if names else ""
        elif isinstance(icon, Gio.FileIcon):
            icon_name = icon.get_file().get_path() or ""
        words: list[str] = []
        if isinstance(info, Gio.DesktopAppInfo):
            words = list(info.get_keywords() or []) + [info.get_generic_name() or ""]
        out.append(Entry("apps", info.get_display_name() or info.get_name(), "app", info.get_id() or "",
                         glyph=GLYPH["apps"], icon=icon_name, keywords=" ".join(w for w in words if w)))
    out.sort(key=lambda e: fold(e.name))
    unique, seen = [], set()
    for e in out:  # two .desktop files with one name are one row
        if e.name not in seen:
            seen.add(e.name)
            unique.append(e)
    return unique


# --------------------------------------------------------------------- folders

_USER_DIRS = (  # Windows' order: personal, desktop, documents, downloads...
    ("XDG_DESKTOP_DIR", "desktop", "Desktop"), ("XDG_DOCUMENTS_DIR", "documents", "Documents"),
    ("XDG_DOWNLOAD_DIR", "downloads", "Downloads"), ("XDG_PICTURES_DIR", "pictures", "Pictures"),
    ("XDG_MUSIC_DIR", "music", "Music"), ("XDG_VIDEOS_DIR", "videos", "Videos"),
)


def _user_dirs() -> dict[str, Path]:
    """xdg-user-dirs: the user-dirs.dirs file, KEY="$HOME/..." per line."""
    config = Path(os.environ.get("XDG_CONFIG_HOME") or home() / ".config") / "user-dirs.dirs"
    found: dict[str, Path] = {}
    try:
        text = config.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return found
    for line in text.splitlines():
        match = re.fullmatch(r'\s*(XDG_[A-Z]+_DIR)\s*=\s*"(.*)"\s*', line)
        if match:
            value = match.group(2).replace("$HOME", str(home()))
            if value.startswith("/"):
                found[match.group(1)] = Path(value)
    return found


def folder_entries() -> list[Entry]:
    dirs = _user_dirs()
    out: list[Entry] = []
    if home().is_dir():
        out.append(Entry("folders", _label("menu.folder.home"), "folder", str(home()),
                         glyph=GLYPH["home"], detail="~"))
    for var, key, default in _USER_DIRS:
        path = dirs.get(var, home() / default)
        if path == home() or not path.is_dir():
            continue  # xdg-user-dirs points an unset folder at $HOME
        out.append(Entry("folders", _label(f"menu.folder.{key}"), "folder", str(path),
                         glyph=GLYPH["folder"], detail=shorten(path)))
    return out


# ---------------------------------------------------------------------- recent

def recent_entries(limit: int = RECENT_LIMIT) -> list[Entry]:
    """The files used last, as the desktop recorded them (recently-used.xbel)."""
    data = Path(os.environ.get("XDG_DATA_HOME") or home() / ".local" / "share")
    try:
        root = ET.parse(data / "recently-used.xbel").getroot()
    except (OSError, ET.ParseError):
        return []
    found: list[tuple[str, Path]] = []
    for mark in root.iter("bookmark"):
        uri = urlparse(mark.get("href", ""))
        if uri.scheme != "file":
            continue
        path = Path(unquote(uri.path))
        stamp = mark.get("modified") or mark.get("visited") or mark.get("added") or ""
        if path.exists():
            found.append((stamp, path))
    found.sort(key=lambda item: item[0], reverse=True)
    out, seen = [], set()
    for stamp, path in found:
        if path in seen:
            continue
        seen.add(path)
        when = ""
        try:
            when = datetime.fromisoformat(stamp.replace("Z", "+00:00")).astimezone().strftime("%d/%m %H:%M")
        except ValueError:
            pass
        place = shorten(path.parent)
        out.append(Entry("recent", path.name, "path", str(path), glyph=GLYPH["file"],
                         detail=f"{place} · {when}" if when else place))
        if len(out) == limit:
            break
    return out


# ------------------------------------------------------- settings and tools

def _panel(kind: str) -> str | None:
    """The command line that opens vivac-panel KIND, if the panel exists."""
    from .kit import repo_root

    if not (repo_root() / "lib" / "vivacpanel" / f"{kind}.py").is_file():
        return None
    launcher = resolve("vivac-panel", _repo_tool("vivac-panel"))
    return shlex.join([launcher, kind]) if launcher else None


def _terminal() -> str | None:
    return shutil.which(os.environ.get("VIVAC_TERMINAL") or "kitty")


def setting_entries() -> list[Entry]:
    out: list[Entry] = []
    for kind, label, glyph in (("sound", "sound.title", "sound"), ("security", "security.title", "security")):
        cmd = _panel(kind)
        if cmd:
            out.append(Entry("settings", _t(label), "run", cmd, glyph=GLYPH[glyph],
                             detail=f"vivac-panel {kind}"))
    theme = resolve("vivac-theme", _repo_tool("vivac-theme"))
    if theme and (term := _terminal()):
        out.append(Entry("settings", _t("menu.set.theme"), "run",
                         shlex.join([term, "--class", "vivac-theme", "-e", theme]),
                         glyph=GLYPH["theme"], detail="vivac-theme", keywords="theme colours palette"))
    return out


def tool_entries() -> list[Entry]:
    out: list[Entry] = []
    for kind, label, glyph in (("system", "sys.title", "system"), ("clipboard", "clip.title", "clipboard"),
                               ("calendar", "cal.title", "calendar"), ("forecast", "fc.title", "weather"),
                               ("usb", "usb.title", "usb")):
        cmd = _panel(kind)
        if cmd:
            out.append(Entry("tools", _t(label), "run", cmd, glyph=GLYPH[glyph], detail=f"vivac-panel {kind}"))
    ask = resolve("vivac-ask", _repo_tool("vivac-ask"))
    if ask and (term := _terminal()):
        out.append(Entry("tools", _t("menu.tool.ask"), "run",
                         shlex.join([term, "--class", "vivac-ask", "-e", ask]),
                         glyph=GLYPH["ask"], detail="vivac-ask", keywords="ia assistant model"))
    return out


# --------------------------------------------------------------------- session

def _dispatch() -> Path:
    return home() / ".config" / "hypr" / "scripts" / "dispatch.sh"


def session_entries() -> list[Entry]:
    return power_entries() + bridge_entries()


def power_entries() -> list[Entry]:
    """What ends or pauses the session."""
    out: list[Entry] = []
    ctl = shutil.which("systemctl")
    if shutil.which("hyprlock"):
        out.append(Entry("session", _t("power.lock"), "power", "lock", glyph=GLYPH["lock"]))
    if ctl:
        out.append(Entry("session", _t("power.suspend"), "power", "suspend", glyph=GLYPH["suspend"]))
    if _dispatch().is_file():
        out.append(Entry("session", _t("power.logout"), "power", "logout", True, GLYPH["logout"]))
    if ctl:
        out.append(Entry("session", _t("power.reboot"), "power", "reboot", True, GLYPH["reboot"]))
        out.append(Entry("session", _t("power.poweroff"), "power", "poweroff", True, GLYPH["poweroff"]))
    return out


def bridge_entries() -> list[Entry]:
    """The bridge to Windows, once each part is set up. Asking the tools
    whether they are can take seconds (the firmware is read), so the panel
    calls this off the main thread."""
    out: list[Entry] = []
    if _tool_ok("vivac-reboot-other", "--available"):
        out.append(Entry("session", _t("power.reboot_windows"), "bridge",
                         shlex.join([str(bin_dir() / "vivac-reboot-other"), "--yes"]), True, GLYPH["windows"]))
    if (bin_dir() / "vivac-drop").exists() and _shared_root_set():
        drop = str(bin_dir() / "vivac-drop")
        out.append(Entry("session", _t("menu.drop_in"), "bridge", shlex.join([drop, "--open-in"]),
                         glyph=GLYPH["drop_in"]))
        out.append(Entry("session", _t("drop.send"), "bridge", shlex.join([drop, "--open-out"]),
                         glyph=GLYPH["drop_out"]))
    link = bin_dir() / "vivac-link"
    if link.exists() and (_state_dir() / "link.conf").exists():
        out.append(Entry("session", _t("link.send_clip"), "say", shlex.join([str(link), "send-clip"]),
                         glyph=GLYPH["link"], say=(_t("link.title"), "", "")))
        if (_state_dir() / "link-peer-mac").exists():
            out.append(Entry("session", _t("link.wake"), "say", shlex.join([str(link), "wake"]),
                             glyph=GLYPH["wake"], say=(_t("link.title"), "", "")))
    if _tool_ok("vivac-mouse", "available"):
        on = "enabled=yes" in _read(_state_dir() / "mouse.conf").split()
        out.append(Entry("session", _t("mouse.menu_on" if on else "mouse.menu_off"), "say",
                         shlex.join([str(bin_dir() / "vivac-mouse"), "toggle"]), glyph=GLYPH["mouse"],
                         say=(_t("mouse.title"), "", "")))
    if _tool_ok("vivac-hermes", "--available") and (term := _terminal()):
        out.append(Entry("session", _t("hermes.menu"), "bridge",
                         shlex.join([term, "-e", str(bin_dir() / "vivac-hermes")]), glyph=GLYPH["hermes"]))
    if (bin_dir() / "vivac-localsend").exists():
        send = str(bin_dir() / "vivac-localsend")
        out.append(Entry("session", _t("localsend.menu_send"), "bridge", shlex.join([send, "pick"]),
                         glyph=GLYPH["send"]))
        out.append(Entry("session", _t("localsend.menu_toggle"), "say", shlex.join([send, "toggle"]),
                         glyph=GLYPH["send"], say=(_t("localsend.title"), "", "")))
    return out


def _read(path: Path) -> str:
    try:
        return path.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return ""


def _shared_root_set() -> bool:
    """The shared settings folder is configured (shared_settings is not none)."""
    from .kit import settings

    value = settings().get("shared_settings", "")
    return bool(value) and value != "none"


# ----------------------------------------------------------------------- phone

_DEVICE_ID = re.compile(r"[A-Za-z0-9][A-Za-z0-9_-]{0,63}")


def _kdeconnect() -> str | None:
    return shutil.which(os.environ.get("VIVAC_KDECONNECT_CLI") or "kdeconnect-cli")


def phone_entries() -> list[Entry]:
    """Ring and send the clipboard to each reachable phone, and the phone's own
    menu (files, a link, pairing) while KDE Connect is installed. Asking
    KDE Connect can take a moment: the panel calls this off the main thread."""
    cli = _kdeconnect()
    if not cli:
        return []
    out: list[Entry] = []
    try:
        listed = subprocess.run([cli, "--list-available", "--id-name-only"], capture_output=True, text=True,
                                timeout=3).stdout
    except (OSError, subprocess.TimeoutExpired):
        listed = ""
    for line in listed.splitlines():
        ident, _, name = line.strip().partition(" ")
        if not _DEVICE_ID.fullmatch(ident):
            continue
        name = name.strip() or ident
        title = _t("phone.title")
        out.append(Entry("phone", _t("phone.ring"), "say", shlex.join([cli, "-d", ident, "--ring"]),
                         glyph=GLYPH["ring"], detail=name, say=(title, _t("phone.ringing", name), _t("phone.failed", name))))
        out.append(Entry("phone", _t("phone.send_clip"), "say", shlex.join([cli, "-d", ident, "--send-clipboard"]),
                         glyph=GLYPH["clip_send"], detail=name, say=(title, _t("phone.sent", name), _t("phone.failed", name))))
    out.append(Entry("phone", _t("phone.menu"), "run", shlex.join([resolve("vivac-phone") or "vivac-phone", "menu"]),
                     glyph=GLYPH["phone"], keywords="kde connect kdeconnect"))
    return out


# ------------------------------------------------------------------- catalogue

def catalog(slow: bool = True) -> list[Entry]:
    """Everything; with slow=False without what takes asking other programs
    (the bridge, the phone), which the panel adds when it arrives."""
    entries = (app_entries() + recent_entries() + folder_entries() + setting_entries() + tool_entries()
               + power_entries())
    return entries + bridge_entries() + phone_entries() if slow else entries


def group_label(group: str) -> str:
    return _label(f"menu.group.{group}")


def section_label(group: str) -> str:
    return _label(f"menu.section.{group}")


# ------------------------------------------------------------- search and order

def usage_path() -> Path:
    return _state_dir() / "menu-usage.tsv"


def usage_id(entry: Entry) -> str:
    return f"{entry.kind}|{entry.target}"


def read_usage() -> dict[str, int]:
    """count<TAB>kind|target per line, as the Windows menu writes it."""
    uses: dict[str, int] = {}
    for line in _read(usage_path()).splitlines():
        count, _, ident = line.partition("\t")
        if count.isdigit() and ident:
            uses[ident] = int(count)
    return uses


def add_use(entry: Entry) -> None:
    """Count an opening. Only apps, folders and tools: never a file's name,
    never a session action, never anything typed."""
    if entry.kind not in USAGE_KINDS:
        return
    uses = read_usage()
    ident = usage_id(entry)
    uses[ident] = uses.get(ident, 0) + 1
    top = sorted(uses.items(), key=lambda item: -item[1])[:USAGE_LIMIT]
    path = usage_path()
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        scratch = path.with_name(path.name + f".{os.getpid()}")
        scratch.write_text("".join(f"{count}\t{ident}\n" for ident, count in top), encoding="utf-8")
        os.replace(scratch, path)
    except OSError:
        pass


def by_use(entries: list[Entry], uses: dict[str, int]) -> list[Entry]:
    """Most used first; what was never used keeps the order it had."""
    return sorted(entries, key=lambda e: -uses.get(usage_id(e), 0))


def search(entries: list[Entry], query: str, uses: dict[str, int]) -> list[Entry]:
    """Every word typed must appear (name, keywords or category, accents and
    case ignored); a name that starts with a word comes first, then what is
    used most, then a name that merely contains it."""
    words = fold(query).split()
    if not words:
        return list(entries)
    ranked = []
    for index, entry in enumerate(entries):
        name = fold(entry.name)
        key = f"{name} {fold(entry.keywords)} {fold(group_label(entry.group))}"
        if not all(word in key for word in words):
            continue
        parts = name.split()
        bucket, fine = 0, 0
        for word in words:
            if name.startswith(word):
                continue
            if any(part.startswith(word) for part in parts):
                fine = max(fine, 1)
            elif word in name:
                bucket = max(bucket, 1)
            else:
                bucket = max(bucket, 2)
        ranked.append(((bucket, -uses.get(usage_id(entry), 0), fine, index), entry))
    ranked.sort(key=lambda item: item[0])
    return [entry for _, entry in ranked]


# ------------------------------------------------------------------ what runs

_SAY = ('out=$("${@:4}" 2>&1) && m=${out:-$2} || m=${out:-$3}; '
        '[ -n "$m" ] && command -v notify-send >/dev/null && notify-send --app-name=vivac -- "$1" "$m"; true')


def command_for(entry: Entry, query: str) -> list[str] | None:
    """The command that carries an entry out; None for an application, which
    Gio launches (with its own environment and startup notification)."""
    kind = entry.kind
    if kind == "app":
        return None
    if kind in ("folder", "path"):
        return ["xdg-open", entry.target]
    if kind in ("run", "bridge"):
        return shlex.split(entry.target)
    if kind == "say":
        title, ok, bad = entry.say or ("vivac", "", "")
        return ["bash", "-c", _SAY, "_", title, ok, bad, *shlex.split(entry.target)]
    if kind == "power":
        return {
            "lock": ["hyprlock"], "suspend": ["systemctl", "suspend"],
            "logout": [str(_dispatch()), "exit"], "reboot": ["systemctl", "reboot"],
            "poweroff": ["systemctl", "poweroff"],
        }.get(entry.target)
    if kind == "copy":
        return ["wl-copy", entry.target]
    if kind == "find-web":
        return ["xdg-open", "https://duckduckgo.com/?q=" + quote(query, safe="")]
    if kind == "run-text":
        return ["bash", "-c", query]
    return None


def launch(entry: Entry, query: str, context=None) -> bool:
    """Carry an entry out in a process of its own, so closing the panel
    leaves it running."""
    if entry.kind == "app":
        try:
            import gi

            gi.require_version("Gio", "2.0")
            from gi.repository import Gio

            info = Gio.DesktopAppInfo.new(entry.target)
            return bool(info and info.launch([], context))
        except Exception:
            return False
    argv = command_for(entry, query)
    if not argv:
        return False
    try:
        subprocess.Popen(argv, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                         stderr=subprocess.DEVNULL, start_new_session=True)
    except OSError:
        return False
    return True


def action_entries(query: str) -> list[Entry]:
    """What any text can be: run as typed, searched on the web."""
    return [
        Entry("actions", _t("menu.run", query), "run-text", query, glyph=GLYPH["run"],
              detail=_t("menu.action.run_text")),
        Entry("actions", _t("menu.find_web", query), "find-web", query, glyph=GLYPH["web"],
              detail=_t("menu.action.find_web")),
    ]


# ----------------------------------------------------------------------- panel

def _who() -> tuple[str, str]:
    """The person's full name (or login) and this machine's name."""
    login = os.environ.get("USER") or os.environ.get("LOGNAME") or ""
    name = login
    try:
        import pwd

        record = pwd.getpwuid(os.getuid())
        login = record.pw_name
        name = record.pw_gecos.split(",")[0].strip() or login
    except (ImportError, KeyError):
        pass
    return name, f"{login}@{socket.gethostname()}"


def main(category: str = "", text: str = "") -> int:
    from .kit import SETTINGS, T, gtk_kit, session_language

    k = gtk_kit()
    Gtk, Gdk, GLib = k.Gtk, k.Gdk, k.GLib
    comma = session_language(SETTINGS) in ("es", "ca", "gl", "fr", "de", "it", "pt")
    panel = k.Panel("menu", GLYPH["menu"], T("menu.title"), "",
                    hints=[("↑↓", T("menu.key.move")), ("Tab", T("menu.key.category")),
                           ("↵", T("menu.key.open")), ("Esc", T("menu.key.close"))], width=800)
    panel.centred = True
    state = {"all": [], "cat": category if category in GROUPS else "all", "index": 0, "nav": [],
             "armed": None, "uses": read_usage(), "scroll": None, "list": None, "rail": None, "entry": None,
             "power": []}
    OVERVIEW = 5   # rows per category in the opening view
    CAP = 80       # rows drawn in one list; the rest is a note

    def clear(box):
        child = box.get_first_child()
        while child:
            nxt = child.get_next_sibling()
            box.remove(child)
            child = nxt

    def query() -> str:
        return state["entry"].get_text().strip() if state["entry"] else ""

    def groups_present():
        have = {e.group for e in state["all"]}
        return [g for g in GROUPS if g in have]

    def categories():
        return ["all"] + groups_present()

    # ---- the view: what is listed for the query and the category -----------
    def compute():
        """[(heading, count, [Entry or ('calc', text, expr)]), ...] and the counts."""
        q, cat, uses = query(), state["cat"], state["uses"]
        sections, counts = [], {}
        if q:
            found = search(state["all"], q, uses)
            for e in found:
                counts[e.group] = counts.get(e.group, 0) + 1
            counts["all"] = len(found)
            shown = [e for e in found if cat == "all" or e.group == cat]
            result = calculation(q, comma)
            if result is not None:
                sections.append(("", 0, [("calc", result, q)]))
            if shown:
                sections.append((T("menu.section.results"), len(shown), shown))
            sections.append((T("menu.section.actions"), 0, action_entries(q)))
        else:
            for e in state["all"]:
                counts[e.group] = counts.get(e.group, 0) + 1
            counts["all"] = len(state["all"])
            if cat == "all":
                frequent = [e for e in by_use(state["all"], uses) if uses.get(usage_id(e), 0) > 0][:6]
                if frequent:
                    sections.append((T("menu.section.frequent"), 0, frequent))
                for g in groups_present():
                    members = [e for e in state["all"] if e.group == g]
                    sections.append((section_label(g), len(members), members[:OVERVIEW]))
            else:
                members = by_use([e for e in state["all"] if e.group == cat], uses)
                sections.append((section_label(cat), len(members), members))
        return sections, counts

    # ---- drawing ------------------------------------------------------------
    def note(text):
        lab = Gtk.Label(label=text, xalign=0, wrap=True)
        lab.add_css_class("empty")
        return lab

    def calc_widget(i, result, expr):
        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=2)
        top = Gtk.Box(spacing=8)
        big = Gtk.Label(label="= " + result, xalign=0, hexpand=True, ellipsize=3)
        big.add_css_class("calc-big")
        top.append(big)
        top.append(Gtk.Label(label="↵", css_classes=["key"], valign=Gtk.Align.CENTER) if i == state["index"] else Gtk.Box())
        box.append(top)
        sub = Gtk.Label(label=f"{expr} · {T('menu.action.copy')}", xalign=0, ellipsize=3)
        sub.add_css_class("calc-sub")
        box.append(sub)
        btn = Gtk.Button(child=box)
        btn.add_css_class("calc")
        if i == state["index"]:
            btn.add_css_class("selected")
        btn.set_focusable(False)
        btn.connect("clicked", lambda *_: (state.__setitem__("index", i), activate()))
        return btn

    def entry_row(i, e: Entry):
        armed = state["armed"] is not None and state["armed"] is e
        sub = T("menu.confirm") if armed else (e.detail or group_label(e.group))
        theme = Gtk.IconTheme.get_for_display(Gdk.Display.get_default())
        icon = e.icon if e.icon and (e.icon.startswith("/") or theme.has_icon(e.icon)) else None
        if icon and icon.startswith("/"):
            icon = None
        selected = i == state["index"]
        end = Gtk.Label(label="↵", css_classes=["key"], valign=Gtk.Align.CENTER) if selected else None
        r = k.row(e.glyph or GLYPH["apps"], e.name, sub, end=end, icon=icon, selected=selected,
                  on_activate=lambda i=i: (state.__setitem__("index", i), activate()))
        r.set_focusable(False)
        if armed:
            r.add_css_class("armed")
        return r

    def render():
        sections, counts = compute()
        box = state["list"]
        clear(box)
        nav = []
        flat = [item for _, _, items in sections for item in items]
        total_rows = len(flat)
        state["index"] = max(0, min(state["index"], max(0, total_rows - 1)))
        drawn_rows = []
        budget = CAP
        for heading, count, items in sections:
            if not items:
                continue
            visible = items[:budget] if budget > 0 else []
            if not visible:
                break
            if heading:
                box.append(k.section(heading, count or None))
            block = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=2)
            if not (len(visible) == 1 and isinstance(visible[0], tuple)):
                block.add_css_class("block")
            for item in visible:
                i = len(nav)
                nav.append(item)
                if isinstance(item, tuple):
                    w = calc_widget(i, item[1], item[2])
                else:
                    w = entry_row(i, item)
                drawn_rows.append(w)
                block.append(w)
            budget -= len(visible)
            box.append(block)
            hidden = (count or len(items)) - len(visible) if heading else 0
            if hidden > 0 and not query() and state["cat"] == "all":
                box.append(note(T("menu.more", hidden, heading)))
            elif hidden > 0:
                box.append(note(T("menu.more_typing", hidden)))
        state["nav"] = nav
        state["index"] = max(0, min(state["index"], max(0, len(nav) - 1)))
        calc_shown = bool(nav) and isinstance(nav[0], tuple)
        if query() and counts.get("all", 0) == 0 and not calc_shown:
            box.prepend(note(T("menu.none")))
        elif not state["all"]:
            box.append(note(T("menu.none")))
        shown_count = counts.get("all", 0) if query() else counts.get(state["cat"], 0) if state["cat"] != "all" else counts.get("all", 0)
        panel.subtitle.set_label("= " + nav[0][1] if calc_shown else
                                 T("menu.count_one") if shown_count == 1 else T("menu.count", shown_count))
        render_rail(counts)
        GLib.idle_add(lambda: (reveal(drawn_rows[state["index"]]) if drawn_rows else None, False)[1])

    def reveal(row):
        sw = state["scroll"]
        adj = sw.get_vadjustment()
        ok, rect = row.compute_bounds(sw.get_child().get_child() or row)
        if not ok:
            return
        top, bottom = rect.get_y(), rect.get_y() + rect.get_height()
        if top < adj.get_value():
            adj.set_value(max(0, top - 24))
        elif bottom > adj.get_value() + adj.get_page_size():
            adj.set_value(bottom - adj.get_page_size() + 8)

    def render_rail(counts):
        rail = state["rail"]
        clear(rail)
        name, login = _who()
        who = Gtk.Box(spacing=10)
        avatar = Gtk.Label(label=(name[:1] or "?").upper(), valign=Gtk.Align.CENTER)
        avatar.add_css_class("avatar")
        who.append(avatar)
        col = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, valign=Gtk.Align.CENTER, hexpand=True)
        n = Gtk.Label(label=name, xalign=0, ellipsize=3)
        n.add_css_class("name")
        s = Gtk.Label(label=login, xalign=0, ellipsize=3)
        s.add_css_class("sub")
        col.append(n)
        col.append(s)
        who.append(col)
        who.set_margin_bottom(8)
        rail.append(who)
        for number, group in enumerate(categories(), 1):
            glyph = Gtk.Label(label=GLYPH[group])
            glyph.add_css_class("glyph")
            title = Gtk.Label(label=T(f"menu.section.{group}"), xalign=0, hexpand=True, ellipsize=3)
            title.add_css_class("name")
            cnt = Gtk.Label(label=str(counts.get(group, 0)), valign=Gtk.Align.CENTER)
            cnt.add_css_class("count")
            inner = Gtk.Box(spacing=10)
            for w in (glyph, title, cnt):
                inner.append(w)
            b = Gtk.Button(child=inner)
            b.add_css_class("cat")
            if group == state["cat"]:
                b.add_css_class("on")
            if number <= 9:
                b.set_tooltip_text(f"Ctrl+{number}")
            b.set_focusable(False)
            b.connect("clicked", lambda _b, g=group: set_cat(g))
            rail.append(b)
        spacer = Gtk.Box(vexpand=True)
        rail.append(spacer)
        # The power buttons: lock and suspend at once, the rest on a second press.
        grid = Gtk.Box(spacing=4, homogeneous=True)
        for e in state["power"]:
            b = Gtk.Button(label=e.glyph)
            b.add_css_class("icon")
            armed = state["armed"] is e
            if armed:
                b.add_css_class("armed")
            b.set_tooltip_text(f"{e.name} · {T('menu.confirm')}" if armed else e.name)
            b.set_focusable(False)
            b.connect("clicked", lambda _b, e=e: act(e))
            grid.append(b)
        if state["power"]:
            rail.append(grid)

    # ---- actions --------------------------------------------------------------
    def set_cat(group):
        if group not in categories():
            return
        state["cat"] = group
        state["index"] = 0
        state["armed"] = None
        render()
        state["entry"].grab_focus_without_selecting()

    def move(step):
        if state["nav"]:
            state["index"] = max(0, min(len(state["nav"]) - 1, state["index"] + step))
            render()

    def act(item):
        """Carry out an entry; one that ends something asks for a second press."""
        if isinstance(item, tuple):
            e = Entry("actions", "= " + item[1], "copy", item[1])
        else:
            e = item
        if e.confirm and state["armed"] is not e:
            state["armed"] = e
            render()
            return
        q = query()
        add_use(e)
        context = Gdk.Display.get_default().get_app_launch_context() if e.kind == "app" else None
        launch(e, q, context)
        panel.window.close()

    def activate():
        if state["nav"]:
            act(state["nav"][state["index"]])

    def on_key(_ctl, keyval, _code, mods):
        ctrl = bool(mods & Gdk.ModifierType.CONTROL_MASK)
        if keyval in (Gdk.KEY_Down, Gdk.KEY_Up):
            state["armed"] = None
            move(1 if keyval == Gdk.KEY_Down else -1)
            return True
        if keyval in (Gdk.KEY_Page_Down, Gdk.KEY_Page_Up):
            state["armed"] = None
            move(6 if keyval == Gdk.KEY_Page_Down else -6)
            return True
        if keyval in (Gdk.KEY_Tab, Gdk.KEY_ISO_Left_Tab):
            cats = categories()
            step = -1 if keyval == Gdk.KEY_ISO_Left_Tab or mods & Gdk.ModifierType.SHIFT_MASK else 1
            set_cat(cats[(cats.index(state["cat"]) + step) % len(cats)] if state["cat"] in cats else "all")
            return True
        if ctrl and Gdk.KEY_1 <= keyval <= Gdk.KEY_9:
            cats = categories()
            if keyval - Gdk.KEY_1 < len(cats):
                set_cat(cats[keyval - Gdk.KEY_1])
            return True
        if keyval == Gdk.KEY_Escape:
            if state["entry"].get_text():
                state["entry"].set_text("")  # first Esc clears, the next closes
            else:
                panel.window.close()
            return True
        return False

    def on_changed(*_):
        state["index"] = 0
        state["armed"] = None
        render()

    # ---- the panel ------------------------------------------------------------
    def build(_panel):
        provider = Gtk.CssProvider()
        provider.load_from_string(extra_css(panel.p))
        Gtk.StyleContext.add_provider_for_display(Gdk.Display.get_default(), provider,
                                                  Gtk.STYLE_PROVIDER_PRIORITY_USER)
        root = Gtk.Box(spacing=16)
        root.set_margin_top(12)
        rail = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=2)
        rail.add_css_class("rail")
        rail.set_size_request(210, -1)
        state["rail"] = rail
        root.append(rail)
        right = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=8, hexpand=True)
        entry = Gtk.Entry(placeholder_text=T("menu.placeholder"), hexpand=True)
        entry.add_css_class("search")
        keys = Gtk.EventControllerKey()
        keys.set_propagation_phase(Gtk.PropagationPhase.CAPTURE)
        keys.connect("key-pressed", on_key)
        entry.add_controller(keys)
        entry.connect("changed", on_changed)
        entry.connect("activate", lambda *_: activate())
        state["entry"] = entry
        right.append(entry)
        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL)
        state["list"] = box
        state["scroll"] = k.scroller(box, 520)
        state["scroll"].set_min_content_height(520)
        right.append(state["scroll"])
        root.append(right)
        if text:
            entry.set_text(text)
        state["all"] = catalog(slow=False)
        state["power"] = [e for e in state["all"] if e.kind == "power" and e.target in ("lock", "suspend", "reboot", "poweroff")]
        if state["cat"] not in categories():
            state["cat"] = "all"
        render()
        GLib.idle_add(lambda: (entry.grab_focus_without_selecting(), False)[1])
        load_phone()
        return root

    def load_phone():
        """The bridge and KDE Connect answer slowly: their rows join the list when they arrive."""
        import threading

        def work():
            found = bridge_entries() + phone_entries()
            GLib.idle_add(lambda: (joined(found), False)[1])

        def joined(found):
            state["all"] = state["all"] + found
            if state["cat"] not in categories():
                state["cat"] = "all"
            render()

        threading.Thread(target=work, daemon=True).start()

    panel.on_build = build
    return panel.run()


def extra_css(p: dict[str, str]) -> str:
    """What only the menu draws: the category rail, the calculator, a row
    waiting for its second press."""
    return f"""
.vivac .rail {{ background: {p['surface']}; border-radius: 10px; padding: 10px 8px 8px 8px; }}
.vivac .avatar {{ min-width: 40px; min-height: 40px; border-radius: 20px; background: {p['accent']};
  color: {p['bg']}; font-size: 18px; font-weight: 700; }}
.vivac .rail .name {{ font-size: 13px; font-weight: 700; }}
.vivac .rail .sub {{ font-size: 11px; color: {p['textSecondary']}; }}
.vivac button.cat {{ border-radius: 8px; padding: 6px 8px; min-height: 34px; border: none; box-shadow: none;
  background: transparent; color: {p['text']}; }}
.vivac button.cat:hover {{ background: {p['surfaceAlt']}; }}
.vivac button.cat.on {{ background: {p['actionFill']}; color: {p['actionText']}; }}
.vivac button.cat.on .glyph, .vivac button.cat.on .name {{ color: {p['actionText']}; }}
.vivac button.cat.on .name {{ font-weight: 700; }}
.vivac button.cat .count {{ background: {p['surfaceAlt']}; color: {p['textSecondary']}; }}
.vivac button.cat.on .count {{ background: alpha({p['actionText']}, 0.2); color: {p['actionText']}; }}
.vivac button.calc {{ border: none; box-shadow: inset 0 0 0 2px {p['accent']}; border-radius: 10px;
  padding: 10px 14px; background: {p['surface']}; color: {p['text']}; }}
.vivac button.calc.selected {{ background: {p['actionFill']}; color: {p['actionText']}; box-shadow: none; }}
.vivac .calc-big {{ font-size: 28px; font-weight: 700; }}
.vivac .calc-sub {{ font-size: 11px; color: {p['textSecondary']}; }}
.vivac button.calc.selected .calc-sub {{ color: {p['actionText']}; }}
.vivac button.calc.selected .key {{ background: alpha({p['actionText']}, 0.18); color: {p['actionText']};
  box-shadow: none; }}
.vivac .row.armed, .vivac .row.selected.armed {{ background: {p['alert']}; color: {p['bg']}; }}
.vivac .row.armed .sub, .vivac .row.armed .glyph {{ color: {p['bg']}; font-weight: 700; }}
.vivac button.icon.armed {{ background: {p['alert']}; color: {p['bg']}; }}
.vivac .row.selected .key {{ background: alpha({p['actionText']}, 0.18); color: {p['actionText']};
  box-shadow: none; }}
"""
