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

## The vivac theme (system UI)

The phone's system UI is themed with resources, not code patches. `vivac-os-customize`
applies two projects (`patches/<project>/`; `vivac-files/` inside a project is copied
in as new files, symlinks followed):

| Project | What |
|---|---|
| `vendor/adevtool` | patch adds three modules and three fonts to shiba's `device.mk`; `vivac-files/.../shiba/vivac-theme/` holds the static RROs |
| `frameworks/base` | patch adds the `VivacFonts` filegroup and two aliases to the font config; `vivac-files/data/fonts/vivac/` holds the families (symlinks to the launcher's fonts) |

Static overlays (`isStatic`, priority 900, `/product/overlay`, always on):

- `VivacThemeFramework` (`android`): dark by default (`config_defaultNightMode=2`);
  Material You seed pinned to coral `#E1777D` via `theming_defaults` (`TONAL_SPOT`,
  no wallpaper colors); static `system_*` ramps from the vivac palette; fonts
  (`config_bodyFontFamily` Space Grotesk, headline and lock clock Unbounded ExtraBold);
  dialog and button radii (24dp, pill).
- `VivacThemeSystemUI` (`com.android.systemui`): shade, quick settings tiles,
  power menu, bottom sheets, notification scrim radii.
- `VivacThemeSettings` (`com.android.settings`): panel and card radii.

System fonts added: `space-grotesk`, `unbounded` (alias `unbounded-extrabold`),
`jetbrains-mono`, all variable (`wght`). `jetbrains-mono` is installed for apps and
labels; the framework has no config key to make it a system default.

Limits: the runtime palette is generated from the seed, so neutrals are
coral-tinted, not exactly `#18131B`; the static ramps only show where the
dynamic one is not applied. Code that hard-codes `sans-serif` keeps Roboto.
Nothing here is compiled or visually checked yet (needs the full soong analysis,
~38 GB, so swap first): `m VivacThemeFramework VivacThemeSystemUI VivacThemeSettings`.
`tests/cases/test_os_theme.sh` checks the sources are consistent.

## Shade redirect (system UI code patch)

Swiping the status bar down while vivac's home is in front opens the launcher's own
shade. Inside any other app Android's shade is untouched. Patch
`frameworks/base/0002-vivac-shade-redirect.patch` (hook, 2 hunks in
`PhoneStatusBarViewController.kt`) plus the new class `VivacShadeRedirect.kt` in
`vivac-files/` (all the logic, so upstream merges only touch the hook).

- Hook: `PhoneStatusBarViewTouchHandler.onTouchEvent`, after the "panels enabled" check, so
  the gesture is judged where the status bar receives it, before Android's shade starts.
- Armed at `ACTION_DOWN` (no binder): keyguard not locked (`KeyguardManager`), one finger,
  not the top edge (`y < 1`), shade fully collapsed and enabled, not dual shade.
- Fires once, when the move passes touch slop, downward and more vertical than horizontal,
  still one finger: the task in front has `ACTIVITY_TYPE_HOME`, its package is
  `dev.vivac.launcher` and the default home resolves to that package.
- Then `startActivityAsUser(UserHandle.CURRENT)` of `dev.vivac.launcher/.AvisosEntry`, action
  `dev.vivac.launcher.action.OPEN_AVISOS`, `NEW_TASK | SINGLE_TOP`; Android's tracking
  gets an `ACTION_CANCEL` and the rest of the gesture is swallowed.
- Fallback: any check failing, any exception (component missing, permission) means nothing
  is swallowed and Android's shade opens as usual. The decision is made once per gesture.
- Not redirected: `expandNotificationsPanel` and other API calls (they never go through
  the touch path), two-finger or sideways swipes, an already expanded shade, taps, lock screen.
- A second pull while vivac's shade is up (vivac still on top) is routed to vivac again;
  `SINGLE_TOP` just re-delivers the intent, which the launcher treats as "open", so it is a no-op.
- Limit: only the legacy touch path is patched. Our release configs leave `scene_container`
  and `status_bar_event_forwarding_modernization` at their disabled default; if upstream
  turns either on, the hook has to move (the test cases will not notice).
- Not compiled: no Kotlin toolchain without the soong analysis. Check with
  `m SystemUI` after the next sync, before flashing.
`tests/cases/test_os_shade_redirect.sh` checks the contract against the launcher manifest.

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
