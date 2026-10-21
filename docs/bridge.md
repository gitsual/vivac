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
| [Palettes from a picture](#5-palettes-from-a-picture) | dual boot (or one system alone) | a disk both systems mount, to share them |

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

## Versions

The product has one version (`VERSION` at the root); each half has its own
(`linux/VERSION`, `windows/VERSION`). A release is tagged `vX.Y.Z` for the
product, `linux-vX.Y.Z` and `windows-vX.Y.Z` for a half. The bridge protocol
carries its own number (`v1` in the path and the beacon); a half refuses a
peer whose protocol it does not speak, by answering `404`.
