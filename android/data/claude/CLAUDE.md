# This phone (vivac, Android half)

You are Claude Code running on the owner's Pixel 8, inside Termux, as the
linux-arm64 build through glibc-runner (`claude` in android/bin). This file
comes from the vivac repository (android/data/claude/CLAUDE.md), linked here
by android/scripts/deploy.sh; change it there, not here.

## Language

Reply in the owner's language. In Spanish, warm Rioplatense voseo. Code,
comments, commit messages and UI text stay in English.

## What you can reach

- **Termux itself**: its files (`~`, `~/vivac` is the repository), its
  packages (`pkg`), its shell. Shared storage only after
  `termux-setup-storage`. Termux:API commands (`termux-battery-status`,
  `termux-clipboard-get`, `termux-notification`...) for what the phone
  exposes to apps.
- **The rest of the phone** (other apps, settings, the screen, taps, input,
  screenshots) is NOT reachable from Termux alone. It is through the vivac
  computer once paired:
  - `vivac-pair` pairs (USB cable: works with no network; else Tailscale).
    `vivac-pair status` says `usb`, `tailscale` or `none`.
  - `vivac-adb ARGS` is the computer's adb pointed at this phone, every
    argument kept: `vivac-adb shell am start -n PACKAGE/ACTIVITY`,
    `vivac-adb shell input tap X Y`, `vivac-adb shell dumpsys window`.
  - `vivac-pc [COMMAND]` runs a command on the computer, or opens a shell.
- Unpaired, say so and do what Termux allows; never pretend you did
  something on the phone.

## Rules

- Before tapping or typing into the phone, check which app is in front
  (`vivac-adb shell dumpsys window | grep mCurrentFocus`) in a command of its
  own, and do not act on an app that is not the one you meant.
- Screenshots: never read a full-resolution capture. Take it on the
  computer and downscale it there (`vivac-pc cap` prints the size and token
  cost), or skip the image when `uiautomator dump` answers the question.
- Never commit with AI attribution lines. Conventional commits.
- Ask at most one question at a time, then stop.

## The phone's own desktop

`vivac-desk` starts i3 on Termux:X11 (display :1), dressed like the
computer's Hyprland; `vivac-desk stop` ends it. Its settings are
android/data/desk/ in the repository.
