# Virtual-machine validation

The VM test is a real KVM/QEMU guest, not a container presented as an Arch installation.

## Automated acceptance test

```bash
./scripts/test-vm.sh
```

The script:

1. downloads the official Arch Linux cloud QCOW2 image and verifies its upstream SHA-256 file;
2. creates a disposable 32 GiB sparse overlay, ephemeral SSH key and NoCloud seed;
3. attaches a read-only archive of the current working tree, excluding Git and VM artifacts;
4. boots the guest with KVM and user-mode networking bound only to loopback;
5. updates the guest, installs the base, graphical-login and VM package profiles;
6. deploys every Stow package into the guest user's HOME, then detects the guest's hardware facts and renders the machine-specific Waybar and Hyprland fragments from them;
7. runs the full repository checker and clean Neovim installation;
8. checks the Hyprland configuration, the rendered fragments (present, regular files, valid JSON, no drift) and required workstation executables;
9. runs the selected system profile as a dry-run so the test does not pretend firewall, Bluetooth or hardware effects occurred.

The host HOME, packages, services and firewall are not modified. Failed runs preserve logs and the overlay under ignored `.vm-test/`; successful runs clean the disposable run directory unless `--keep` is used.

## Interactive graphical VM

Run acceptance while retaining its tested overlay, then open that exact guest:

```bash
./scripts/test-vm.sh --keep
./scripts/open-tested-vm.sh
```

Alternatively, perform acceptance and graphical opening in one command:

```bash
./scripts/test-vm.sh --gui
```

After automated acceptance, the opener enables the VM variant of the graphical login (the disposable guest user is logged straight into Hyprland, no greeter and no passphrase) and the guest-service modules, reboots and keeps the QEMU window running. QEMU runs in its own full-screen mode on an empty host workspace so the guest boots at the whole monitor resolution (`VM_HOST_WORKSPACE` overrides the workspace; `Ctrl+Alt+F` leaves QEMU's full screen). The opener refreshes the guest's copy of the repository from the current tree before applying profiles, so it always runs what is checked out, not what was accepted earlier. The SSH key exists only in ignored local VM state and is never committed. Stop it cleanly with:

```bash
./scripts/open-tested-vm.sh --stop
```

Optional resource overrides:

```bash
VM_MEMORY_MB=12288 VM_CPUS=6 ./scripts/test-vm.sh --gui
```

## Keyboard and pointer in the graphical VM

The guest is a full Hyprland desktop, so it wants the same shortcuts as the host. Both cannot own the keyboard at once, so ownership is switched explicitly and never inferred:

- `scripts/vm-keyboard.sh` (run automatically by the graphical modes) adds session-only host bindings. `Ctrl+Alt+Home` toggles a Hyprland submap: outside it the host keeps every shortcut and unbound keys reach QEMU; inside it the only host binding is the toggle itself, so everything else, including `Super`, reaches the guest. A notification reports each switch. The bindings live in the running session only and disappear on a Hyprland reload; the host configuration is never rewritten. Override the key with `VM_TOGGLE_KEY` (a keysym name, `Ctrl+Alt` stays fixed).
- `Ctrl+Alt+F1`-`F12` are consumed by the compositor before any user binding on either side, so they always switch the host virtual console. Switch guest consoles from inside the guest with `chvt`.
- QEMU's own GTK hotkeys (`Ctrl+Alt+G`, `Ctrl+Alt+F`, `Ctrl+Alt+digit`) are handled by QEMU before the guest; the bundled desktop does not use `Ctrl+Alt` combinations, so nothing is lost.
- The guest gets a USB tablet, so the pointer is absolute and works in both modes without a grab.
- The guest console keymap follows `VM_CONSOLE_KEYMAP` (default `es`), validated against `localectl` and asserted in `/etc/vconsole.conf`; the bundled Hyprland layout is `es` as well, matching the source workstation.

Stop a kept VM with its recorded PID, then remove `.vm-test/run` when its evidence is no longer needed. The verified base image remains cached to avoid a repeated download.

## What the VM can and cannot prove

It proves package installation, deployment, editor installation, configuration parsing and the generic login path on a clean Arch guest. It cannot prove physical Bluetooth pairing, real microphone/speaker behavior, GPU-specific acceleration, disk partitioning or the user's private external AI services. Those remain explicit destination-side checks rather than simulated successes.
