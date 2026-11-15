# vivac for Android

The phone is vivac's third half, next to `linux/` and `windows/`. Like them, it is a
layer on top of an OS someone else maintains (GrapheneOS or any Android), never a
fork: the system keeps its own monthly security updates. It runs inside
[Termux](https://termux.dev) and needs neither root nor ADB.

What it gives today:

- **Hermes sees the phone.** `vivac-mcp` is an MCP server that Hermes (on the PC)
  reaches over SSH. Its tools cover device info, battery, location, notifications,
  clipboard and Wi-Fi, plus actions: notify, vibrate, torch, speak, take a photo, open a URL.
- **Facts without identifiers.** `vivac-facts` describes the phone from an allowlist.
  Serial, IMEI, MAC and phone number never leave it.
- **Photos to the chat.** `vivac-photo-get` through `vivac-gate`, and
  `vivac-phone-pull` on the PC, so Hermes can send what the camera took.

Coming in the next phases: alerts from the phone to WhatsApp, the phone as a
`vivac link` peer, and themes (Termux colours plus a wallpaper that Material You
turns into system colours).

## 1. On the phone (once)

1. Install from **F-Droid**, all three from the same source because they share a
   signature: **Termux**, **Termux:API**, **Termux:Boot**. Open Termux:Boot once.
2. Install **Tailscale** and log in to the same tailnet as the PC.
3. Settings → Apps → Termux, Termux:API and Tailscale → Battery → **Unrestricted**.
4. Termux:API needs **Location** and **Camera** permissions. Notification access
   (Settings → Notifications → Device & app notifications) lets it read notifications.
5. In Termux:

   ```sh
   curl -fsSL https://raw.githubusercontent.com/gitsual/vivac/main/android/scripts/bootstrap.sh | bash
   sshd
   termux-battery-status   # must print JSON: Termux:API works
   ```

`bootstrap.sh` installs `python python-cryptography openssh termux-api git` from
Termux's repository, clones the repo into `~/vivac` (later runs only fast-forward it)
and runs `android/scripts/deploy.sh`. The deploy links the tools into `$PREFIX/bin`,
writes `~/.termux/boot/vivac` (wake lock plus sshd on every boot) and sets
`PasswordAuthentication no`. Anything of yours in the way is moved to
`~/.local/state/vivac/backups/<stamp>/`, never deleted.

## 2. On the PC: let Hermes in

```sh
ssh-keygen -t ed25519 -f ~/.ssh/vivac_phone -N '' -C hermes-vivac-phone
```

On the phone, append the public key to `~/.ssh/authorized_keys`, **pinned to the gate**:

```
command="vivac-gate",no-pty,no-port-forwarding,no-agent-forwarding,no-X11-forwarding ssh-ed25519 AAAA... hermes-vivac-phone
```

On the PC, the `pixel` alias goes either in `~/.ssh/config` or in a file of its
own, `~/.config/vivac/ssh_config` (the HostName is the phone's Tailscale name, so it
works at home, away, and when the phone's Tailscale IP changes):

```
Host pixel
    HostName <phone's tailscale name>
    Port 8022
    IdentityFile ~/.ssh/vivac_phone
    IdentitiesOnly yes
    BatchMode yes
    StrictHostKeyChecking accept-new
```

`vivac-phone-pull` passes `~/.config/vivac/ssh_config` with `-F` when it exists.

In Hermes' `~/.hermes/config.yaml`:

```yaml
mcp_servers:
  pixel:
    command: ssh
    args: [-o, BatchMode=yes, pixel, vivac-mcp]
    trust: untrusted   # actions ask in the chat first; read tools (readOnlyHint) don't
```

With the alias in `~/.config/vivac/ssh_config`, pass it explicitly (absolute path):
`args: [-F, <absolute path of ~/.config/vivac/ssh_config>, pixel, vivac-mcp]`.

Check it with `ssh pixel vivac-mcp` (type `{"jsonrpc":"2.0","id":1,"method":"ping"}`,
expect `{"jsonrpc": "2.0", "id": 1, "result": {}}`), then restart the gateway.

The Hermes home is shared with Windows, so Hermes there sees `mcp_servers.pixel` too.
It needs the same alias and key under `%USERPROFILE%\.ssh`, or the tool fails on
Windows only.

## Tools

| Tool | Kind | Runs |
|---|---|---|
| `device_info` | read | `vivac-facts` |
| `battery` | read | `termux-battery-status` |
| `location` | read | `termux-location -p network\|gps\|passive -r once` |
| `notifications` | read | `termux-notification-list` |
| `clipboard_get` | read | `termux-clipboard-get` |
| `wifi` | read | `termux-wifi-connectioninfo`, without BSSID or MAC |
| `notify` | action | `termux-notification --title --content` |
| `clipboard_set` | action | `termux-clipboard-set` |
| `vibrate` | action | `termux-vibrate -d` (5 s max) |
| `torch` | action | `termux-torch on\|off` |
| `tts_speak` | action | `termux-tts-speak` |
| `photo` | action | `termux-camera-photo` into `~/.local/share/vivac/photos` |
| `open_url` | action | `termux-open-url`, http(s) only |

To limit Hermes to the read tools, add
`tools: {include: [device_info, battery, location, notifications, clipboard_get, wifi]}`
under `mcp_servers.pixel`.

Not possible without root or ADB: screenshots and listing installed apps.

## Development

Everything is tested on the PC against fake `termux-*`, `getprop` and `ssh`. No
phone is needed:

```sh
bash android/scripts/check.sh   # syntax, linter, Python syntax, privacy scan, shared data, tests
```
