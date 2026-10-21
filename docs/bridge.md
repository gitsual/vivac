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
| [Bluetooth across the dual boot](#5-bluetooth-across-the-dual-boot) | dual boot | the Windows partition mounted on Linux |

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

## Versions

The product has one version (`VERSION` at the root); each half has its own
(`linux/VERSION`, `windows/VERSION`). A release is tagged `vX.Y.Z` for the
product, `linux-vX.Y.Z` and `windows-vX.Y.Z` for a half. The bridge protocol
carries its own number (`v1` in the path and the beacon); a half refuses a
peer whose protocol it does not speak, by answering `404`.
