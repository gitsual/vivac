"""USB: the removable drives, to open or to take out safely.

The Windows side's usbPill (windows/static/zebar/vivac/bar.js) on udisks2:
one entry per volume of every removable disk, lsblk saying what is plugged
and udisksctl doing the mounting, unmounting and powering off. Taking a
drive out unmounts every volume it has, powers the disk off and says "it can
be removed" in a notification, as Windows does. Nothing here keeps state of
its own: what lsblk shows is what there is.
"""
from __future__ import annotations

import json
import subprocess
import sys
import threading
from dataclasses import dataclass

GLYPH_USB, GLYPH_DISK, GLYPH_EJECT = "\U000F129E", "\U000F02CA", "\U000F01EA"
HIDDEN_FS = {"swap", "crypto_LUKS", "LVM2_member", "linux_raid_member", "zfs_member"}
COLUMNS = "NAME,PATH,PKNAME,LABEL,MODEL,SIZE,FSUSE%,FSTYPE,MOUNTPOINT,RM,HOTPLUG,TRAN,TYPE"


@dataclass
class Drive:
    path: str  # the volume: /dev/sdb1
    disk: str  # what powers off: /dev/sdb
    name: str
    size: int
    fstype: str = ""
    mount: str | None = None
    used_pct: int | None = None
    model: str = ""

    @property
    def mounted(self) -> bool:
        return bool(self.mount)


def _run(*cmd: str, timeout: float = 20.0) -> tuple[int, str, str]:
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
        return r.returncode, r.stdout, r.stderr
    except (OSError, subprocess.TimeoutExpired) as exc:
        return 127, "", str(exc)


def _flag(value) -> bool:
    """lsblk says rm/hotplug as true/false or "1"/"0" by version."""
    return value is True or str(value).strip().lower() in ("1", "true")


def _int(value) -> int:
    try:
        return int(value)
    except (TypeError, ValueError):
        return 0


def human(size: int, comma: bool = False) -> str:
    """Decimal units, as the drive's box says them: 30 GB, 1,9 TB."""
    value, unit = float(size), "B"
    for unit in ("B", "kB", "MB", "GB", "TB"):
        if value < 1000 or unit == "TB":
            break
        value /= 1000
    text = f"{value:.0f}" if unit == "B" or value >= 100 else f"{value:.1f}".removesuffix(".0")
    return f"{text.replace('.', ',') if comma else text} {unit}"


def drives() -> list[Drive]:
    """Volumes of the removable disks (USB, SD readers, anything the kernel
    marks removable or hot-pluggable). An internal disk never is one."""
    code, out, _ = _run("lsblk", "-b", "-J", "-o", COLUMNS, timeout=5)
    if code != 0:
        return []
    try:
        devices = json.loads(out).get("blockdevices", [])
    except (json.JSONDecodeError, AttributeError):
        return []
    found: list[Drive] = []
    for disk in devices:
        if disk.get("type") != "disk":
            continue
        if not (_flag(disk.get("rm")) or _flag(disk.get("hotplug")) or disk.get("tran") == "usb"):
            continue
        if not _int(disk.get("size")):  # a card reader with no card in it
            continue
        model = (disk.get("model") or "").strip()
        volumes = [c for c in disk.get("children") or [] if c.get("type") == "part"]
        if not volumes:
            volumes = [disk]
        volumes = [v for v in volumes if (v.get("fstype") or "") not in HIDDEN_FS]
        if not volumes:
            continue
        for v in volumes:
            label = (v.get("label") or "").strip()
            base = v.get("name") or ""
            name = label or (model if len(volumes) == 1 else f"{model} · {base}" if model else base) or base
            pct = str(v.get("fsuse%") or "").rstrip("%")
            found.append(Drive(path=v.get("path") or f"/dev/{base}", disk=disk.get("path") or f"/dev/{disk.get('name')}",
                               name=name, size=_int(v.get("size")), fstype=v.get("fstype") or "",
                               mount=v.get("mountpoint") or None, used_pct=int(pct) if pct.isdigit() else None,
                               model=model))
    return found


def waybar(args: list[str]) -> int:
    """One JSON line for the bar: nothing without drives; the USB glyph, a
    count when there are several, and each drive's name, size and mount point
    in the tooltip."""
    from .kit import T

    found = drives()
    if not found:
        print(json.dumps({"text": "", "tooltip": "", "class": "hidden"}))
        return 0
    text = GLYPH_USB + (f" {len(found)}" if len(found) > 1 else "")
    lines = [f"{d.name} · {human(d.size)} · {d.mount or T('usb.tip_unmounted')}" for d in found]
    print(json.dumps({"text": text, "tooltip": "\n".join(lines), "class": "usb"}, ensure_ascii=False))
    return 0


def open_drive(drive: Drive) -> str | None:
    """Open the drive in the file manager, mounting it first when it is not.
    Returns None, or why it could not."""
    mount = drive.mount
    if not mount:
        code, out, err = _run("udisksctl", "mount", "-b", drive.path)
        if code != 0:
            return (err or out).strip().splitlines()[-1] if (err or out).strip() else "mount failed"
        if " at " not in out:
            return out.strip() or "mount failed"
        mount = out.strip().rsplit(" at ", 1)[1].rstrip(".")
        drive.mount = mount
    try:
        subprocess.Popen(["xdg-open", mount], start_new_session=True,
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    except OSError as exc:
        return str(exc)
    return None


def eject(drive: Drive) -> str:
    """Unmount every mounted volume of the drive's disk, then power it off:
    "done", "busy" (something has it open: nothing is powered off), "gone"
    (it was pulled already) or "failed"."""
    siblings = [d for d in drives() if d.disk == drive.disk and d.mounted] or ([drive] if drive.mounted else [])
    for d in siblings:
        code, out, err = _run("udisksctl", "unmount", "-b", d.path)
        low = (err + out).lower()
        if code != 0 and "not mounted" not in low:
            if "busy" in low:
                return "busy"
            if "no such" in low or "looking up object" in low or "not a block" in low:
                return "gone"
            return "failed"
    code, out, err = _run("udisksctl", "power-off", "-b", drive.disk)
    low = (err + out).lower()
    if code != 0 and ("no such" in low or "looking up object" in low):
        return "gone"
    # A stick that cannot power off is still unmounted and safe to pull.
    return "done"


def eject_and_notify(drive: Drive) -> str:
    from .kit import T

    result = eject(drive)
    message = {"done": T("usb.eject_done", drive.name), "busy": T("usb.eject_busy", drive.name),
               "gone": T("usb.eject_gone", drive.name),
               "failed": T("usb.eject_failed", drive.name, "udisksctl")}[result]
    _run("notify-send", "-a", "vivac", "-i", "drive-removable-media-usb" if result == "done" else "dialog-warning",
         T("usb.title"), message, timeout=5)
    return result


def _css(p: dict[str, str]) -> str:
    return f"""
.vivac .usb-card {{ background: {p['surface']}; border-radius: 12px; padding: 8px 6px 4px 6px; }}
.vivac .usb-head {{ background: transparent; }}
.vivac .usb-ring-pct {{ font-size: 24px; font-weight: 700; color: {p['text']}; }}
.vivac .usb-legend {{ font-size: 13px; color: {p['text']}; }}
.vivac .usb-legend-val {{ font-size: 13px; font-weight: 700; color: {p['text']}; }}
.vivac .usb-swatch-accent {{ background: {p['accent']}; border-radius: 3px; }}
.vivac .usb-swatch-surfaceAlt {{ background: {p['surfaceAlt']}; border-radius: 3px; }}
.vivac .usb-path {{ font-size: 12px; background: {p['bg']}; color: {p['textSecondary']};
  border-radius: 8px; padding: 6px 10px; }}
.vivac .usb-card button.action {{ min-height: 32px; }}
.vivac .usb-card button.action.primary:focus-visible {{ box-shadow: 0 0 0 2px {p['bg']}, 0 0 0 4px {p['focusRing']}; }}
"""


def main() -> int:
    from .draw import widgets
    from .kit import SETTINGS, T, gtk_kit, session_language

    k = gtk_kit()
    Gtk, GLib = k.Gtk, k.GLib
    comma = session_language(SETTINGS) != "en"
    panel = k.Panel("usb", GLYPH_USB, T("usb.title"), "",
                    hints=[("Tab", T("usb.key.move")), ("Enter", T("usb.key.open")),
                           ("Esc", T("usb.key.close"))], width=440)
    p = panel.p
    drawn = widgets(Gtk, p)
    provider = Gtk.CssProvider()
    provider.load_from_string(_css(p))
    Gtk.StyleContext.add_provider_for_display(k.Gdk.Display.get_default(), provider,
                                              Gtk.STYLE_PROVIDER_PRIORITY_USER + 1)
    state = {"sig": None, "working": set(), "root": None}

    def clear(box):
        child = box.get_first_child()
        while child:
            nxt = child.get_next_sibling()
            box.remove(child)
            child = nxt

    def act(drive, what):
        if what == "open":
            why = open_drive(drive)
            if why:
                _run("notify-send", "-a", "vivac", "-i", "dialog-warning", T("usb.title"),
                     T("usb.open_failed", drive.name, why), timeout=5)
            else:
                panel.window.close()
            return
        state["working"].add(drive.path)
        fill()

        def work():
            eject_and_notify(drive)
            GLib.idle_add(lambda: (state["working"].discard(drive.path), fill(True), False)[2])
        threading.Thread(target=work, daemon=True).start()

    def card(d):
        working = d.path in state["working"]
        block = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=10)
        block.add_css_class("usb-card")
        status = k.badge(("\u2713 " + T("usb.mounted")) if d.mounted else T("usb.unmounted"),
                         "ok" if d.mounted else "info")
        sub = " \u00b7 ".join(x for x in (d.fstype.upper() if d.fstype else T("usb.blank"), human(d.size, comma)) if x)
        head = k.row(GLYPH_DISK, d.name, sub, end=status, tooltip=d.mount or d.path)
        head.add_css_class("usb-head")
        block.append(head)
        if d.mounted and d.used_pct is not None:
            body = Gtk.Box(spacing=16)
            body.set_margin_start(8)
            body.set_margin_end(8)
            ring = drawn.Ring(size=96, thickness=12, fraction=d.used_pct / 100,
                              kind="alert" if d.used_pct >= 90 else "")
            over = Gtk.Overlay(valign=Gtk.Align.CENTER)
            over.set_child(ring)
            centre = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, halign=Gtk.Align.CENTER, valign=Gtk.Align.CENTER)
            pct = Gtk.Label()
            pct.add_css_class("usb-ring-pct")
            pct.set_markup(f'{d.used_pct}<span size="small" foreground="{p["textSecondary"]}">%</span>')
            word = Gtk.Label(label=T("usb.used_word"))
            word.add_css_class("subtitle")
            centre.append(pct)
            centre.append(word)
            over.add_overlay(centre)
            body.append(over)
            side = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=8, valign=Gtk.Align.CENTER, hexpand=True)
            used_bytes = d.size * d.used_pct // 100
            for colour, text, value in (("accent", T("usb.used_label"), used_bytes),
                                        ("surfaceAlt", T("usb.free_label"), d.size - used_bytes)):
                line = Gtk.Box(spacing=8)
                swatch = Gtk.Box(valign=Gtk.Align.CENTER)
                swatch.add_css_class("usb-swatch-" + colour)
                swatch.set_size_request(12, 12)
                line.append(swatch)
                lab = Gtk.Label(label=text, xalign=0, hexpand=True)
                lab.add_css_class("usb-legend")
                line.append(lab)
                val = Gtk.Label(label=human(value, comma), xalign=1)
                val.add_css_class("usb-legend-val")
                line.append(val)
                side.append(line)
            path = Gtk.Label(label="\U000F0770  " + d.mount, xalign=0, ellipsize=2)  # middle
            path.add_css_class("usb-path")
            path.set_tooltip_text(d.mount)
            side.append(path)
            body.append(side)
            block.append(body)
        else:
            lab = Gtk.Label(label=T("usb.unused", human(d.size, comma)) if d.fstype else T("usb.blank"), xalign=0)
            lab.add_css_class("subtitle")
            lab.set_margin_start(8)
            block.append(lab)
        buttons = Gtk.Box(spacing=8)
        buttons.set_margin_start(8)
        buttons.set_margin_end(8)
        buttons.set_margin_bottom(8)
        if working:
            lab = Gtk.Label(label=T("usb.working") + " \u2026", xalign=0)
            lab.add_css_class("subtitle")
            buttons.append(lab)
        else:
            if d.fstype:
                b = Gtk.Button(label="\U000F0770  " + T("usb.open"))
                b.add_css_class("action")
                b.add_css_class("primary")
                b.connect("clicked", lambda *_: act(d, "open"))
                b.set_hexpand(True)
                buttons.append(b)
            b = Gtk.Button(label=f"{GLYPH_EJECT}  " + T("usb.eject"))
            b.add_css_class("action")
            b.add_css_class("danger")
            b.connect("clicked", lambda *_: act(d, "eject"))
            b.set_hexpand(not d.fstype)
            buttons.append(b)
        block.append(buttons)
        return block

    def fill(force=False):
        root = state["root"]
        found = drives()
        sig = [(d.path, d.mount, d.used_pct) for d in found], sorted(state["working"])
        if not force and sig == state["sig"]:
            return True
        state["sig"] = sig
        clear(root)
        panel.subtitle.set_label(T("usb.none") if not found else
                                 T("usb.count_one") if len(found) == 1 else T("usb.count_many", len(found)))
        if not found:
            empty = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=8)
            empty.add_css_class("hero")
            glyph = Gtk.Label(label=GLYPH_USB)
            glyph.add_css_class("big")
            hint = Gtk.Label(label=T("usb.none_hint"), wrap=True, xalign=0.5, justify=Gtk.Justification.CENTER)
            hint.add_css_class("empty")
            empty.append(glyph)
            empty.append(hint)
            root.append(empty)
            return True
        body = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=8)
        body.append(k.section(T("usb.drives"), len(found)))
        for d in found:
            body.append(card(d))
        root.append(k.scroller(body, 520))
        return True

    def build(_panel):
        root = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=4)
        root.set_margin_top(12)
        state["root"] = root
        fill(True)
        GLib.timeout_add_seconds(2, fill)  # a drive plugged or pulled while it is open
        return root

    panel.on_build = build
    return panel.run()


if __name__ == "__main__":
    sys.exit(main())
