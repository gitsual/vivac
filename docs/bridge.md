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
| [Palettes from a picture](#5-palettes-from-a-picture) | dual boot (or one system alone) | a disk both systems mount, to share them |
| [Bluetooth across the dual boot](#5-bluetooth-across-the-dual-boot) | dual boot | the Windows partition mounted on Linux |
| [The phone](#5-the-phone-kde-connect) | a phone on the same network | KDE Connect on both |

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
  themes/             palettes made from a picture, each with its picture
```

## 1. Shared choices

Already in both halves (`sync-shared-settings`): `theme`, `weather_location`
and `language` follow the shared file; `mod` and everything else stay local.
A `theme` that names a palette made from a picture is accepted when that
palette is in `<shared root>/themes/` (section 5); otherwise the other side
ignores it and says so, as it does for any name it does not know.

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
| `ping` | answers with its name, system, version and hardware address |
| `mouse` | places and trusts the sender's lan-mouse and answers with its own ([One keyboard and mouse](#5-one-keyboard-and-mouse)) |

And one that is not a request: `wake` sends a Wake-on-LAN packet to the
other machine's hardware address, the one its last `ping` gave, so a machine
that is asleep (or off, where its firmware allows) comes up.

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
{"v":2,"name":"<name>","os":"linux|windows","port":47321,"id":"<16 hex>"}
```

`id` is the first 16 hex digits of `HMAC-SHA256(secret, "vivac-link-id")`.
A side that receives a beacon whose `id` equals its own takes the sender's
address as its peer. The id proves nothing (anyone can replay a beacon); it
only lets two paired machines find each other without saying the secret.
Every request is still signed.

### Keys

Two keys come from the secret, one per use, so the same key never both
encrypts and signs:

```text
seal key = HMAC-SHA256(secret, "vivac-link v2 encrypt")
sign key = HMAC-SHA256(secret, "vivac-link v2 sign")
```

Every body that carries something is **sealed**: AES-256-CBC under the seal
key, a fresh random 16-byte IV, PKCS#7 padding; on the wire, the IV and then
the ciphertext. What is sealed is then signed (encrypt-then-MAC), and a
receiver checks the signature before it opens anything. Someone else on the
network sees that two machines talk, when, and roughly how much, never what.

### Requests

HTTP/1.1 over TCP to the peer's `port`, one request per connection:

```text
POST /v2/<verb> HTTP/1.1
Content-Length: <n>
X-Vivac-Time: <unix seconds>
X-Vivac-Nonce: <32 hex digits, random>
X-Vivac-Sign: <hex HMAC-SHA256(sign key, "v2\n" + verb + "\n" + time + "\n" + nonce + "\n" + hex SHA-256(sealed body))>
```

What is sealed: `clip` and `url`, UTF-8 text; `notify`, JSON
`{"title":"...","body":"..."}`; `file`, the file's name in UTF-8 (up to 1024
bytes), a NUL byte, then the file's bytes, so not even the name travels in
the clear; `ping`, nothing (an empty plain body still seals to 32 bytes).

The receiver refuses with `401` when the signature does not match, the time
is more than 60 s away from its own clock, or the nonce was already seen in
the last 120 s; with `413` when the sealed body is over the verb's limit plus
1057 bytes (what sealing and a name add); with `400` when the body does not
open, or opens to more than 64 MiB (`file`) or 64 KiB (`clip`, `url`,
`notify`); with `404` for an unknown verb or protocol. Refusals are plain
JSON (`{"ok":false}`) and say nothing more.

### Answers

A `200` carries a sealed JSON body (`{"ok":true}`, or the `ping` answer) and
its own signature, made over the request's nonce:

```text
X-Vivac-Sign: <hex HMAC-SHA256(sign key, "v2 answer\n" + nonce + "\n" + hex SHA-256(sealed body))>
```

The sender trusts an answer only when that signature matches; anything else
on the port, answering in the peer's place, is refused as "not trusted".

The `ping` answer is `{"ok":true,"name":"...","os":"linux|windows",
"version":"...","protocol":2,"mac":"aa:bb:cc:dd:ee:ff"}`; `mac` is the
hardware address of the interface the request came in on (empty on a
loopback or a tunnel), which the sender keeps for `wake`.

A receiver never runs anything it receives, never opens a URL without a
click, and writes files only into its `Downloads/vivac-link/` folder, under a
name stripped of any path.

### Waking the other machine

`vivac-link wake` sends the standard magic packet (six `0xFF`, then the
6-byte hardware address sixteen times) by UDP broadcast to ports 9 and 7.
The address is the one the last `ping` answered with, kept beside the
pairing (`link-peer-mac`). The other machine wakes only if its firmware and
network card allow Wake-on-LAN, which is a firmware setting vivac does not
change.

### Listening

- Linux: a systemd user service, `vivac-link.service` (Python standard
  library, and python-cryptography for AES).
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

### Pairing over vivac link

`pair` and `trust` are the manual exchange. With vivac link paired, one
command does both sides: `vivac-link mouse right` (Windows:
`bin\vivac-link.ps1 mouse right`), where `right` is the edge of this screen
the other machine sits beyond. It sends the link verb `mouse`, body JSON
`{"fingerprint":"aa:...","port":4242,"side":"left"}`, where `side` is where
the *receiver* should place the sender (the sender's own side, reversed).
The receiver checks each field, runs
`vivac-mouse config --peer <sender's address> --side <side> --fingerprint <fp> --port <port>`
(so the same checks and files as by hand, and a restart of lan-mouse only if
it is on), and answers with its own `{"fingerprint","port","side"}`, which
the sender stores the same way. Neither side ever turns lan-mouse on because
of it. Both need lan-mouse to have made its certificate (`vivac-mouse enable`
once) first.

## 5. vivac ask across machines

`vivac ask` is a feature of each half on its own (`linux/README.md`, `windows/README.md`): a
side panel for a language model served by Ollama, talking to `ask_url`, `http://localhost:11434`
by default. It is not part of the bridge protocol and carries nothing of vivac link. One machine
can still use the other's Ollama, typically the one with the larger GPU: set
`ask_url=http://ADDRESS:11434` and `ask_allow_lan=true` on the asking side, and make Ollama listen
on the network on the serving side (`OLLAMA_HOST=0.0.0.0`), with the firewall letting in the local
subnet only. Ollama has no authentication: whoever reaches the port can use it, so only on a
network you trust. A public address is refused even with `ask_allow_lan=true`.
## 5. Palettes from a picture

`vivac theme from-image IMAGE [--name NAME]` makes a new palette, a ninth,
a tenth, from a PNG or JPEG: on Linux `vivac-theme from-image`, on Windows
`vivac.ps1 theme from-image` (`-Name`, `-DryRun`, `-Apply`). Each theme
menu ends with **From a picture…**, which asks for the picture (rofi over
the pictures folder and Downloads; the Windows file dialog), makes the
palette and wears it. `--dry-run` / `-DryRun` prints it as truecolour
swatches and writes nothing.

No colour is invented. Every one of the thirteen tokens is a row of
`palette-corpus.tsv`; the picture only votes for which. Both halves run the
same steps with the same constants (`linux/scripts/theme-from-image.py`,
`windows/lib/Picture.psm1`):

1. A grid of at most 64 × 64 samples, the centre of each cell, read from the
   decoded pixels without resampling; samples under half opacity are skipped.
2. Distance is redmean, the measure the catalogue gate uses, as the integer
   512 × redmean², so both halves compare exactly.
3. The ground is the dark corpus colour (role `deep` or `base`) most samples
   are nearest to; if no full palette can be built on it, the next one.
4. Text, dim text, surfaces and the terminal pair come from their corpus
   roles, each the first in its order that clears the catalogue's floors
   (7:1 text, 4.5:1 dim text, 3:1 accent and signals).
5. The accent is the most salient colour: samples vote weighted by chroma.
   Its root and the ground's root come from `corpus-roots.tsv`; an accent of
   the ground's own root, or a rupture (distance ≥ 5), is passed over.
6. Urgent, info, ok and muted keep their meaning: the corpus colour nearest
   the shipped signal colour that clears the floor and stays 60 apart from
   the accent (info) or the dim text (muted).

The result is a file in the format of `data/themes/*.conf`, declaring its
roots, distance and verdict, plus `# @wallpaper: NAME.png` (or `.jpg`): the
picture, copied beside it, is the palette's wallpaper. A name is lower-case
letters, digits and dashes; a shipped name is refused.

Where it lives: never in the checkout. With `shared_settings` set and the
shared root there, in `<shared root>/themes/`, so the other system lists the
same palette and the shared `theme` choice works on both; otherwise in
`~/.config/vivac/themes/` (Linux) or `%APPDATA%\vivac\themes\` (Windows).
Each side lists both folders after the eight, the shared one first. A file
there is checked as it is read: the thirteen tokens, every value in the
corpus, a wallpaper that is a plain name beside it; one that fails, or takes
a shipped name, is left out of the catalogue.

The same picture gives the same file on both sides:
`shared/fixtures/theme-from-image/` holds two small generated pictures and
the palettes both halves must make from them, and each half's tests compare
byte for byte. A JPEG can decode a shade differently on each side (libjpeg
against Windows' own decoder); the snapping to the corpus almost always
absorbs it, but only a PNG is guaranteed identical.
## 5. Bluetooth across the dual boot

Both systems use the same Bluetooth adapter, so a device sees one computer.
Pairing creates a new key, and each system keeps its own, so only the system
that paired last can connect. vivac copies Windows' keys into Linux, and
then both systems hold the same keys:

1. Pair the device on Linux.
2. Restart in Windows and pair it again there.
3. Shut Windows down fully, or use **Restart in Linux**, which restarts
   fully. Shift and Shut down also works. A plain Shut down with Fast
   Startup turned on is not enough.
4. On Linux, choose **Bluetooth: take pairings from Windows** in the bridge
   menu (`Super+Shift+B`).

After that, the device works on both systems with no more pairing. Pair it
again on either system and the steps start over.

The copy goes only from Windows to Linux. Linux reads the Windows registry
and never writes to it. On Windows, `bin\vivac-bt-sync.ps1` lists the paired
devices (name, address, Classic or LE). It only reads Plug and Play device
names and never touches the registry.

### The Linux side: `vivac-bt-sync`

- **Finds Windows.** It looks for a mounted NTFS file system that has
  `Windows/System32/config/SYSTEM`. `--windows DIR` names the mount,
  `--hive PATH` names a hive file or a copy of one, and `--reg FILE` reads a
  `.reg` export of `BTHPORT\Parameters\Keys` instead (regedit run as SYSTEM,
  or chntpw's `reged -x`). A partition encrypted with BitLocker cannot be
  read from Linux, so it is not found.
- **Reads the hive** with python-hivex (`hivex`, in the package list) and
  opens it read-only. An offline hive has no `CurrentControlSet`, so it
  reads the control set from `Select\Current`. The keys live under
  `Services\BTHPORT\Parameters\Keys\<adapter>`. A Classic device is a value
  named after its address. A Low Energy device is a subkey named after its
  address, holding `LTK`, `KeyLength`, `ERand`, `EDIV`, `IRK`, `CSRK`, and
  so on. Device names come from `Parameters\Devices\<address>\Name`.
- **Writes BlueZ's files**, `/var/lib/bluetooth/<adapter>/<device>/info`.
  It changes only the lines that need it and keeps every other byte:

  | Windows value | BlueZ key | Conversion |
  |---|---|---|
  | `<address>` (Classic, 16 bytes) | `[LinkKey] Key` | the bytes in stored order, upper-case hex |
  | `LTK` | `[LongTermKey] Key` | the same; written to `[PeripheralLongTermKey]` and `[SlaveLongTermKey]` instead when BlueZ has no `[LongTermKey]` for the device |
  | `KeyLength` (DWORD) | `EncSize` | decimal |
  | `EDIV` (DWORD) | `EDiv` | decimal |
  | `ERand` (QWORD, 8 bytes little-endian) | `Rand` | the bytes reversed, then decimal: `63 02 84 B8 5D 40 44 DF` is `16088054540146049635` |
  | `IRK` | `[IdentityResolvingKey] Key` | left alone when it matches in either byte order; otherwise stored order |
  | `CSRK`, `CSRKInbound` | `[LocalSignatureKey]`, `[RemoteSignatureKey]` `Key` | stored order, only when BlueZ has that section |

- **Writes only for devices both systems know.** A device that only Windows
  has paired is listed, but nothing is written for it. Pair it on Linux
  first. Some devices take a new address each time they pair. When Windows
  has a new address that Linux lacks, and the identity key matches a device
  Linux has under an old address, the device folder moves to the new address.
- **Changes nothing by default.** Without options it prints the plan: each
  device, and which keys would change. It never prints key values.
  `--apply` stops `bluetooth.service`, which would otherwise write its own
  copy back on exit. Then it saves each changed file as
  `info.vivac-bak-<UTC time>`, writes the new file in its place with the
  same mode, and starts the service again. `--ask` shows the plan and asks
  before applying. The bridge menu runs it that way, in a kitty window.
- **Refuses** to apply when Windows is hibernated (`hiberfil.sys` starts
  with `HIBR`, which Fast Startup also leaves) or when the hive was not
  closed cleanly (the two sequence numbers in its header differ). In both
  cases the file on disk may hold older keys than Windows uses.
- **Root**: `/var/lib/bluetooth` is readable by root only, so the tool runs
  itself through `sudo`, which asks for the password in the terminal. It
  adds no sudoers rule. A rule that let a program in your home directory run
  as root without a password would hand root to anything that can write
  there.

The conversions follow the ArchWiki (*Bluetooth*, "Dual boot pairing") and
the tools it links to. The Classic key, LTK, EDIV and ERand conversions are
the same in every source. The section an LTK belongs in, and the IRK byte
order, depend on the device. The rules above cover both cases the ArchWiki
lists. Copying from Linux to Windows would mean writing the Windows registry
from outside Windows. vivac does not do that.
## 5. The phone: KDE Connect

A phone running the KDE Connect app (Android, GrapheneOS included, from
F-Droid or the Play Store) pairs with either system and becomes part of
vivac. vivac does not speak KDE Connect's protocol itself: it asks the
KDE Connect daemon on the same machine, through its command line
(`kdeconnect-cli`) and, on Linux, its D-Bus interface. Pairing is KDE
Connect's own, done once on each system from the phone or KDE Connect's
window. Everything here hides itself when KDE Connect is not installed or
no paired phone is in reach: no bar module, no menu entry, no error.

| | Linux | Windows |
|---|---|---|
| Install | `kdeconnect` in the base packages; `kdeconnectd` starts with the session | optional: `bootstrap.ps1 -Phone` (winget `KDE.KDEConnect`) |
| The phone's notifications | through the notification daemon, as any program's; dunst marks them with a phone glyph (rule `vivac-phone`) | KDE Connect's own Windows notifications |
| The bar | `custom/phone`: the first reachable phone's battery, `charging` and `low` (20 % or less) classes, every phone in the tooltip | a phone glyph while a phone is reachable, a count when there are several, the names on hover; no battery (the Windows build has no D-Bus client to read it with) |
| The menu | **Phone…** in the bridge menu (`vivac-phone menu`): ring, send a file, send the clipboard, open the link on the clipboard on the phone (http and https only), browse the phone's files (sshfs), pair | a **Phone** category in the menu, also opened by a click on the bar: ring, send a file, send the clipboard, pair |

### What the phone may run on Linux

KDE Connect's *Run command* plugin lets the phone run commands the computer
lists. `vivac-phone commands` writes vivac's list for each paired device
(the groups of `~/.config/kdeconnect/trusted_devices`), into
`~/.config/kdeconnect/<device id>/kdeconnect_runcommand/config`, the file KDE
Connect's settings page writes: QSettings INI, key `commands` in `[General]`,
the value a quoted `@ByteArray(...)` of JSON

```json
{"vivac-lock": {"name": "Lock the screen", "command": "\"$HOME/.local/bin/vivac-phone\" run lock"}}
```

The list is fixed: `lock` (`loginctl lock-session`), `suspend`, `clip-other`
(this clipboard to the machine paired through vivac link, when there is one)
and `reboot-windows` (when the firmware has a Windows entry; it runs
`vivac-reboot-other --yes`: the tap on the phone is the confirmation, since
nobody may be at the screen to answer). Each entry only names one of these,
and `vivac-phone run` refuses any other name, so what the phone can do is
decided by vivac, not by the file. Entries whose key starts `vivac-` are
replaced on every run; any other is the user's own and is kept. A second run
changes nothing, `--dry-run` prints what it would write, `--device ID` limits
it to one phone. After writing, the daemon is told (D-Bus signal
`org.kde.kdeconnect.config.configChanged` on
`/kdeconnect/<device id>/kdeconnect_runcommand`) and sends the new list to
the phone. On Windows the phone runs nothing of vivac's.

### Not verified with a real phone

The gates exercise all of it against fake `kdeconnect-cli`, `busctl` and
`rofi` (Linux) and a fake `kdeconnect-cli` (Windows). The runcommand file is
read back by Qt's own QSettings and rewritten byte for byte. What still needs
a phone: the battery property names (`charge`, `isCharging` on
`org.kde.kdeconnect.device.battery`, taken from the 26.x sources), the
notification's app name (`KDE Connect`, from its notifyrc) that the dunst rule
matches, and KDE Connect for Windows' install path.

## Versions

The product has one version (`VERSION` at the root); each half has its own
(`linux/VERSION`, `windows/VERSION`). A release is tagged `vX.Y.Z` for the
product, `linux-vX.Y.Z` and `windows-vX.Y.Z` for a half. The bridge protocol
carries its own number (`v2` in the path, the beacon and the key labels); a
half refuses a peer whose protocol it does not speak, by answering `404`.
`v1` signed but did not encrypt; it was never released, and no half speaks
it.
