# The bridge: what Linux and Windows do together

vivac runs on Arch Linux (`linux/`) and on Windows 11 (`windows/`). Each half
stands on its own. Together they also share state across a dual boot and talk
live across a local network. This file is the contract both halves implement;
a change here is a change to both.

Four features, each usable alone:

| Feature | When it helps | Needs |
|---|---|---|
| [Shared choices](#1-shared-choices) | dual boot | a disk both systems mount |
| [Reboot into the other system](#2-reboot-into-the-other-system) | dual boot | UEFI |
| [The drop tray](#3-the-drop-tray) | dual boot | a disk both systems mount |
| [vivac link](#4-vivac-link) | two machines on one network | a pairing code |

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
| `ping` | answers with its name, system, version and hardware address |

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

## Versions

The product has one version (`VERSION` at the root); each half has its own
(`linux/VERSION`, `windows/VERSION`). A release is tagged `vX.Y.Z` for the
product, `linux-vX.Y.Z` and `windows-vX.Y.Z` for a half. The bridge protocol
carries its own number (`v2` in the path, the beacon and the key labels); a
half refuses a peer whose protocol it does not speak, by answering `404`.
`v1` signed but did not encrypt; it was never released, and no half speaks
it.
