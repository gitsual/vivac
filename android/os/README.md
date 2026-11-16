# vivac-os: GrapheneOS built and signed at home

vivac-os is GrapheneOS for the Pixel 8 (`shiba`), built from the official
signed release tags, signed with our own keys, and served to the phone's
Updater app from our own static update server. A monthly job follows
upstream on its own; the phone is only wiped once, when we decide to switch.

## Layout (outside the repo, on the NVMe: `~/m2/vivac-os/`)

| Path | What |
|---|---|
| `src/` | GrapheneOS source (`repo`), ~350 GB with build output |
| `keys/shiba/` | signing keys, encrypted with one passphrase. Back up OFF this PC |
| `releases/` | signed releases (`script/generate-release.sh` output) |
| `server/` | static folder the phone's Updater downloads from |
| `backups/` | phone backups made by `vivac-os-backup` |
| `logs/` | build and sync logs |

## Tools (`os/bin/`)

| Tool | Does |
|---|---|
| `vivac-os-upstream` | prints the build GrapheneOS ships now (`shiba-stable`) |
| `vivac-os-publish` | copies a signed release to `server/`, channel metadata last |
| `vivac-os-backup` | backs up the phone over adb before the wipe, with a checklist |

## Monthly flow (automatic once set up)

1. A systemd timer runs `vivac-os-upstream`; if it is newer than our last build:
2. `vivac-os-sync`: shallow `repo init --depth=1` of the new tag, verify its signature, `repo sync -c --no-tags` (git cannot resume a cut fetch; full history left 461 GB of tmp_pack).
3. Apply the vivac customizations, regenerate vendor files (`adevtool`).
4. `m vendorbootimage vendorkernelbootimage target-files-package`, then
   `script/finalize.sh` and `script/generate-release.sh shiba BUILD`, with the
   key passphrase unsealed from the TPM (`systemd-creds`).
5. `vivac-os-publish` to `testing`; after a check, promote to `stable`.
6. Notify through Hermes (WhatsApp) on success or failure.

## Switching the phone (manual, wipes it, NOT done yet)

1. `vivac-os-backup ~/m2/vivac-os/backups/$(date +%F)` and every box in its
   `CHECKLIST.md` (Seedvault code, 2FA export, Signal, Termux, eSIM).
2. OEM unlocking on, `fastboot flashing unlock` (wipes), `flash-all.sh` from
   our install zip (writes our AVB key), `fastboot flashing lock` (wipes again).
3. Check the verified-boot key hash shown on boot is ours, not the official
   `cd7479653aa8...`.
4. Restore: Seedvault, then `sdcard/` back, then apps from `packages.tsv`.

Way back to official GrapheneOS: unlock, `fastboot erase avb_custom_key`,
flash the official install zip, lock.

## Risks we accepted

- Losing the keys means no more updates without another wipe.
- If the monthly job breaks, the phone gets no security patches until fixed.
- Official GrapheneOS OTAs stop once the phone runs our keys.
