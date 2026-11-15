# Security: what the android half exposes

| Component | Reachable by | Can do |
|---|---|---|
| `sshd` (Termux, port 8022) | Anyone on the networks the phone is on, Tailscale included | Key login only (`PasswordAuthentication no`, set by deploy). |
| Hermes' key | Hermes on the PC | Only `vivac-gate`, pinned in `authorized_keys` with `command=` and `no-pty`, no forwarding. |
| `vivac-gate` | That key | Exactly `vivac-mcp`, or `vivac-photo-get photo-YYYYMMDD-HHMMSS.jpg` from the photo folder. Anything else is refused. |
| `vivac-mcp` | Through the gate | The 13 fixed tools in README.md. No tool takes a command line, a shell string or an arbitrary path. Text arguments are capped at 4000 characters, vibration at 5 s, and URLs must be http(s). |
| `vivac-facts` | Through `device_info` | An allowlist of fields. Serial, IMEI, MAC and phone number are never read into the output. |

## Decisions

- **No root, no fork.** GrapheneOS keeps a locked bootloader and verified boot. vivac only
  uses what Termux:API grants, and Android shows and revokes each permission.
- **Actions ask first.** `vivac-mcp` marks the six read tools `readOnlyHint: true`.
  With `trust: untrusted` on `mcp_servers.pixel`, Hermes asks in the chat before any
  other tool runs (`tools/mcp_tool_handlers.py`, `_trust_gate_check`). Hermes'
  `approvals.mode` does not cover MCP tools. To give Hermes read-only access, use
  `tools.include` (see README.md).
- **Location and notifications are personal data.** They travel only inside the SSH
  session between the phone and the PC. Once in Hermes, they go wherever Hermes'
  model provider takes them.
- **Your own login to Termux** uses a different, unpinned key of yours. Never reuse
  Hermes' key for it.

## Reporting

Same as the rest of vivac: see `../linux/SECURITY.md`.
