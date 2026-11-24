"""Network: wired and Wi-Fi in one panel, with the dual-adapter Wi-Fi.

Replaces the rofi menus (wifi-menu.sh, wifi-dual-menu.sh, lan-menu.sh). Every
fact comes from NetworkManager through nmcli; the dual setup (internal card
plus the USB Alfa, two profiles for one SSID, the lower route metric carrying
the traffic) is read from the same wifi-dual.conf the bar module uses, never
copied. Nothing here keeps state NetworkManager does not.
"""
from __future__ import annotations

import json
import os
import re
import subprocess
import sys
from dataclasses import dataclass, field
from pathlib import Path

NMCLI = os.environ.get("VIVAC_NMCLI", "nmcli")
DUAL_CONF = Path(os.environ.get("VIVAC_WIFI_DUAL_CONF") or Path.home() / ".config/waybar/scripts/wifi-dual.conf")
GLYPH_WIFI, GLYPH_OFF, GLYPH_LOCK, GLYPH_LAN = "\U000F05A9", "\U000F05AA", "\U000F033E", "\U000F0200"
GLYPH_REFRESH, GLYPH_CHECK = "\U000F0450", "✓"


def _nm(*args: str, timeout: int = 15) -> tuple[int, str]:
    try:
        r = subprocess.run([NMCLI, *args], capture_output=True, text=True, timeout=timeout)
        return r.returncode, (r.stdout if r.returncode == 0 else (r.stderr or r.stdout))
    except (OSError, subprocess.TimeoutExpired) as e:
        return 1, str(e)


def _out(*args: str) -> str:
    rc, text = _nm(*args)
    return text if rc == 0 else ""


def split_terse(line: str) -> list[str]:
    """nmcli -t separates fields with ':' and escapes a literal one as '\\:'."""
    return [f.replace("\\:", ":").replace("\\\\", "\\") for f in re.split(r"(?<!\\):", line)]


@dataclass
class Device:
    name: str
    kind: str  # "wifi" | "ethernet"
    state: str
    connection: str

    @property
    def up(self) -> bool:
        return self.state == "connected"


@dataclass
class Network:
    ssid: str
    signal: int
    security: str
    in_use: bool
    known: bool
    channel: str = ""
    freq: str = ""


def devices() -> list[Device]:
    out = []
    for line in _out("-t", "-f", "DEVICE,TYPE,STATE,CONNECTION", "device", "status").splitlines():
        f = split_terse(line)
        if len(f) >= 4 and f[1] in ("wifi", "ethernet") and not f[0].startswith(("veth", "docker", "br-")):
            out.append(Device(f[0], f[1], f[2], f[3]))
    return out


def networks(dev: str) -> list[Network]:
    """Visible networks, one per SSID: the one in use first, then by signal."""
    known = {split_terse(l)[0] for l in _out("-t", "-f", "NAME,TYPE", "connection", "show").splitlines()
             if len(split_terse(l)) > 1 and "wireless" in split_terse(l)[1]}
    best: dict[str, Network] = {}
    for line in _out("-t", "-f", "IN-USE,SSID,SECURITY,SIGNAL,CHAN,FREQ", "device", "wifi", "list",
                     "ifname", dev, "--rescan", "no").splitlines():
        f = split_terse(line)
        if len(f) < 6 or not f[1]:
            continue
        sec = "" if f[2] in ("", "--") else f[2]
        n = Network(f[1], int(f[3] or 0), sec or "None", f[0].strip() == "*", f[1] in known, f[4], f[5])
        cur = best.get(n.ssid)
        if cur is None or (n.in_use, n.signal) > (cur.in_use, cur.signal):
            best[n.ssid] = n
    return sorted(best.values(), key=lambda n: (not n.in_use, -n.signal, n.ssid.lower()))


def needs_password(n: Network) -> bool:
    return n.security not in ("", "None") and not n.known


def rescan(dev: str) -> None:
    _nm("device", "wifi", "rescan", "ifname", dev)


def connect(ssid: str, dev: str, password: str = "") -> str | None:
    """Join a network. A known profile is brought up; None when it worked,
    else why not (a stale profile is deleted so a new password can retry)."""
    if not password:
        rc, why = _nm("connection", "up", "id", ssid, "ifname", dev)
        if rc == 0:
            return None
    args = ["device", "wifi", "connect", ssid]
    if password:
        args += ["password", password]
    rc, why = _nm(*args, "ifname", dev, timeout=40)
    return None if rc == 0 else why.strip().splitlines()[-1] if why.strip() else "failed"


def disconnect(dev: str) -> None:
    _nm("device", "disconnect", dev)


def forget(ssid: str) -> None:
    _nm("connection", "delete", "id", ssid)


def set_radio(on: bool) -> None:
    _nm("radio", "wifi", "on" if on else "off")


def radio_on() -> bool:
    return _out("radio", "wifi").strip() == "enabled"


# -- the dual Wi-Fi ---------------------------------------------------------

@dataclass
class Adapter:
    label: str  # "int" | "alfa"
    dev: str
    con: str
    state: str  # connected | connecting | disconnected | unavailable | missing
    signal: int = 0
    ip: str = ""


@dataclass
class Dual:
    adapters: list[Adapter] = field(default_factory=list)
    primary: str = "int"
    metrics: tuple[int, int] = (600, 700)


def _dual_conf() -> dict[str, str]:
    try:
        text = DUAL_CONF.read_text()
    except OSError:
        return {}
    return dict(re.findall(r"^([A-Z_]+)=(\S+)", text, re.M))


def _state(dev: str) -> str:
    s = _out("-g", "GENERAL.STATE", "device", "show", dev).strip()
    for prefix, name in (("100", "connected"), ("20", "unavailable"), ("30", "disconnected"), ("10", "unmanaged")):
        if s.startswith(prefix):
            return name
    return "missing" if not s else "connecting"


def _metric(con: str) -> int:
    try:
        return int(_out("-g", "ipv4.route-metric", "connection", "show", con).strip())
    except ValueError:
        return 0


def dual() -> Dual | None:
    """The two adapters, or None when this machine has no dual setup."""
    c = _dual_conf()
    if not all(k in c for k in ("INT_DEV", "INT_CON", "ALFA_DEV", "ALFA_CON")):
        return None
    d = Dual(metrics=(int(c.get("METRIC_PRIMARY", 600)), int(c.get("METRIC_BACKUP", 700))))
    for label, dev, con in (("int", c["INT_DEV"], c["INT_CON"]), ("alfa", c["ALFA_DEV"], c["ALFA_CON"])):
        a = Adapter(label, dev, con, _state(dev))
        if a.state == "connected":
            for line in _out("-t", "-f", "IN-USE,SIGNAL", "device", "wifi", "list", "ifname", dev,
                             "--rescan", "no").splitlines():
                f = split_terse(line)
                if f[0] == "*":
                    a.signal = int(f[1] or 0)
            a.ip = _out("-g", "IP4.ADDRESS", "device", "show", dev).strip().splitlines()[0:1] and \
                _out("-g", "IP4.ADDRESS", "device", "show", dev).strip().splitlines()[0] or ""
        d.adapters.append(a)
    ma, mb = _metric(c["INT_CON"]), _metric(c["ALFA_CON"])
    d.primary = "alfa" if mb < ma else "int"
    route = _route_dev()
    for a in d.adapters:  # what the kernel really uses beats what the profiles ask for
        if a.dev == route:
            d.primary = a.label
    return d


def _route_dev() -> str:
    """The device of the lowest-metric default route: who carries traffic now."""
    try:
        text = subprocess.run(["ip", "-4", "route", "show", "default"], capture_output=True, text=True,
                              timeout=4).stdout
    except (OSError, subprocess.TimeoutExpired):
        return ""
    best = None
    for line in text.splitlines():
        m, dv = re.search(r"metric (\d+)", line), re.search(r"dev (\S+)", line)
        if dv and (best is None or int(m.group(1) if m else 0) < best[0]):
            best = (int(m.group(1) if m else 0), dv.group(1))
    return best[1] if best else ""


def set_primary(which: str) -> None:
    """Make one card carry the traffic and the other the backup (route metrics;
    `device reapply` moves the routes without dropping the link)."""
    c = _dual_conf()
    first, second = (("INT", "ALFA") if which == "int" else ("ALFA", "INT"))
    hi, lo = c.get("METRIC_PRIMARY", "600"), c.get("METRIC_BACKUP", "700")
    for key, metric, prio in ((first, hi, "10"), (second, lo, "5")):
        _nm("connection", "modify", c[f"{key}_CON"], "ipv4.route-metric", metric, "ipv6.route-metric", metric,
            "connection.autoconnect-priority", prio)
    for key in (first, second):
        _nm("device", "reapply", c[f"{key}_DEV"])


def toggle_adapter(a: Adapter) -> None:
    if a.state == "connected":
        _nm("connection", "down", a.con)
    else:
        _nm("connection", "up", a.con, "ifname", a.dev)


# -- the bar ----------------------------------------------------------------

def _ip(dev: str) -> str:
    lines = _out("-g", "IP4.ADDRESS", "device", "show", dev).strip().splitlines()
    return lines[0].split("|")[0].split("/")[0] if lines else ""


def eth_speed(dev: str) -> str:
    try:
        mbps = int(Path(f"/sys/class/net/{dev}/speed").read_text())
    except (OSError, ValueError):
        return ""
    return f"{mbps // 1000} Gbps" if mbps >= 1000 else f"{mbps} Mbps"


def waybar(args: list[str] | None = None) -> int:
    """One pill for the network: the Wi-Fi that carries traffic (a bar of its
    signal, the SSID in the tooltip), else the cable, else a crossed glyph."""
    from .kit import T

    devs = devices()
    d = dual()
    wifi = [x for x in devs if x.kind == "wifi" and x.up]
    wired = [x for x in devs if x.kind == "ethernet" and x.up]
    lines = [f"{x.name}: {x.connection} {_ip(x.name)}".strip() for x in wifi + wired]
    if d:
        lines.append("Wi-Fi dual: " + T("net.primary_is", d.primary.upper()))
        lines += [f"  {a.label.upper():5} {a.state} {a.dev}" + (f"  {a.signal}%  {a.ip}" if a.signal else "")
                  for a in d.adapters]
    if wifi:
        sig = next((a.signal for a in (d.adapters if d else []) if a.dev == wifi[0].name and a.signal), 0)
        text, cls = GLYPH_WIFI + (f" {sig}%" if sig else ""), "wifi"
    elif wired:
        text, cls = GLYPH_LAN, "wired"
    else:
        text, cls = GLYPH_OFF, "down"
    print(json.dumps({"text": text, "tooltip": "\n".join(lines) or T("net.none"), "class": cls}, ensure_ascii=False))
    return 0


# -- the panel --------------------------------------------------------------

def _css(p: dict[str, str]) -> str:
    return f"""
.vivac .net-card {{ background: {p['surface']}; border-radius: 12px; padding: 14px; }}
.vivac .net-ssid {{ font-size: 17px; font-weight: 700; color: {p['text']}; }}
.vivac .net-cell {{ background: {p['surfaceAlt']}; border-radius: 10px; padding: 8px 10px; }}
.vivac .net-cell-k {{ font-size: 11px; color: {p['muted']}; }}
.vivac .net-cell-v {{ font-size: 13px; font-weight: 700; color: {p['text']}; }}
.vivac button.net-tab {{ min-height: 32px; border-radius: 9px; border: none; box-shadow: none;
  background: {p['surface']}; color: {p['textSecondary']}; }}
.vivac button.net-tab.sel {{ background: {p['actionFill']}; color: {p['actionText']}; font-weight: 700; }}
.vivac .net-pw {{ background: {p['surface']}; border-radius: 12px; padding: 10px; }}
.vivac switch:checked {{ background: {p['actionFill']}; }}
.vivac switch:checked slider {{ background: {p['actionText']}; }}
.vivac .net-err {{ color: {p['alert']}; font-size: 12px; }}
"""


def tab_for(args: list[str]) -> str:
    """The tab a launch names: "ethernet" (or "eth") for the wired button,
    anything else Wi-Fi, the panel's first tab."""
    return "eth" if args and args[0] in ("ethernet", "eth") else "wifi"


def main(*args: str) -> int:
    import threading

    from .kit import SETTINGS, T, gtk_kit

    k = gtk_kit()
    Gtk, GLib = k.Gtk, k.GLib
    panel = k.Panel("network", GLYPH_WIFI, T("net.title"), "",
                    hints=[("Tab", T("net.key.move")), ("Enter", T("net.key.connect")),
                           ("F5", T("net.key.scan")), ("Esc", T("net.key.close"))], width=440)
    provider = Gtk.CssProvider()
    provider.load_from_string(_css(panel.p))
    Gtk.StyleContext.add_provider_for_display(k.Gdk.Display.get_default(), provider,
                                              Gtk.STYLE_PROVIDER_PRIORITY_USER + 1)
    st = {"tab": tab_for(list(args)), "root": None, "ask": None, "err": "", "busy": False, "sig": None}

    def clear(box):
        c = box.get_first_child()
        while c:
            n = c.get_next_sibling()
            box.remove(c)
            c = n

    def bg(fn, then=None):
        def work():
            r = fn()
            GLib.idle_add(lambda: (then(r) if then else None, fill(True), False)[2])
        st["busy"] = True
        threading.Thread(target=work, daemon=True).start()

    def btn(label, cb, kind=""):
        b = Gtk.Button(label=label)
        b.add_css_class("action")
        if kind:
            b.add_css_class(kind)
        b.connect("clicked", lambda *_: cb())
        return b

    def cell(key, value):
        c = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, hexpand=True)
        c.add_css_class("net-cell")
        a = Gtk.Label(label=key, xalign=0)
        a.add_css_class("net-cell-k")
        b = Gtk.Label(label=value, xalign=0, ellipsize=3)
        b.add_css_class("net-cell-v")
        c.append(a)
        c.append(b)
        return c

    def tabs(devs):
        row = Gtk.Box(spacing=6, homogeneous=True)
        eth = [x for x in devs if x.kind == "ethernet"]
        for key, label in (("wifi", T("net.tab.wifi")), ("eth", T("net.tab.eth"))):
            b = Gtk.Button(label=label)
            b.add_css_class("net-tab")
            if st["tab"] == key:
                b.add_css_class("sel")
            b.connect("clicked", lambda _b, kk=key: (st.update(tab=kk, ask=None, err=""), fill(True)))
            row.append(b)
        return row

    def wifi_body(devs):
        body = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=8)
        wifis = [x for x in devs if x.kind == "wifi"]
        d = dual()
        on = radio_on()
        card = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=10)
        card.add_css_class("net-card")
        carrying = next((x for x in wifis if x.up and (not d or x.name == next(
            (a.dev for a in d.adapters if a.label == d.primary), x.name))), next((x for x in wifis if x.up), None))
        head = Gtk.Box(spacing=10)
        col = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, hexpand=True)
        ssid = Gtk.Label(label=(carrying.connection if carrying else (T("net.disconnected") if on else T("net.radio_off"))),
                         xalign=0, ellipsize=3)
        ssid.add_css_class("net-ssid")
        col.append(ssid)
        if carrying:
            sub = Gtk.Label(label=f"{GLYPH_CHECK} {T('net.connected')} · {carrying.name}", xalign=0)
            sub.add_css_class("subtitle")
            col.append(sub)
        head.append(col)
        sw = Gtk.Switch(active=on, valign=Gtk.Align.CENTER)
        sw.connect("state-set", lambda _s, v: (bg(lambda: set_radio(v)), False)[1])
        head.append(sw)
        card.append(head)
        nets = networks(carrying.name) if carrying else []
        cur = next((n for n in nets if n.in_use), None)
        if carrying and cur:
            ghz = f"{float(cur.freq.split()[0]) / 1000:g} GHz" if cur.freq[:1].isdigit() else cur.freq
            for pair in ((cell(T("net.signal"), f"{cur.signal} %"), cell(T("net.band"), f"{ghz} \u00b7 {T('net.channel')} {cur.channel}")),
                         (cell(T("net.ip"), _ip(carrying.name) or "\u2013"), cell(T("net.device"), carrying.name))):
                grid = Gtk.Box(spacing=8, homogeneous=True)
                for c in pair:
                    grid.append(c)
                card.append(grid)
            acts = Gtk.Box(spacing=8, homogeneous=True)
            acts.append(btn(T("net.disconnect"), lambda: bg(lambda: disconnect(carrying.name)), "primary"))
            acts.append(btn(T("net.forget"), lambda: bg(lambda: forget(carrying.connection)), "danger"))
            acts.append(btn(T("net.settings"), lambda: subprocess.Popen(["nm-connection-editor"])))
            card.append(acts)
        body.append(card)
        if d:
            body.append(k.section(T("net.dual"), len(d.adapters)))
            for a in d.adapters:
                is_p = a.label == d.primary
                tag = k.badge(T("net.carries") if is_p else T("net.backup"), "ok" if is_p else "info")
                name = T("net.card_int") if a.label == "int" else T("net.card_alfa")
                sub = f"{a.dev} · {T('net.state.' + a.state)}" + (f" · {a.signal} %" if a.signal else "")
                block = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=6)
                block.add_css_class("net-card")
                block.append(k.row(GLYPH_WIFI if a.state == "connected" else GLYPH_OFF, name, sub, end=tag))
                if a.state != "unmanaged":
                    acts = Gtk.Box(spacing=8, homogeneous=True)
                    if not is_p and a.state == "connected":
                        acts.append(btn(T("net.make_primary"), lambda a=a: bg(lambda: set_primary(a.label)), "primary"))
                    acts.append(btn(T("net.off") if a.state == "connected" else T("net.on"),
                                    lambda a=a: bg(lambda: toggle_adapter(a))))
                    block.append(acts)
                body.append(block)
        if carrying or wifis:
            scan_dev = (carrying or wifis[0]).name
            nets = nets or networks(scan_dev)
            body.append(k.section(T("net.available"), len(nets)))
            lst = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=6)
            for n in nets:
                lst.append(net_row(n, scan_dev))
                if st["ask"] == n.ssid:
                    lst.append(pw_box(n, scan_dev))
            if st["err"]:
                e = Gtk.Label(label=st["err"], xalign=0, wrap=True)
                e.add_css_class("net-err")
                lst.append(e)
            body.append(k.scroller(lst, 300))
        return body

    def net_row(n, dev):
        lock = Gtk.Label(label=GLYPH_LOCK if n.security != "None" else "")
        end = Gtk.Box(spacing=8)
        end.append(Gtk.Label(label=f"{n.signal} %"))
        end.append(lock)
        sub = (f"{GLYPH_CHECK} {T('net.connected')}" if n.in_use else
               (T("net.saved") if n.known else T("net.protected", n.security) if n.security != "None" else T("net.open")))

        def go():
            if n.in_use:
                return
            if needs_password(n):
                st["ask"] = None if st["ask"] == n.ssid else n.ssid
                fill(True)
            else:
                bg(lambda: connect(n.ssid, dev), lambda why: st.update(err=why or ""))
        return k.row(GLYPH_WIFI, n.ssid, sub, end=end, selected=n.in_use, on_activate=go)

    def pw_box(n, dev):
        box = Gtk.Box(spacing=8)
        box.add_css_class("net-pw")
        entry = Gtk.Entry(visibility=False, hexpand=True, placeholder_text=T("net.password"))
        entry.set_input_purpose(Gtk.InputPurpose.PASSWORD)

        def join(*_):
            pw = entry.get_text()
            if pw:
                st["ask"] = None
                bg(lambda: connect(n.ssid, dev, pw), lambda why: st.update(err=why or ""))
        entry.connect("activate", join)
        box.append(entry)
        box.append(btn(T("net.join"), join, "primary"))
        GLib.idle_add(lambda: (entry.grab_focus(), False)[1])
        return box

    def eth_body(devs):
        body = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=8)
        eths = [x for x in devs if x.kind == "ethernet"]
        if not eths:
            lab = Gtk.Label(label=T("net.no_cable"), xalign=0.5)
            lab.add_css_class("empty")
            body.append(lab)
        for e in eths:
            card = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=10)
            card.add_css_class("net-card")
            card.append(k.row(GLYPH_LAN, e.connection or e.name,
                              f"{e.name} · {T('net.state.' + e.state) if e.up else e.state}",
                              end=k.badge(T("net.connected") if e.up else T("net.no_link"), "ok" if e.up else "info")))
            if e.up:
                grid = Gtk.Box(spacing=8, homogeneous=True)
                grid.append(cell(T("net.speed"), eth_speed(e.name) or "–"))
                grid.append(cell(T("net.ip"), _ip(e.name) or "–"))
                card.append(grid)
            acts = Gtk.Box(spacing=8, homogeneous=True)
            acts.append(btn(T("net.disconnect") if e.up else T("net.connect"),
                            lambda e=e: bg(lambda: disconnect(e.name) if e.up else _nm("device", "connect", e.name)),
                            "primary"))
            acts.append(btn(T("net.settings"), lambda: subprocess.Popen(["nm-connection-editor"])))
            card.append(acts)
            body.append(card)
        return body

    def fill(force=False):
        st["busy"] = False
        root = st["root"]
        devs = devices()
        sig = (st["tab"], st["ask"], st["err"], [(x.name, x.state, x.connection) for x in devs],
               dual() and [(a.state, a.signal) for a in dual().adapters], radio_on())
        if not force and sig == st["sig"]:
            return True
        st["sig"] = sig
        clear(root)
        wifi = next((x for x in devs if x.kind == "wifi" and x.up), None)
        eth = next((x for x in devs if x.kind == "ethernet" and x.up), None)
        panel.subtitle.set_label(" · ".join(
            [f"Wi-Fi: {wifi.connection}" if wifi else "Wi-Fi: –",
             f"{T('net.tab.eth')}: {eth_speed(eth.name) or T('net.connected')}" if eth else f"{T('net.tab.eth')}: –"]))
        root.append(tabs(devs))
        root.append(wifi_body(devs) if st["tab"] == "wifi" else eth_body(devs))
        return True

    def build(_panel):
        root = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=8)
        root.set_margin_top(12)
        st["root"] = root
        fill(True)
        GLib.timeout_add_seconds(4, lambda: fill() if not st["busy"] and not st["ask"] else True)
        key = Gtk.EventControllerKey()
        key.connect("key-pressed", lambda _c, kv, *_: (
            (threading.Thread(target=lambda: [rescan(x.name) for x in devices() if x.kind == "wifi"], daemon=True).start(),
             GLib.timeout_add_seconds(2, lambda: (fill(True), False)[1])) and True) if kv == 0xffc2 else False)
        GLib.idle_add(lambda: (panel.window.add_controller(key) if panel.window else None, False)[1])
        return root

    panel.on_build = build

    # Open already, and the pointer rests on the other network button: go to
    # its tab (lib/bar-hover passes the button's arguments with --hover).
    def to_tab(hover_args):
        tab = tab_for(hover_args)
        if tab != st["tab"] and st["root"] is not None:
            st.update(tab=tab, ask=None, err="")
            fill(True)
    panel.on_hover_args = to_tab
    return panel.run()


if __name__ == "__main__":
    sys.exit(main())
