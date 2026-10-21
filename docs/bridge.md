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
| [Phones: LocalSend](#5-phones-localsend) | a phone on the same network | the LocalSend app on the phone, a PIN |

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

## 5. Phones: LocalSend

The **phone drop**. A phone (Android or iOS) with the stock
[LocalSend](https://localsend.org) app, from F-Droid or a store, sends files
and texts to either half and receives files from it; nothing of vivac's is
installed on the phone. Both halves speak LocalSend's own protocol, v2
([github.com/localsend/protocol](https://github.com/localsend/protocol)),
so any LocalSend device works, a vivac machine included.

| | Linux | Windows |
|---|---|---|
| Program | `vivac-localsend` (Python standard library) | `bin\vivac-localsend.ps1`, `lib\LocalSend.psm1` |
| Receiver | user service `vivac-localsend.service` | sign-in task `\vivac\localsend` |
| On, off, PIN | `vivac-localsend on`, `off`, `status`, `pin [--new]` | `vivac-localsend.ps1 on`, `off`, `status`, `pin [-New]` |
| Send | `vivac-localsend send [--to ALIAS] FILE...`, `--text TEXT` | `vivac-localsend.ps1 send [-To ALIAS] FILE...`, `-Text TEXT` |
| Menu | bridge menu (`Super+Shift+B`): **Send to phone…**, **Phone drop: on/off + PIN** | the same two entries in the menu |
| Firewall | `apply-system.sh --bridge` | `apply-system.ps1 -LocalSend` |

### Discovery

UDP multicast to `224.0.0.167`, port `53317`, as LocalSend does. A device
announces itself with:

```json
{"alias":"<name>","version":"2.1","deviceModel":"Linux|Windows","deviceType":"desktop",
 "fingerprint":"<32 hex>","port":53317,"protocol":"http","download":false,"announce":true}
```

A device that hears `"announce":true` (or v1's `"announcement":true`) answers
by `POST /api/localsend/v2/register` with its own info, or, when that fails,
with the same JSON and `"announce":false` to the group. The receiver
announces when it starts and answers every announcement; the sender
announces three times in two seconds and keeps what answers. While the
receiver holds port 53317, a sender on the same machine reads what the
receiver heard (`localsend-devices.json` in the state folder, ten minutes at
most); otherwise it listens on 53317 itself for those two seconds. Where
multicast does not get through (another subnet, a guest Wi-Fi), `--peer
HOST:PORT` / `-Peer HOST:PORT` names the device directly.

### Receiving

Plain HTTP on TCP `53317`, `protocol` `http`: neither half can make a TLS
certificate with what it is allowed to use (Python's standard library has no
certificate generator; PowerShell 5.1 would have to write into the user's
certificate store), so phones send to vivac over http. The fingerprint is
then, as LocalSend specifies for http, a random string: 16 random bytes in
hex, made once and kept in the state folder (`localsend-id`).

| Request | Answer |
|---|---|
| `GET /api/localsend/v2/info` | this device's info |
| `POST /api/localsend/v2/register` | this device's info; the caller is remembered for the sender |
| `POST /api/localsend/v2/prepare-upload?pin=PIN` | `200 {"sessionId":…,"files":{id:token}}`; `204` when it held only texts; `400` malformed; `401` no PIN or a wrong one; `409` another sender's session is running (it lapses after five idle minutes); `413` a file over 2 GiB; `429` five wrong PINs from that address in the last minute |
| `POST /api/localsend/v2/upload?sessionId&fileId&token` | `200`; `400` missing parameters or a body shorter than announced; `403` unknown session, another address, a wrong or used token; `413` a body longer than announced; `422` the SHA-256 differs from the announced one |
| `POST /api/localsend/v2/cancel?sessionId` | `200`; the files already received stay |
| anything else | `404` |

- **The PIN is required.** It is `localsend_pin` in the settings file (4 to
  32 letters and digits), or, with `localsend_pin=auto` (the default), six
  random digits made the first time the receiver is turned on and kept in the
  state folder (`localsend.pin`, this user only). `status` and the menu's
  **Phone drop: on/off + PIN** say it. A phone sends without one first; the
  `401` makes LocalSend ask for it.
- **Files** go into the same folder as vivac link's, `Downloads/vivac-link/`
  (`VIVAC_LINK_INBOX` in the gates), under the same safe name: no folder, no
  control or forbidden character, no leading dot on Linux, no device name on
  Windows; `name (2).ext` when the name is taken, never over anything. Each
  is streamed to a hidden `.localsend-*.part` file beside them, its SHA-256
  checked when one was announced, and only then given its name; a refused
  or cut upload leaves nothing behind. Up to 2 GiB a file.
- **Texts**: LocalSend sends a message as a `.txt` whose `preview` is the
  text. It is shown in a notification, as text, and goes nowhere else: not
  to the clipboard, not to a file. The answer is `204`, as LocalSend's own
  receivers answer.
- **One notification per batch**: "3 files from <alias>" (or "<alias> sent
  <name>"), a click opens the folder. Nothing received is opened or run.
- **Only when turned on.** Nothing listens until `on` (or the menu). The
  firewall step opens TCP and UDP 53317 to the local subnet only (UFW rule
  "vivac phone drop"; Windows rule "vivac phone drop", private networks).
  `-LocalSend` is a switch of its own on Windows, apart from `-Link`: a
  phone is not the paired machine, and either may be wanted alone. On Linux
  `--bridge` opens both ports, as the one system step of the bridge; the
  service is still only started by `vivac-localsend on`.

### Sending

`prepare-upload` with this device's info and, for each file, its id, name,
size, MIME type, SHA-256 and modification time; the phone's owner accepts on
the phone (up to five minutes), then each file is streamed to `upload` with
its token; on a failure the session is cancelled. A phone that asks for a PIN
gets the one given with `--pin` / `-Pin`, or, on Linux, typed in rofi or on
the terminal.

Phones serve **https with a self-signed certificate**. No authority vouches
for it; LocalSend's trust is that the certificate's SHA-256 is the
`fingerprint` the device announced. Both halves accept the self-signed
certificate only after checking exactly that (Python:
`getpeercert(binary_form=True)`; .NET: the `SslStream`'s
`RemoteCertificate`), before sending a byte. A device named with `--peer`
announced nothing: the certificate it shows on the first request is the one
every later request must show.

The device is chosen by alias (`--to` / `-To`: the whole name, case aside,
else the only one it begins), else in rofi (Linux) or a list in vivac's style
(Windows). **Send to phone…** in the menu picks what to send first: rofi
lists the clipboard's text and the newest files of the usual folders
(Shift+Enter for several); Windows opens its own file picker.

### Gates

`VIVAC_LOCALSEND_SINK=<file>` writes each notification as a line
`title|body|folder` instead of showing it (on Windows the sign-in task is a
file beside it); `VIVAC_LOCALSEND_PORT` and `VIVAC_LOCALSEND_INTERFACES` keep
discovery on the gates' own port and on the loopback.

## Versions

The product has one version (`VERSION` at the root); each half has its own
(`linux/VERSION`, `windows/VERSION`). A release is tagged `vX.Y.Z` for the
product, `linux-vX.Y.Z` and `windows-vX.Y.Z` for a half. The bridge protocol
carries its own number (`v1` in the path and the beacon); a half refuses a
peer whose protocol it does not speak, by answering `404`.
