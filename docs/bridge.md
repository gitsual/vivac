# The bridge: what Linux and Windows do together

vivac runs on Arch Linux (`linux/`) and on Windows 11 (`windows/`). Each half
stands on its own. Together they also share state across a dual boot and talk
live across a local network. This file is the contract both halves implement;
a change here is a change to both.

Five features, each usable alone:

| Feature | When it helps | Needs |
|---|---|---|
| [Shared choices](#1-shared-choices) | dual boot | a disk both systems mount |
| [Reboot into the other system](#2-reboot-into-the-other-system) | dual boot | UEFI |
| [The drop tray](#3-the-drop-tray) | dual boot | a disk both systems mount |
| [vivac link](#4-vivac-link) | two machines on one network | a pairing code |
| [One keyboard and mouse](#5-one-keyboard-and-mouse) | two machines on one network | lan-mouse on both, each trusting the other's certificate |

## The shared root

The folder that holds the shared settings file is the **shared root**: with
`shared_settings=D:\vivac-shared\settings` on Windows and
`shared_settings=~/shared/vivac-shared/settings` on Linux, both pointing at
the same folder on the same disk, the shared root is that folder. Nothing in
the bridge that needs a disk works while `shared_settings=none`; it says so
and does nothing else.

```text
<shared root>/
  settings            shared choices (key=value, lowercase values)
  drop/to-linux/      the drop tray, towards Linux
  drop/to-windows/    the drop tray, towards Windows
```

## 1. Shared choices

Already in both halves (`sync-shared-settings`): `theme`, `weather_location`
and `language` follow the shared file; `mod` and everything else stay local.

## 2. Reboot into the other system

One action in each power menu: **Restart in Windows** on Linux, **Restart in
Linux** on Windows. It sets the UEFI *BootNext* variable, which the firmware
honours for exactly one boot and then forgets, and restarts. GRUB's default
and the firmware's boot order are never changed.

- **Linux**: `efibootmgr` finds the entry whose label is `Windows Boot
  Manager` and runs `efibootmgr --bootnext XXXX`. Root is needed; a sudoers
  drop-in (`/etc/sudoers.d/vivac-bootnext`, installed by `apply-system.sh --bridge`)
  allows exactly `efibootmgr --bootnext` followed by four hex digits, without
  a password, to members of `wheel`.
  Then `systemctl reboot`.
- **Windows**: `bcdedit /enum firmware` finds the first entry whose
  description names a Linux loader (`GRUB`, `Arch`, `Linux`, `vivac`,
  `systemd-boot`, `rEFInd`; never `Windows Boot Manager`) and runs
  `bcdedit /set {fwbootmgr} bootsequence {id}`. The pattern is fixed, not a
  setting: an elevated task reads nothing the user can change unelevated.
  Administrator rights are needed; an on-demand task `\vivac\reboot-other`
  runs a protected copy (under `C:\Program Files\vivac`, as every elevated
  vivac task does) so the button raises no UAC prompt. Then `shutdown /r`.

Both ask for confirmation twice, like any restart, and both have `--dry-run`
/ `-DryRun`, which names the entry it would choose and changes nothing.

## 3. The drop tray

A folder per direction under the shared root. Put something in
`drop/to-windows/` on Linux, and at the next Windows sign-in a notification
says how many things are waiting, with a click that opens the folder; the
same the other way. Each side's menu has **Drop tray** (opens what came for
this side) and **Send to <other>** (opens the outgoing folder). Nothing is
moved or deleted automatically; the folder is the tray.

## 4. vivac link

Two machines, one Linux and one Windows (or two of the same), on the same
local network, paired once. Then from either one:

| Verb | What the other side does |
|---|---|
| `clip` | puts the text on its clipboard and says so in a notification |
| `url` | shows a notification "<name> sent a link"; a click opens it (http/https only, never opened unasked) |
| `file` | saves it under `Downloads/vivac-link/` with a safe name, never overwriting, and says so |
| `notify` | shows the title and body as a notification |
| `ping` | answers with its name, system and version |

### Pairing

`vivac link pair` on one machine prints a code (32 random bytes, base32,
grouped in fives: `ABCDE-FGHIJ-...`). `vivac link pair <code>` on the other
stores the same secret. The secret lives only in the machine's own state,
never in the repository, the shared root or the settings file:

- Linux: `${XDG_STATE_HOME:-~/.local/state}/vivac/link.conf` (mode 600)
- Windows: `%LOCALAPPDATA%\vivac\link.conf` (current user only)

```text
secret=<base32, no dashes>
name=<this machine's display name, default the host name>
peer=<host:port, optional; found by discovery otherwise>
port=47321
```

### Discovery

Every 30 s each side sends a UDP broadcast to port `47321`:

```json
{"v":1,"name":"<name>","os":"linux|windows","port":47321,"id":"<16 hex>"}
```

`id` is the first 16 hex digits of `HMAC-SHA256(secret, "vivac-link-id")`.
A side that receives a beacon whose `id` equals its own takes the sender's
address as its peer. The id proves nothing (anyone can replay a beacon); it
only lets two paired machines find each other without saying the secret.
Every request is still signed.

### Requests

HTTP/1.1 over TCP to the peer's `port`, one request per connection:

```text
POST /v1/<verb> HTTP/1.1
Content-Length: <n>
X-Vivac-Time: <unix seconds>
X-Vivac-Nonce: <32 hex digits, random>
X-Vivac-Name: <file name, file verb only, UTF-8 percent-encoded>
X-Vivac-Sign: <hex HMAC-SHA256(secret, verb + "\n" + time + "\n" + nonce + "\n" + hex SHA-256(body))>
```

Bodies: `clip` and `url` are UTF-8 text; `notify` is JSON
`{"title":"...","body":"..."}`; `file` is the raw bytes; `ping` is empty.

The receiver rejects with `401` when the signature does not match, the time
is more than 60 s away from its own clock, or the nonce was already seen in
the last 120 s; with `413` when the body is over 64 MiB (`clip`, `url`,
`notify`: over 64 KiB); with `404` for an unknown verb. It answers `200` with
a JSON body (`{"ok":true}`, or the `ping` answer). It never runs anything it
receives, never opens a URL without a click, and writes files only into its
`Downloads/vivac-link/` folder, under a name stripped of any path.

### Listening

- Linux: a systemd user service, `vivac-link.service` (Python standard
  library only).
- Windows: a sign-in task, `\vivac\link`, at the normal level.
- Both listen on all interfaces, so each system's firewall decides who may
  reach the port. Windows: `apply-system.ps1 -Link` adds one inbound rule
  for TCP and UDP 47321, private networks and the local subnet only. Linux:
  `apply-system.sh --bridge` opens the same in UFW, the firewall vivac configures, for the
  local subnet only.

## 5. One keyboard and mouse

Two machines side by side, one keyboard and one mouse: push the pointer past
the edge of this screen that faces the other machine and it appears there,
with the keyboard following it. [lan-mouse](https://github.com/feschber/lan-mouse)
(0.11) does the work; vivac installs it, writes its configuration, starts and
stops it, and opens its port. vivac never touches the input itself.

| | Linux | Windows |
|---|---|---|
| Program | `vivac-mouse` | `bin\vivac-mouse.ps1` |
| lan-mouse | `lan-mouse` from `extra` (`packages/pacman.txt`) | winget `feschber.LanMouse` (`bootstrap.ps1 -Mouse`), a portable zip found on the PATH or as `%LOCALAPPDATA%\Microsoft\WinGet\Links\lan-mouse.exe` |
| vivac's settings | `${XDG_STATE_HOME:-~/.local/state}/vivac/mouse.conf` (mode 600) | `%LOCALAPPDATA%\vivac\mouse.conf` |
| lan-mouse's files | `${XDG_CONFIG_HOME:-~/.config}/lan-mouse/` | `%LOCALAPPDATA%\lan-mouse\` |
| Runs as | the user service `vivac-mouse.service` (`lan-mouse daemon`) | the sign-in task `\vivac\mouse` (`lan-mouse.exe daemon`, no console, normal level) |
| Firewall | `apply-system.sh --bridge`: UDP 4242 from each local subnet, in UFW | `apply-system.ps1 -Mouse`: rule "vivac mouse", UDP 4242, private networks, local subnet |

`mouse.conf` is the only thing vivac reads:

```text
enabled=yes|no
peer=<host name or IP address of the other machine>
side=left|right|top|bottom   the edge of this screen the other machine sits beyond
fingerprint=<the other machine's certificate fingerprint>
port=4242
```

and from it vivac writes lan-mouse's `config.toml` whole, the same bytes on
both systems: `port`, one `[authorized_fingerprints]` entry (the only
certificate whose input is accepted), and one `[[clients]]` entry with
`position`, `hostname` (or `ips` for an address), `port` and
`activate_on_startup = true`. A `config.toml` vivac did not write is kept once
as `config.toml.vivac-backup`. Every value is checked before it reaches the
file: a host name or an IP address, one of the four sides, 32 hex pairs, a
port; nothing else gets in.

### The fingerprint

lan-mouse makes a self-signed certificate, `lan-mouse.pem`, beside its
`config.toml` the first time it starts, and identifies a machine by the
SHA-256 of that certificate (the DER bytes of the `CERTIFICATE` block),
written as 32 lowercase hex pairs joined by colons (`aa:bb:cc:...`). It shows
it only in its GTK window; `vivac-mouse fingerprint` reads it out of the file
and prints it (the private key in the same file is never read). Until
lan-mouse has started once there is no certificate, and it says so.

### Verbs

| Verb | What it does |
|---|---|
| `enable` | writes the config and starts lan-mouse; Linux: records `enabled=yes` and restarts the service, which login starts again (`vivac-mouse resume`, from Hyprland's autostart) while it stays enabled; Windows: registers and starts `\vivac\mouse` |
| `disable` | stops lan-mouse and keeps it stopped (Windows: removes the task) |
| `toggle` | one or the other: the bridge menu's **Shared mouse: on/off** row |
| `config --peer HOST --side SIDE [--fingerprint FP] [--port N]` | where the other machine is (Windows: `-Peer -Side -Fingerprint -Port`) |
| `trust FP` | accepts the other machine's certificate, in place of the one before |
| `fingerprint` | prints this machine's |
| `pair` | prints this machine's name and fingerprint, and the exact line to run on the other machine, with the opposite side: when the other machine is on the right of this one, this one is on its left |
| `status` | on or off, the other machine, both fingerprints |

`enable`, `disable`, `toggle`, `config` and `trust` take `--dry-run` /
`-DryRun`, which prints the file and the commands and changes nothing.
`LAN_MOUSE` (Linux) and `VIVAC_LAN_MOUSE` (Windows) name another lan-mouse
binary; the gates point them at a fake.

### Setting it up

1. Install lan-mouse and open the port: `apply-system.sh --bridge` on Linux;
   `bootstrap.ps1 -Mouse`, then `apply-system.ps1 -Mouse` elevated, on
   Windows.
2. `vivac-mouse enable` on both: lan-mouse starts and makes its certificate.
3. On one machine, `vivac-mouse config --peer OTHER --side right` (wherever
   the other screen really is).
4. `vivac-mouse pair` there, and run the line it prints on the other machine;
   then `vivac-mouse pair` on the other machine, and run its line on the
   first. Each now trusts the other's fingerprint and nothing else.

The way back is lan-mouse's release chord: left Ctrl, Shift, Super and Alt
together, or, once both sides are set up, moving back across the edge.

### Why its own firewall switch on Windows

Linux opens UDP 4242 in the same `--bridge` step as the link port: lan-mouse
is in the base package list there and listens only while enabled. On Windows
lan-mouse is an optional package (`-Mouse`), so its rule is a profile of its
own, `-Mouse`, beside `-Link`: either can be applied, or removed by
`uninstall.ps1`, without the other. Both rules open the default port only;
after `--port N`, open N by hand.

### Known limits (lan-mouse's)

- **Windows**: the pointer is invisible on a Windows machine that is being
  controlled when no physical mouse is plugged into it.
- **wlroots compositors without libei** (Hyprland among them) on the
  receiving side do not handle modifier events from a sender that does not
  use the layer-shell capture backend: Ctrl, Shift, Alt and Super can be
  lost.
- **X11** can only receive, not send.
- Traffic is encrypted with DTLS (WebRTC.rs), with **no mitigation against
  timing side channels**: someone on the network can learn when and roughly
  how you type. Keep it to a network you trust.
- Windows' own elevated windows (UAC prompts, administrator programs) do not
  take input from a lan-mouse running at the normal level.

### Pairing over vivac link (after protocol v2)

`pair` and `trust` are the manual exchange. Once vivac link speaks v2, one
verb carries it: `mouse`, body JSON `{"fingerprint":"aa:...","port":4242,"side":"right"}`,
where `side` is where the *receiver* should place the sender (the sender's
own side, reversed). The receiver checks each field as `vivac-mouse config`
does, stores the fingerprint and side through the same code path as
`vivac-mouse config --peer <sender's address> --side <side> --fingerprint <fp>`,
restarts lan-mouse if it is enabled, and answers with its own
`{"fingerprint","port","side"}`, which the sender stores the same way. It
never enables lan-mouse by itself.

## Versions

The product has one version (`VERSION` at the root); each half has its own
(`linux/VERSION`, `windows/VERSION`). A release is tagged `vX.Y.Z` for the
product, `linux-vX.Y.Z` and `windows-vX.Y.Z` for a half. The bridge protocol
carries its own number (`v1` in the path and the beacon); a half refuses a
peer whose protocol it does not speak, by answering `404`.
