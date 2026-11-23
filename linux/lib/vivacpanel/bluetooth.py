"""Bluetooth: connected, paired and nearby devices, with their battery.

bluetoothctl (BlueZ) is the only source. This machine has no adapter, so the
honest state comes first: the adapter is looked for in /sys/class/bluetooth
before bluetoothctl is ever asked (without bluetoothd or an adapter it waits
for a controller and never answers). With an adapter: the switch in the
header, three groups by intent, the primary action only where it is needed,
and pairing as pair + trust + connect, the way a user means it.
"""
from __future__ import annotations

import json
import os
import re
import subprocess
import sys
from dataclasses import dataclass, field
from pathlib import Path

BTCTL = os.environ.get("VIVAC_BTCTL", "bluetoothctl")
SYS = Path(os.environ.get("VIVAC_BT_SYS", "/sys/class/bluetooth"))
GLYPH_BT, GLYPH_OFF = "\U000F00AF", "\U000F00B2"
ICONS = {"audio-headset": "\U000F02CB", "audio-headphones": "\U000F02CB", "audio-speakers": "\U000F04C3",
         "audio-card": "\U000F04C3", "input-keyboard": "\U000F030C", "input-mouse": "\U000F037D",
         "input-gaming": "\U000F0297", "phone": "\U000F011C", "computer": "\U000F0322"}


def _ctl(*args: str, timeout: int = 6) -> str:
    try:
        return subprocess.run([BTCTL, *args], capture_output=True, text=True, timeout=timeout,
                              stdin=subprocess.DEVNULL).stdout
    except (OSError, subprocess.TimeoutExpired):
        return ""


def adapter_present() -> bool:
    try:
        return any(p.name.startswith("hci") and ":" not in p.name for p in SYS.iterdir())
    except OSError:
        return False


@dataclass
class Dev:
    mac: str
    name: str
    group: str  # connected | paired | nearby
    icon: str = ""
    battery: int | None = None
    rssi: int | None = None


@dataclass
class Snapshot:
    state: str  # no_adapter | no_service | off | on
    powered: bool = False
    scanning: bool = False
    devices: list[Dev] = field(default_factory=list)

    def of(self, group: str) -> list[Dev]:
        return [d for d in self.devices if d.group == group]


def _field(info: str, key: str) -> str:
    m = re.search(rf"^\s*{re.escape(key)}: (.*)$", info, re.M)
    return m.group(1).strip() if m else ""


def snapshot() -> Snapshot:
    if not adapter_present():
        return Snapshot("no_adapter")
    show = _ctl("show")
    if "Powered" not in show:
        return Snapshot("no_service")
    powered = _field(show, "Powered") == "yes"
    snap = Snapshot("on" if powered else "off", powered, _field(show, "Discovering") == "yes")
    if not powered:
        return snap
    paired = {m.group(1) for m in re.finditer(r"^Device (\S+)", _ctl("devices", "Paired"), re.M)}
    for m in re.finditer(r"^Device (\S+) (.*)$", _ctl("devices"), re.M):
        mac, name = m.groups()
        info = _ctl("info", mac)
        battery = re.search(r"Battery Percentage: \S+ \((\d+)\)", info)
        rssi = _field(info, "RSSI")
        group = ("connected" if _field(info, "Connected") == "yes"
                 else "paired" if mac in paired or _field(info, "Paired") == "yes" else "nearby")
        snap.devices.append(Dev(mac, _field(info, "Name") or name, group, _field(info, "Icon"),
                                int(battery.group(1)) if battery else None,
                                int(rssi.split()[0]) if rssi.lstrip("-").split()[:1] and rssi.split()[0].lstrip("-").isdigit() else None))
    return snap


def set_power(on: bool) -> None:
    if on:
        subprocess.run(["rfkill", "unblock", "bluetooth"], capture_output=True, timeout=4)
    _ctl("power", "on" if on else "off")


def scan(seconds: int = 8) -> None:
    _ctl("--timeout", str(seconds), "scan", "on", timeout=seconds + 4)


def pair(mac: str) -> str | None:
    """Pair, trust (so it reconnects by itself) and connect; None or why not."""
    for step in ("pair", "trust", "connect"):
        out = _ctl(step, mac, timeout=30)
        if step != "trust" and re.search(r"Failed|not available", out):
            return out.strip().splitlines()[-1]
    return None


def connect(mac: str) -> str | None:
    out = _ctl("connect", mac, timeout=20)
    return out.strip().splitlines()[-1] if "Failed" in out else None


def disconnect(mac: str) -> None:
    _ctl("disconnect", mac)


def remove(mac: str) -> None:
    _ctl("remove", mac)


def waybar(args: list[str] | None = None) -> int:
    from .kit import T

    s = snapshot()
    if s.state == "no_adapter":
        print(json.dumps({"text": "", "tooltip": "", "class": "hidden"}))
        return 0
    if s.state in ("off", "no_service"):
        print(json.dumps({"text": GLYPH_OFF, "tooltip": T("bt.off"), "class": "off"}))
        return 0
    conn = s.of("connected")
    tip = "\n".join(f"{d.name}" + (f" {d.battery} %" if d.battery is not None else "") for d in conn) or T("bt.title")
    print(json.dumps({"text": GLYPH_BT + (f" {len(conn)}" if conn else ""), "tooltip": tip,
                      "class": "connected" if conn else "on"}, ensure_ascii=False))
    return 0


def _css(p: dict[str, str]) -> str:
    return f"""
.vivac .bt-empty {{ background: {p['surface']}; border-radius: 12px; padding: 22px; }}
.vivac .bt-big {{ font-size: 40px; color: {p['muted']}; }}
.vivac .bt-card {{ background: {p['surface']}; border-radius: 12px; padding: 6px; }}
.vivac switch:checked {{ background: {p['actionFill']}; }}
.vivac switch:checked slider {{ background: {p['actionText']}; }}
"""


def main() -> int:
    import threading

    from .kit import T, gtk_kit

    k = gtk_kit()
    Gtk, GLib = k.Gtk, k.GLib
    panel = k.Panel("bluetooth", GLYPH_BT, T("bt.title"), "",
                    hints=[("F5", T("bt.key.scan")), ("Enter", T("bt.key.connect")), ("Esc", T("bt.key.close"))],
                    width=440)
    provider = Gtk.CssProvider()
    provider.load_from_string(_css(panel.p))
    Gtk.StyleContext.add_provider_for_display(k.Gdk.Display.get_default(), provider,
                                              Gtk.STYLE_PROVIDER_PRIORITY_USER + 1)
    st = {"root": None, "sig": None, "busy": set(), "scanning": False}

    def clear(box):
        c = box.get_first_child()
        while c:
            n = c.get_next_sibling()
            box.remove(c)
            c = n

    def bg(key, fn):
        st["busy"].add(key)
        fill(True)

        def work():
            fn()
            GLib.idle_add(lambda: (st["busy"].discard(key), fill(True), False)[2])
        threading.Thread(target=work, daemon=True).start()

    def btn(label, cb, kind=""):
        b = Gtk.Button(label=label)
        b.add_css_class("action")
        if kind:
            b.add_css_class(kind)
        b.connect("clicked", lambda *_: cb())
        return b

    def dev_row(d):
        end = Gtk.Box(spacing=8)
        if d.battery is not None:
            end.append(k.badge(T("bt.battery", d.battery), "alert" if d.battery <= 15 else "ok"))
        if d.mac in st["busy"]:
            end.append(Gtk.Label(label=T("bt.working")))
        else:
            if d.group == "connected":
                end.append(btn(T("bt.disconnect"), lambda: bg(d.mac, lambda: disconnect(d.mac))))
            elif d.group == "paired":
                end.append(btn(T("bt.connect"), lambda: bg(d.mac, lambda: connect(d.mac)), "primary"))
            else:
                end.append(btn(T("bt.pair"), lambda: bg(d.mac, lambda: pair(d.mac)), "primary"))
            if d.group != "nearby":
                end.append(btn("\U000F01B4", lambda: bg(d.mac, lambda: remove(d.mac))))
        sub = d.mac if d.group == "nearby" else T("bt.sub." + d.group)
        return k.row(ICONS.get(d.icon, GLYPH_BT), d.name, sub, end=end)

    def fill(force=False):
        s = snapshot()
        sig = (s.state, s.scanning, [(d.mac, d.group, d.battery) for d in s.devices], sorted(st["busy"]))
        if not force and sig == st["sig"]:
            return True
        st["sig"] = sig
        root = st["root"]
        clear(root)
        head = Gtk.Box(spacing=10)
        label = {"no_adapter": T("bt.no_adapter"), "no_service": T("bt.no_service"), "off": T("bt.off"),
                 "on": T("bt.on_summary", len(s.of("connected")), len(s.of("connected")) + len(s.of("paired")))}[s.state]
        panel.subtitle.set_label(label)
        if s.state == "no_adapter":
            box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=8, halign=Gtk.Align.FILL)
            box.add_css_class("bt-empty")
            big = Gtk.Label(label=GLYPH_OFF)
            big.add_css_class("bt-big")
            title = Gtk.Label(label=T("bt.no_adapter_title"))
            title.add_css_class("name")
            hint = Gtk.Label(label=T("bt.no_adapter_hint"), wrap=True, justify=Gtk.Justification.CENTER)
            hint.add_css_class("subtitle")
            for w in (big, title, hint):
                box.append(w)
            root.append(box)
            return True
        sw = Gtk.Switch(active=s.powered, halign=Gtk.Align.END, valign=Gtk.Align.CENTER)
        sw.connect("state-set", lambda _s, v: (bg("power", lambda: set_power(v)), False)[1])
        head.append(Gtk.Label(label=T("bt.switch"), xalign=0, hexpand=True))
        head.append(sw)
        root.append(head)
        if s.state != "on":
            return True
        for group in ("connected", "paired", "nearby"):
            devs = s.of(group)
            if not devs and group != "nearby":
                continue
            root.append(k.section(T("bt." + group), len(devs)))
            card = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=4)
            card.add_css_class("bt-card")
            for d in devs:
                card.append(dev_row(d))
            if group == "nearby" and (st["scanning"] or s.scanning):
                lab = Gtk.Label(label=T("bt.scanning"), xalign=1)
                lab.add_css_class("subtitle")
                root.append(lab)
            root.append(card)
        root.append(btn(T("bt.more"), lambda: subprocess.Popen(["blueman-manager"])))
        return True

    def rescan():
        st["scanning"] = True
        fill(True)
        threading.Thread(target=lambda: (scan(), GLib.idle_add(lambda: (st.update(scanning=False), fill(True), False)[2])),
                         daemon=True).start()

    def build(_panel):
        root = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=8)
        root.set_margin_top(12)
        st["root"] = root
        fill(True)
        GLib.timeout_add_seconds(3, lambda: fill() if not st["busy"] else True)
        key = Gtk.EventControllerKey()
        key.connect("key-pressed", lambda _c, kv, *_: (rescan(), True)[1] if kv == 0xffc2 else False)
        GLib.idle_add(lambda: (panel.window.add_controller(key) if panel.window else None, False)[1])
        if snapshot().state == "on":
            rescan()
        return root

    panel.on_build = build
    return panel.run()


if __name__ == "__main__":
    sys.exit(main())
