# Security

Report a vulnerability privately through GitHub's security advisory form for
this repository rather than in a public issue.

What this repository does to stay safe to publish and to run:

- **No secrets, no identities.** No credentials, device identifiers, user
  paths, e-mail addresses, SIDs or MAC addresses are committed; a gate
  (`tests/cases/Repository.Tests.ps1`) scans every file for them.
- **Nothing is deleted.** A deploy backs up any file that is not exactly what
  vivac wrote before replacing it, and `scripts/uninstall.ps1` restores the
  originals. Registry values vivac changes are snapshotted before the first
  change.
- **Machine-wide changes are opt-in and separate.** `deploy.ps1` and
  `bootstrap.ps1` never need elevation; firewall, Defender and lock-screen
  changes live in `scripts/apply-system.ps1`, each behind its own switch and
  each with `-DryRun`.
- **The bar can run three verbs and nothing else.** Zebar only executes what
  `static/zebar/vivac/zpack.json` grants; the grant is a regular expression
  pinned by a test.
- **Tasks run without a shell.** `scripts/task.ps1` passes an argument array
  straight to the program; nothing in a task file is interpreted.

No antivirus replaces prompt updates, least privilege, software from its
original source, and tested offline backups.
