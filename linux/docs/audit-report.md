# Publication audit

## Scope

The repository is built from an explicit allowlist covering desktop, graphical login, launchers, editor, audio/Bluetooth, theme, shell, security, storage architecture and generalized user automations. Machine-bound service behavior is represented by parameterized local tasks rather than copied endpoints or identities. Credentials, key stores, browser profiles, histories, private media, caches, generated state, VM artifacts, backups and nested repositories remain outside the published tree.

## Source audit

Candidate files were classified before import for private keys, credential assignments, emails, absolute home paths, private network addresses, MAC addresses and UUIDs. The pre-import pass examined 127 text files and reported 98 review locations by class: 9 credential-like assignments, 52 absolute home paths, 30 private/loopback IPv4 references and 7 UUIDs; it found no private-key headers, email addresses or MAC addresses. Findings are recorded only by file/line/class; secret values are never copied into this report.

The source Neovim tree contained a credential-like assignment in commented legacy code and several absolute machine paths. The legacy block was removed and path checks now use PATH/environment variables. Audio serials and node names were replaced by local templates. Disk identifiers were converted into an architecture recommendation and placeholders.

## Release gates

- Bash syntax, ShellCheck and shfmt;
- Python parsing and JSON validation;
- compile-only validation of every Neovim Lua file;
- systemd unit verification;
- sorted, unique, resolvable package manifests;
- broken-symlink and unexpected-binary checks;
- secret, identity, hardware and private-network scanning;
- Gitleaks against working files and Git history;
- two consecutive deployments into an isolated temporary HOME;
- preservation of a pre-existing conflict in the backup tree;
- clean Neovim startup in an isolated HOME;
- dry-run of privileged system configuration;
- inspection of the exact staged Git object set before publication.

## Verified release evidence

The following gates were rerun on the final working tree:

- `scripts/check.sh`: passed all eight stages, including syntax/ShellCheck, structured configuration, systemd verification, sorted manifests, symlink/file-type checks, privacy scanning, Gitleaks over working files, disposable-HOME dry-run and deployment regression;
- isolated Stow regression: two consecutive deployments preserved hashes for all 44 source dotfiles, backed up one pre-existing conflict exactly once and left links targeting repository sources;
- `scripts/test-neovim.sh`: clean Lazy installation and startup passed locally and in the VM; NvChad, Treesitter, Avante and cmp loaded; `cmp-async-path` came from the author's GitHub mirror; the source lockfile hash remained unchanged; transient network failures are retried at most three times and only an error-free final log is accepted;
- package validation: the 55-package base and the composed 59-package base/login/VM profiles resolved inside `archlinux:base`; the AUR manifest had no active entries;
- real VM acceptance: an official checksum-verified Arch cloud image booted under KVM with 8 GiB RAM and 4 vCPUs; all composed packages installed, all Stow packages deployed, the eight-stage checker and clean Neovim test passed, Hyprland reported `config ok`, and required executables were asserted;
- graphical VM: the tested overlay rebooted with greetd active and enabled and the static, device-activated QEMU guest agent active through its virtio channel;
- `bootstrap.sh --dry-run` ran with a disposable HOME and modular `apply-system.sh --dry-run` completed without changing host packages, services, audio, Bluetooth or firewall state.

Git history and exact staged-object scans are performed after repository initialization. The published commit and remote are verified externally rather than embedded as a self-referential identifier in that same commit.
