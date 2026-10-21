# Security architecture

## Layers reproduced from the workstation

- **UFW:** deny unsolicited inbound traffic, allow outbound traffic, IPv6 enabled.
- **ClamAV:** FreshClam signatures updated continuously; weekly on-demand home scan avoids the cost of always-on file access scanning.
- **rkhunter and Lynis:** explicit periodic integrity and hardening audits.
- **GNOME Keyring + KeePassXC:** secrets stay outside dotfiles.
- **fstrim timer:** storage maintenance without custom cron jobs.

The live workstation had both Firewalld and UFW installed, but only UFW active. This public design intentionally chooses one firewall to avoid competing rule managers.

## Commands

```bash
./scripts/apply-system.sh --dry-run
./scripts/deploy.sh security
systemctl --user enable --now clamav-home-scan.timer
workstation-security-audit
```

`apply-system.sh` backs up replaced system configuration, preserves existing UFW allow rules and never opens a public port. Review remote-access requirements before enabling a default-deny firewall over SSH.

No antivirus replaces package-signature verification, prompt updates, least privilege, browser isolation and tested offline backups.
