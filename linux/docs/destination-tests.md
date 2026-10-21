# Destination tests

What this repository claims about a machine it has never seen, and how each
claim was checked. Every row carries exactly one status:

- **verified on author hardware**: run on the workstation vivac
  describes (NVIDIA, open kernel modules).
- **VM-verified**: exercised by `scripts/test-vm.sh` in the official Arch
  cloud image under QEMU/KVM with a virtio GPU, in one boot, on every
  phase tip before publication.
- **untested**: shipped as a recommendation. The code path is covered by
  the behaviour tests in `tests/cases/`, the claim is not.

A test (`tests/cases/test_destination_matrix.sh`) refuses a blank status,
an unknown status, a GPU family missing from this table, and a GPU status
that disagrees with `data/gpu-catalogue.tsv`. The author runs everything by
hand; there is no CI re-running it.

## GPU families

| Claim | Status |
|-------|--------|
| nvidia_open: open kernel modules, Turing and newer | verified on author hardware |
| nvidia_proprietary: proprietary driver, Maxwell and Pascal | untested |
| nvidia_legacy_470: 470 branch from the AUR, Kepler | untested |
| intel_xe: xe driver | untested |
| intel_i915: i915 driver | untested |
| amd_amdgpu: amdgpu driver | untested |
| virtio: virtual GPU | VM-verified |
| generic: Mesa only | untested |
| hybrid AMD or Intel with NVIDIA: both stacks plus PRIME offload | untested |
| Secure Boot with a DKMS module: warning printed, nothing refused | untested |

## Login

| Claim | Status |
|-------|--------|
| tuigreet login (`--desktop-login`) starts Hyprland | verified on author hardware |
| VM autologin variant (`--desktop-login --vm`) boots to the desktop | VM-verified |
| ReGreet in cage renders with the palette and both language axes | untested |
| greeter LANG and XKB_DEFAULT_LAYOUT reach the greeter process | VM-verified |

## Language

| Claim | Status |
|-------|--------|
| locale written and generated (`--locale`) | VM-verified |
| console keymap written (`--keymap`) | VM-verified |
| Hyprland keyboard layout rendered (`xkb_layout`) | VM-verified |
| CJK and emoji resolve by code point | VM-verified |
| fcitx5 environment and daemon start rendered (`ime=fcitx5`) | VM-verified |
| typing Japanese through Mozc in a session | untested |
| bootstrap and help panes in Spanish | VM-verified |

## Downloadable image

| Claim | Status |
|-------|--------|
| the sealed image boots and serves ssh | VM-verified |
| two copies present different host keys | VM-verified |
| the OVA's disk boots the same way | VM-verified |
| the split parts reassemble to the published checksum | VM-verified |
| VirtualBox imports the OVA | untested |
| VMware imports the OVA | untested |
| the first login forces a password change | untested |

## Desktop

| Claim | Status |
|-------|--------|
| ten numbered workspaces, wraparound binds | verified on author hardware |
| workspace strip renders ten numbers with no session state | VM-verified |
| workspace glyphs update live from Hyprland events | verified on author hardware |
| F1 opens the Hyprland help pane in a session | verified on author hardware |
| help panes render through the stowed script without a session | VM-verified |
| hypridle locks, blanks and suspends on schedule | untested |
| nwg-bar power menu opens beside the rofi one | untested |
| clipboard history picker | untested |
| desktop application set installs | VM-verified |
| ricing tool set installs and is configured through Stow | VM-verified |
