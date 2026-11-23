"""Clipboard: what was copied, searchable, with secrets kept out of sight.

The Windows side's Show-Clipboard (windows/lib/Surfaces.psm1) over cliphist,
which already keeps the history (`wl-paste --watch cliphist store`, started
with the session). This module reads that history, never writes to it except to
forget entries, and never shows what looks like a secret: Windows hides what a
password manager marks as private (Test-ClipboardPrivate), and here, where
nothing marks it, the text itself is judged (looks_secret). A masked entry can
still be copied, it just never appears on screen, in a tooltip or in a search.

The pure half (entries, looks_secret, filtered, copy, forget) imports nothing
graphical; main() brings GTK in.
"""
from __future__ import annotations

import os
import re
import shutil
import subprocess
import unicodedata
from dataclasses import dataclass
from pathlib import Path

CLIPHIST = os.environ.get("VIVAC_CLIPHIST", "cliphist")
WLCOPY = os.environ.get("VIVAC_WLCOPY", "wl-copy")
LIMIT = 60  # entries read: each text one is decoded to count and judge it
MASK = "•" * 8  # always the same length: it must not tell the secret's
READ_CAP = 64 * 1024  # characters of an entry read to judge it

GLYPH_TEXT, GLYPH_IMAGE, GLYPH_LOCK, GLYPH_CLIP = "\U000F0219", "\U000F021F", "\U000F033E", "\U000F014C"
GLYPH_LINK, GLYPH_TRASH = "\U000F0337", "\U000F01B4"

_IMAGE = re.compile(r"^\[\[ binary data (?P<size>\S+ \S+) (?P<fmt>\w+) (?P<w>\d+)x(?P<h>\d+) \]\]$")
_MAGIC = ((b"\x89PNG", "image/png"), (b"\xff\xd8\xff", "image/jpeg"), (b"GIF8", "image/gif"),
          (b"BM", "image/bmp"), (b"RIFF", "image/webp"))


@dataclass
class Entry:
    id: str
    line: str  # cliphist's own line: what delete and decode take back
    kind: str  # "text" | "image"
    first: str = ""
    lines: int = 1
    chars: int = 0
    private: bool = False
    text: str = ""
    width: int = 0
    height: int = 0
    size: str = ""
    fmt: str = ""


def available() -> bool:
    return shutil.which(CLIPHIST) is not None


def _run(args: list[str], data: bytes | None = None) -> bytes | None:
    try:
        done = subprocess.run(args, input=data, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=8)
    except (OSError, subprocess.TimeoutExpired):
        return None
    return done.stdout if done.returncode == 0 else None


def decode(entry: Entry) -> bytes:
    return _run([CLIPHIST, "decode"], (entry.line + "\n").encode()) or b""


# ------------------------------------------------------------------ secrets

_TOKENS = re.compile(
    r"(?:\bgh[pousr]_[A-Za-z0-9]{20,}|\bgithub_pat_[A-Za-z0-9_]{20,}|\bglpat-[A-Za-z0-9_-]{16,}"
    r"|\bsk-[A-Za-z0-9_-]{16,}|\b[sr]k_(?:live|test)_[A-Za-z0-9]{12,}|\bxox[abprs]-[A-Za-z0-9-]{10,}"
    r"|\b(?:AKIA|ASIA)[0-9A-Z]{16}\b|\bAIza[0-9A-Za-z_-]{30,}|\bnpm_[A-Za-z0-9]{30,}"
    r"|\beyJ[A-Za-z0-9_-]{8,}\.eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}"
    r"|-----BEGIN [A-Z ]*PRIVATE KEY(?: BLOCK)?-----)")
_ASSIGNED = re.compile(
    r"(?i)\b[\w.-]*(?:pass(?:word|wd|phrase)?|pwd|secret|token|api[_-]?key|access[_-]?key|private[_-]?key"
    r"|auth(?:orization)?|bearer|credential)[\w.-]*\s*[:=]\s*\S+")
_BEARER = re.compile(r"(?i)\bbearer\s+[A-Za-z0-9._~+/=-]{8,}")


def _luhn(digits: str) -> bool:
    total = 0
    for index, ch in enumerate(reversed(digits)):
        d = int(ch)
        if index % 2:
            d = d * 2 - 9 if d > 4 else d * 2
        total += d
    return total % 10 == 0


def looks_secret(text: str) -> bool:
    """A password, token, key, credential assignment or card number. Judged on
    the text alone; a false alarm only costs a masked row, a miss costs a leak."""
    body = text[:READ_CAP].strip()
    if not body:
        return False
    if _TOKENS.search(body) or _ASSIGNED.search(body) or _BEARER.search(body):
        return True
    digits = re.sub(r"[ -]", "", body)
    if re.fullmatch(r"[ \d-]{13,23}", body) and 13 <= len(digits) <= 19 and _luhn(digits):
        return True
    # One word with no meaning of its own: 8-64 characters mixing at least
    # three of lower, upper, digit and symbol; not a link or a path.
    if re.fullmatch(r"\S{8,64}", body) and "://" not in body and not body.startswith(("/", "~", "./", "../")):
        classes = sum(bool(re.search(p, body)) for p in (r"[a-z]", r"[A-Z]", r"\d", r"[^\w\s]"))
        if classes >= 3:
            return True
        if len(body) >= 40 and re.fullmatch(r"[A-Za-z0-9+/=_-]+", body) and not re.fullmatch(r"[0-9a-fA-F]+", body) \
                and classes >= 2 and re.search(r"[A-Z]", body) and re.search(r"\d", body):
            return True
    return False


def shown(entry: Entry) -> str:
    """What may be drawn for the entry: its first line, or the mask."""
    return MASK if entry.private else entry.first


# ------------------------------------------------------------------ history

def _text_entry(entry_id: str, line: str, preview: str) -> Entry:
    entry = Entry(entry_id, line, "text", first=preview.strip(), chars=len(preview), text="")
    raw = _run([CLIPHIST, "decode"], (line + "\n").encode())
    if raw is None:
        return entry
    text = raw.decode("utf-8", errors="replace")
    stripped = text.strip()
    entry.text = text[:READ_CAP]
    entry.chars = len(text)
    entry.lines = max(1, len(stripped.splitlines()))
    entry.first = next((ln.strip() for ln in stripped.splitlines() if ln.strip()), "")
    entry.private = looks_secret(text)
    return entry


def entries(limit: int = LIMIT) -> list[Entry]:
    """Newest first, as cliphist lists them. Empty when cliphist is missing."""
    raw = _run([CLIPHIST, "list"])
    if raw is None:
        return []
    out: list[Entry] = []
    for line in raw.decode("utf-8", errors="replace").splitlines():
        entry_id, tab, preview = line.partition("\t")
        if not tab or not entry_id.strip().isdigit():
            continue
        match = _IMAGE.match(preview.strip())
        if match:
            out.append(Entry(entry_id, line, "image", first=preview.strip(), width=int(match["w"]),
                             height=int(match["h"]), size=match["size"], fmt=match["fmt"]))
        else:
            out.append(_text_entry(entry_id, line, preview))
        if len(out) >= limit:
            break
    return out


_LINK = re.compile(r"(?:https?|ftp)://\S+")
KINDS = ("all", "text", "link", "image", "private")


def kind_of(entry: Entry) -> str:
    """The chip an entry belongs to: private (looks like a secret), image,
    link (one URL and nothing else) or text."""
    if entry.private:
        return "private"
    if entry.kind == "image":
        return "image"
    return "link" if _LINK.fullmatch(entry.first) and entry.lines == 1 else "text"


def counts(items: list[Entry]) -> dict[str, int]:
    found = {k: 0 for k in KINDS}
    found["all"] = len(items)
    for e in items:
        found[kind_of(e)] += 1
    return found


def by_kind(items: list[Entry], kind: str) -> list[Entry]:
    return list(items) if kind == "all" else [e for e in items if kind_of(e) == kind]


def _key(text: str) -> str:
    """Case and accents ignored (ConvertTo-MenuKey on the Windows side)."""
    decomposed = unicodedata.normalize("NFKD", text.casefold())
    return "".join(ch for ch in decomposed if not unicodedata.combining(ch))


def filtered(items: list[Entry], needle: str) -> list[Entry]:
    """Text entries containing the needle. A secret or a picture never matches,
    so typing cannot be used to feel one out."""
    needle = _key(needle.strip())
    if not needle:
        return list(items)
    return [e for e in items if e.kind == "text" and not e.private and needle in _key(e.text or e.first)]


def copy(entry: Entry) -> bool:
    """Put the entry back on the clipboard, a picture with its own type."""
    data = decode(entry)
    if not data:
        return False
    args = [WLCOPY]
    if entry.kind == "image":
        args += ["--type", next((mime for magic, mime in _MAGIC if data.startswith(magic)), "image/png")]
    try:  # wl-copy stays behind to serve the data: do not wait on its pipes
        subprocess.run(args, input=data, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=8)
    except (OSError, subprocess.TimeoutExpired):
        return False
    return True


def forget(entry: Entry) -> bool:
    return _run([CLIPHIST, "delete"], (entry.line + "\n").encode()) is not None


def forget_all() -> bool:
    return _run([CLIPHIST, "wipe"]) is not None


def thumbnail(entry: Entry) -> Path | None:
    """A picture entry written to the runtime dir (never next to the history)."""
    base = Path(os.environ.get("XDG_RUNTIME_DIR") or f"/tmp/vivac-{os.getuid()}") / "vivac-clipboard"
    try:
        base.mkdir(mode=0o700, parents=True, exist_ok=True)
        target = base / f"{entry.id}.{entry.fmt or 'png'}"
        if not target.exists():
            data = decode(entry)
            if not data:
                return None
            target.write_bytes(data)
        return target
    except OSError:
        return None


# ------------------------------------------------------------------ the panel

def _css(p: dict[str, str]) -> str:
    return f"""
.vivac .clip-search-count {{ font-size: 12px; color: {p['textSecondary']}; margin-right: 14px; }}
.vivac button.clip-chip {{ min-height: 28px; padding: 0 10px; border-radius: 8px; border: none; box-shadow: none;
  background: {p['surface']}; color: {p['text']}; font-size: 12px; }}
.vivac button.clip-chip:hover {{ background: {p['surfaceAlt']}; }}
.vivac button.clip-chip.sel {{ background: {p['actionFill']}; color: {p['actionText']}; font-weight: 700; }}
.vivac .clip-chip-n {{ color: {p['textSecondary']}; }}
.vivac button.clip-chip.sel .clip-chip-n {{ color: {p['actionText']}; }}
.vivac button.clip-forget-all {{ min-height: 28px; padding: 0 10px; border-radius: 8px; box-shadow: none;
  background: transparent; color: {p['alert']}; border: 1px solid {p['alert']}; font-size: 12px; }}
.vivac button.clip-forget-all:hover {{ background: {p['alert']}; color: {p['bg']}; }}
.vivac .clip-detail {{ background: {p['surface']}; border-radius: 12px; padding: 14px; }}
.vivac .clip-kind {{ font-size: 12px; color: {p['textSecondary']}; }}
.vivac .clip-preview {{ background: {p['bg']}; border-radius: 10px; padding: 12px; font-size: 13px; color: {p['text']}; }}
.vivac .clip-preview.mask {{ color: {p['accent']}; letter-spacing: 2px; }}
.vivac .clip-stat {{ font-size: 12px; color: {p['textSecondary']}; }}
.vivac .clip-detail button.action {{ min-height: 32px; }}
"""


def main() -> int:
    from .kit import T, gtk_kit

    k = gtk_kit()
    Gtk, GLib, Gdk = k.Gtk, k.GLib, k.Gdk
    panel = k.Panel("clipboard", GLYPH_CLIP, T("clip.title"), "",
                    hints=[("\u2191\u2193", T("clip.key.select")), ("\u21b5", T("clip.key.copy")),
                           (T("clip.key.del"), T("clip.key.forget")), ("\u21e7" + T("clip.key.del"), T("clip.key.forget_all")),
                           ("Esc", T("clip.key.close")), ("Tab", T("clip.key.filter"))], width=820)
    panel.centred = True
    p = panel.p
    provider = Gtk.CssProvider()
    provider.load_from_string(_css(p))
    Gtk.StyleContext.add_provider_for_display(Gdk.Display.get_default(), provider,
                                              Gtk.STYLE_PROVIDER_PRIORITY_USER + 1)
    state = {"all": [], "shown": [], "index": 0, "filter": "all", "scroll": None, "list": None,
             "chips": None, "detail": None, "entry": None, "count": None}
    chip_names = {"all": "clip.f.all", "text": "clip.f.text", "link": "clip.f.link",
                  "image": "clip.f.image", "private": "clip.f.private"}
    kind_glyph = {"text": GLYPH_TEXT, "link": GLYPH_LINK, "image": GLYPH_IMAGE, "private": GLYPH_LOCK}

    def clear(box):
        child = box.get_first_child()
        while child:
            nxt = child.get_next_sibling()
            box.remove(child)
            child = nxt

    def describe(e: Entry) -> tuple[str, str]:
        if e.kind == "image":
            return T("clip.image", e.width, e.height), e.size
        if e.private:
            return MASK, T("clip.private_sub")
        parts = []
        if e.lines > 1:
            parts.append(T("clip.lines", e.lines - 1))
        parts.append(T("clip.chars", e.chars))
        return e.first, " \u00b7 ".join(parts)

    thumbs: dict = {}

    def picture(path, w: int, h: int):
        """The picture scaled down to fit w x h, so its own size never stretches the row."""
        try:
            import gi

            gi.require_version("GdkPixbuf", "2.0")
            from gi.repository import GdkPixbuf

            pix = GdkPixbuf.Pixbuf.new_from_file_at_scale(str(path), w, h, True)
        except Exception:  # a picture the loader cannot read: the glyph alone
            return None
        img = Gtk.Image.new_from_paintable(Gdk.Texture.new_for_pixbuf(pix))
        img.set_valign(Gtk.Align.CENTER)
        return img

    def row_for(i: int, e: Entry):
        name, sub = describe(e)
        end = None
        if e.kind == "image" and i < 12 and (path := thumbs.setdefault(e.id, thumbnail(e))):
            end = picture(path, 96, 44)
        elif e.private:
            end = k.badge(T("clip.private"), "warn")
        r = k.row(kind_glyph[kind_of(e)], name, sub, end=end, selected=(i == state["index"]),
                  on_activate=lambda i=i: select(i))  # no tooltip: a secret is never shown
        r.set_focusable(False)
        return r

    def select(i: int):
        state["index"] = i
        render()

    def set_filter(kind: str):
        state["filter"] = kind
        state["index"] = 0
        render()

    def draw_chips():
        box = state["chips"]
        clear(box)
        n = counts(state["all"])
        for kind in KINDS:
            inner = Gtk.Box(spacing=6)
            inner.append(Gtk.Label(label=T(chip_names[kind])))
            c = Gtk.Label(label=str(n[kind]))
            c.add_css_class("clip-chip-n")
            inner.append(c)
            b = Gtk.Button(child=inner)
            b.add_css_class("clip-chip")
            b.set_focusable(False)
            if kind == state["filter"]:
                b.add_css_class("sel")
            b.connect("clicked", lambda *_, kind=kind: set_filter(kind))
            box.append(b)

    def draw_detail():
        box = state["detail"]
        clear(box)
        shown_now = state["shown"]
        if not shown_now:
            return
        e = shown_now[state["index"]]
        kind = kind_of(e)
        head = Gtk.Box(spacing=8)
        cap = Gtk.Label(label=T("clip.preview").upper(), xalign=0, hexpand=True)
        cap.add_css_class("section")
        cap.set_margin_start(0)
        cap.set_margin_top(0)
        cap.set_margin_bottom(0)
        head.append(cap)
        tag = Gtk.Label(label=f"{kind_glyph[kind]}  {T('clip.kind.' + kind)}")
        tag.add_css_class("clip-kind")
        head.append(tag)
        box.append(head)
        body = None
        if kind == "image" and (path := thumbs.setdefault(e.id, thumbnail(e))):
            body = picture(path, 250, 220)
        if body is None:
            body = Gtk.Label(label=MASK if e.private else (e.text or e.first), xalign=0, yalign=0,
                             wrap=True, wrap_mode=2, selectable=False)  # Pango.WrapMode.WORD_CHAR
            body.add_css_class("clip-preview")
            if e.private:
                body.add_css_class("mask")
        wrap = Gtk.ScrolledWindow(hscrollbar_policy=Gtk.PolicyType.NEVER, vexpand=True)
        wrap.set_min_content_height(220)
        wrap.set_child(body)
        box.append(wrap)
        stats = Gtk.Box(spacing=16)
        if e.kind == "image":
            parts = [f"{e.width}\u00d7{e.height}", e.size]
        elif e.private:
            parts = [T("clip.private_sub")]
        else:
            parts = [T("clip.n_lines", e.lines), T("clip.chars", e.chars)]
        for text in parts:
            lab = Gtk.Label(label=text, xalign=0)
            lab.add_css_class("clip-stat")
            stats.append(lab)
        box.append(stats)
        buttons = Gtk.Box(spacing=8)
        cp = Gtk.Button(label=T("clip.copy") + "  \u21b5", hexpand=True)
        cp.add_css_class("action")
        cp.add_css_class("primary")
        cp.set_focusable(False)
        cp.connect("clicked", lambda *_: choose(e))
        fg = Gtk.Button(label=f"{GLYPH_TRASH}  " + T("clip.forget"))
        fg.add_css_class("action")
        fg.add_css_class("danger")
        fg.set_focusable(False)
        fg.connect("clicked", lambda *_: (forget(e), reload()))
        buttons.append(cp)
        buttons.append(fg)
        box.append(buttons)

    def reload():
        state["all"] = entries()
        render()

    def render():
        box = state["list"]
        clear(box)
        draw_chips()
        pool = by_kind(state["all"], state["filter"])
        state["shown"] = filtered(pool, state["entry"].get_text())
        state["index"] = max(0, min(state["index"], len(state["shown"]) - 1))
        total, count = len(state["all"]), len(state["shown"])
        panel.subtitle.set_label(T("clip.count", total))
        state["count"].set_label(T("clip.of", count, total))
        draw_detail()
        if not available():
            msg = T("clip.missing")
        elif not total:
            msg = T("clip.none")
        elif not count:
            msg = T("clip.no_match")
        else:
            msg = ""
        if msg:
            lab = Gtk.Label(label=msg, xalign=0, wrap=True)
            lab.add_css_class("empty")
            box.append(lab)
            return
        block = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=2)
        block.add_css_class("block")
        rows = []
        for i, e in enumerate(state["shown"]):
            r = row_for(i, e)
            rows.append(r)
            block.append(r)
        box.append(block)
        GLib.idle_add(lambda: (reveal(rows[state["index"]]) if rows else None, False)[1])

    def reveal(row):
        sw = state["scroll"]
        adj = sw.get_vadjustment()
        ok, rect = row.compute_bounds(sw.get_child().get_child() or row)
        if not ok:
            return
        top, bottom = rect.get_y(), rect.get_y() + rect.get_height()
        if top < adj.get_value():
            adj.set_value(top - 4)
        elif bottom > adj.get_value() + adj.get_page_size():
            adj.set_value(bottom - adj.get_page_size() + 4)

    def choose(e: Entry):
        if copy(e):
            panel.window.close()

    def on_key(_ctl, keyval, _code, mods):
        shown_now = state["shown"]
        if keyval in (Gdk.KEY_Down, Gdk.KEY_Up):
            if shown_now:
                step = 1 if keyval == Gdk.KEY_Down else -1
                state["index"] = max(0, min(len(shown_now) - 1, state["index"] + step))
                render()
            return True
        if keyval in (Gdk.KEY_Tab, Gdk.KEY_ISO_Left_Tab):
            back = keyval == Gdk.KEY_ISO_Left_Tab or bool(mods & Gdk.ModifierType.SHIFT_MASK)
            set_filter(KINDS[(KINDS.index(state["filter"]) + (-1 if back else 1)) % len(KINDS)])
            return True
        if keyval in (Gdk.KEY_Delete, Gdk.KEY_KP_Delete):
            if mods & Gdk.ModifierType.SHIFT_MASK:
                forget_all()
            elif shown_now:
                forget(shown_now[state["index"]])
            else:
                return True
            reload()
            return True
        return False

    def build(_panel):
        wipe = Gtk.Button(label=f"{GLYPH_TRASH}  " + T("clip.key.forget_all").capitalize())
        wipe.add_css_class("clip-forget-all")
        wipe.set_focusable(False)
        wipe.connect("clicked", lambda *_: (forget_all(), reload()))
        panel.header_end.append(wipe)
        root = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=10)
        root.set_margin_top(12)
        entry = Gtk.Entry(placeholder_text=T("clip.search"), hexpand=True)
        entry.add_css_class("search")
        entry.set_tooltip_text(None)
        keys = Gtk.EventControllerKey()
        keys.set_propagation_phase(Gtk.PropagationPhase.CAPTURE)
        keys.connect("key-pressed", on_key)
        entry.add_controller(keys)
        entry.connect("changed", lambda *_: (state.__setitem__("index", 0), render()))
        entry.connect("activate", lambda *_: state["shown"] and choose(state["shown"][state["index"]]))
        state["entry"] = entry
        count = Gtk.Label(label="", halign=Gtk.Align.END, valign=Gtk.Align.CENTER, can_target=False)
        count.add_css_class("clip-search-count")
        state["count"] = count
        over = Gtk.Overlay()
        over.set_child(entry)
        over.add_overlay(count)
        root.append(over)
        main_row = Gtk.Box(spacing=14)
        left = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=8, hexpand=True)
        left.set_size_request(470, -1)
        state["chips"] = Gtk.Box(spacing=6)
        left.append(state["chips"])
        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL)
        state["list"] = box
        state["scroll"] = k.scroller(box, 480)
        left.append(state["scroll"])
        main_row.append(left)
        detail = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=10, valign=Gtk.Align.START)
        detail.add_css_class("clip-detail")
        detail.set_size_request(290, -1)
        state["detail"] = detail
        main_row.append(detail)
        root.append(main_row)
        state["all"] = entries()
        render()
        GLib.idle_add(lambda: (entry.grab_focus(), False)[1])
        return root

    panel.on_build = build
    return panel.run()
