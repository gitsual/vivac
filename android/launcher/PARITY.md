# vivac launcher: parity checklist

The bar: everything a full Android launcher (Pixel Launcher, Lawnchair) lets you do,
plus test coverage for every line we write. Each row is closed with a failing test first,
then the code, then a check on the phone.

Status: `done` · `todo` · `n/a` (Android does not allow it for a third-party launcher; the reason is given).

## Home (Campamento)

| # | Feature | Status |
|---|---------|--------|
| H1 | Dock with chosen apps | done |
| H2 | Apps pinned to the home screen | done |
| H3 | Widgets: add, configure, remove | done |
| H4 | Reorder dock, pins and widgets (move earlier / later) | done: drag apps within and between dock, route and laderas, and out of the petate; widgets by dragging too (card, or hold and move) |
| H5 | Folders: group pinned apps, rename, open, take apps out | todo |
| H6 | Pin app shortcuts (deep shortcuts) to the home screen | done: pin beside each shortcut in the app menu; on a ladera, tap opens, hold to take off |
| H7 | Accept "add to home screen" requests from apps (PinItemRequest: shortcuts and widgets) | done: PinActivity, to the last ladera |
| H8 | Resize widgets (height in rows) | done (widget card: 1–5 rows) |
| H9 | Configurable grid: columns for pins and drawer, labels on/off | todo |
| H10 | Lock the layout so nothing moves by accident | done: camp menu; apps and widgets cannot be carried while locked |
| H11 | Wallpaper: show the system wallpaper behind vivac, or keep the solid camp | todo |
| H12 | Set wallpaper from the camp menu | todo |
| H13 | Laderas: home pages right of the camp, with widgets and apps; new one on demand, empty ones close | done |

## Drawer (Petate)

| # | Feature | Status |
|---|---------|--------|
| D1 | All apps, grouped, alphabetical | done |
| D2 | Search ignoring case and accents; Go opens a single result | done |
| D3 | Hide apps, with a way to see them again | done |
| D4 | Work profile and Private space apps, badged, in their own chip | todo |
| D5 | Recent apps row (from vivac's own launch history, no usage permission) | done ("Último largo") |
| D6 | Fuzzy search: initials ("om" → Organic Maps) and typo tolerance | initials done; typo tolerance todo |
| D7 | Search app shortcuts, not only apps | todo |
| D8 | Search fallbacks: web search, Play/F-Droid store, system settings | done: web (search app or DuckDuckGo) and store (market://); settings search has no public intent |
| D9 | Alphabet fast scroller | done (the altimeter: tap or slide) |
| D10 | Rename an app (custom label) | done: "Cambiar el nombre" in the menu; search finds the new name; blank restores |
| D11 | Calculator and unit conversion in the search field | done: sums, "10% de 150", length/mass/volume/time/speed/data/temperature; tap copies |
| D12 | Search contacts (READ_CONTACTS, opt-in) and open/call/message them | todo |
| D13 | Search calendar events (READ_CALENDAR, opt-in) | todo |

## App menu (long press)

| # | Feature | Status |
|---|---------|--------|
| M1 | App shortcuts | done |
| M2 | Add to / remove from dock, pin, hide | done |
| M3 | App info, uninstall | done |
| M4 | Drag a shortcut to the home screen (via "pin shortcut" entry) | done (pin entry; dragging pinned shortcuts between pages: todo) |
| M5 | The app's widgets, straight from its menu | todo |

## Icons and dots

| # | Feature | Status |
|---|---------|--------|
| I1 | One ink for every icon: vivac's own line glyph per app, monogram for apps without one | done |
| I2 | Choose themed / original colour icons | todo |
| I3 | Icon packs (ADW / Nova standard appfilter.xml) | todo |
| I4 | Custom icon per app (from a pack) | todo |
| I5 | Notification dots | done |
| I6 | Notification count instead of a dot (optional) | todo |

## Gestures

| # | Feature | Status |
|---|---------|--------|
| G1 | Swipe up: Petate; swipe down: notifications | done |
| G2 | Double tap to lock the screen (accessibility service, opt-in) | done: camp menu toggle; LockService reads nothing |
| G3 | Configurable gestures (swipe up/down, double tap → any action or app) | todo |
| G4 | Home pressed on the camp: back to the top / close sheets | done: closes the petate, menus and sheets, back to page 0 |
| G5 | Swipe-home animation into the icon (GestureNavContract, Android 11+, undocumented) | todo |

## Settings and data

| # | Feature | Status |
|---|---------|--------|
| S1 | vivac settings screen (everything configurable above, in one place) | todo |
| S2 | Back up and restore the layout to a file (Storage Access Framework) | todo |
| S3 | Survive uninstalled apps, reboot, process death | done |
| S4 | Set vivac as the default home from inside the app | done: camp menu, RoleManager dialog (default-apps page as fallback) |

## Not possible for a third-party launcher

| Feature | Why |
|---------|-----|
| Recents / overview screen | Only the system launcher (Quickstep) can host it: `config_recentsComponentName` is fixed in the system image. Possible in the vivac-os fork through a system overlay, not in the app. |
| Home-gesture animation into the launcher | Same reason: the animation lives in Quickstep. |
| Google Discover feed | Needs a Google-signed companion app; also against vivac's privacy stance. |

## Tests

| # | Area | Status |
|---|------|--------|
| T1 | Domain rules (pure Kotlin) | done |
| T2 | Coverage measured with Kover, gate in the build | done (Kover, `koverVerifyDebug` fails under 99 % of lines) |
| T3 | Compose UI tests for every screen and sheet (Robolectric) | done |
| T4 | Android adapters tested against Robolectric shadows (apps, icons, widgets, dots, actions) | done |
| T5 | Activity flows end to end: menus, widget bind/configure results, home intent, process death | done |
