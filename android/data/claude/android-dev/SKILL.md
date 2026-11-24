---
name: android-dev
description: Build, run, see, drive and debug Android apps on this phone with vivac-dev (adb to the phone itself). Use for any work on an Android app from Termux - building and installing, reading the screen, tapping, logs, crashes, ANRs, performance, an app's database or preferences, deep links - and before touching any app's screen.
---

# Android development on the phone: vivac-dev

You run inside Termux on the phone. `vivac-dev` reaches this phone's own adbd
over wireless debugging (localhost), which gives the shell user's powers
without root. Every verb prints short text meant for you. `vivac-dev -h` and
`vivac-dev VERB -h` list everything.

## First: is it connected?

```sh
vivac-dev doctor            # tools installed, device, focus
```

- "no device": wireless debugging is off or this boot was not connected yet.
  Run `vivac-dev connect`. If it was never paired, ask the user to open
  Developer options > Wireless debugging > Pair device with pairing code and
  tell you PORT and CODE, then `vivac-dev pair PORT CODE`. Wireless debugging
  wants Wi-Fi on; it turns itself off after a reboot or a network change.
- A missing tool: `pkg install android-tools imagemagick sqlite openjdk-17 aapt2 rsync`.

## The loop

```sh
vivac-dev build ~/src/app --pkg com.example.app        # build, install, relaunch, report crash + focus
vivac-dev build ~/src/app --pkg com.example.app --remote arch   # same, compiled on the PC (much faster)
vivac-dev ui                    # what is on screen, with tap coordinates
vivac-dev tap "Save" --pkg com.example.app
vivac-dev wait "Saved" --timeout 5
vivac-dev crash com.example.app # Java and native crashes of that app only
vivac-dev log com.example.app --level W
```

## Seeing the screen: cheapest first

1. `vivac-dev ui` - text, no image. Answers almost everything: what is shown,
   what is clickable, where to tap. Always try it first.
2. `vivac-dev shot --crop top|middle|bottom` - part of the screen, 480 px wide.
3. `vivac-dev shot` - the whole screen at 480 px (~700 tokens). It prints the
   path, size and token cost; then Read that path.
4. `vivac-dev shot --width 1080` only when something small is illegible, a
   colour or spacing defect is being judged, or the user asks. Say why.

Never read a screenshot at full resolution by default, and never two in a row:
judge one, then decide.

## Touching the screen: rules

- `tap`, `type`, `key`, `swipe` require `--pkg` and refuse when another app has
  the focus. That is deliberate: this phone is also the user's, and a session
  of theirs (a VNC viewer, a chat) may be in front. If it refuses, do NOT
  reach for `--any`; tell the user what has the focus and wait.
- Re-read `vivac-dev ui` after each action that changes the screen rather than
  assuming where things moved.
- `clear` and `uninstall` lose data and want `--yes`: ask the user first.

## Debugging an app

| Need | Verb |
|---|---|
| version, debuggable, deep link schemes, permissions | `vivac-dev info PKG` |
| open a deep link | `vivac-dev open 'scheme://path?x=1' --pkg PKG` |
| why it closed | `vivac-dev crash PKG`, then `vivac-dev log PKG --level E` |
| it froze | `vivac-dev anr PKG` |
| slow or heavy | `vivac-dev perf PKG` (memory, janky frames, percentiles); `--reset` between runs |
| its database (Room/SQLite) | `vivac-dev sql PKG app.db "select * from place limit 5"` |
| its files and preferences | `vivac-dev files PKG [dir]`, `vivac-dev pull PKG path`, `vivac-dev prefs PKG` |
| follow the log live | `vivac-dev log PKG -f` (runs until interrupted: use it in the background) |

`sql`, `files`, `pull` and `prefs` use run-as, so they need a debug build.
`sql` copies the database with its WAL and opens it read-only: it never
changes the app's data.

## Building on the phone

Local builds need `openjdk-17` and Termux's `aapt2` (Gradle's bundled aapt2 is
x86 only; vivac-dev passes the override itself). They are slow and hot; for
anything big prefer `--remote HOST`, which rsyncs the project to
`~/.cache/vivac-dev/build/<name>` on that machine over ssh, builds there and
brings the APK back.

## Working on an app so it can be driven

To let tools and agents use an app without the screen, give it an entry with
data: an exported activity with a deep link (`<data android:scheme="app" />`)
that validates every parameter, then `vivac-dev open`. `vivac-dev info` shows
which schemes an app already answers to.
