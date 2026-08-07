# Busy Control Centre — working notes

SwiftUI macOS app driving a BUSY Bar over its local HTTP API. Stdlib and system
frameworks only; no packages, no third-party dependencies. Keep it that way.

## Layout

```
project.yml                  xcodegen spec — the source of truth for the target,
                             Info.plist keys and entitlements. The .xcodeproj is
                             generated and gitignored.
Sources/
  BusyBarApp.swift           @main, the widget `registry`, main window UI
  MiniApp.swift              MiniApp protocol, AppEntry, Runner (start/stop/persist)
  BarClient.swift            device HTTP client, element builders, Frame → PNG
  WidgetVisibility.swift     which widgets the main list shows + Widgets window
  Carousel.swift             timed rotation through chosen widgets + its window
  WebJSON.swift              fetchJSON for the widgets that read the open web
  Glyphs.swift               "#" bitmaps → rect elements (weather icons, YT mark)
  DeviceFont.swift           measured character advances for the device's fonts
  SwitchWatcher.swift        the bar's switch position, over its state WebSocket
  Roll.swift                 odometer animation for numbers that change on screen
  Banners.swift              device themes + BannerPicker
  MirrorView.swift           LED-matrix mirror of /api/screen
  LocalNetworkPermission.swift  Bonjour trigger for the TCC prompt
  AboutView.swift            attributions window
  Apps/*.swift               one file per widget
Resources/Themes/            banner artwork (CC-BY-SA-4.0, see ATTRIBUTION.md)
Scripts/fetch-themes.sh      refreshes that artwork from the firmware repo
```

## Build / ship

```sh
xcodegen generate
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
  xcodebuild -project BusyBar.xcodeproj -scheme BusyBar -configuration Release build
```

Release pipeline: sign (Developer ID, hardened runtime, `--timestamp`) →
`notarytool submit --wait` → `stapler staple` → zip. Credentials live in the
keychain profile `busybar-notary`.

## Device API facts worth remembering

- **Priority.** `draw` takes 1–100; a request wins if its priority ≥ the running
  app's. Built-in apps sit at 10, an active focus session at 90. A widget getting
  HTTP 409 means something outranks it — keep ticking, don't treat it as fatal.
- **Elements persist by id** until overwritten or the app clears itself. To make
  a badge disappear you must redraw it with empty text; simply omitting it leaves
  the old one on screen.
- **`/api/screen`** claims `image/bmp` and actually returns base64-encoded
  **BGR888**, no header. 3456 bytes = front 72×16, 38400 = back 160×80.
- **Asset uploads lock briefly**; re-uploading the same filename too fast returns
  HTTP 508, so the image widgets rotate through `frame0..3.png`.
- **One request at a time.** The bar drops requests that overlap, so all traffic
  goes through `BarClient.session` with `httpMaximumConnectionsPerHost = 1`.
- **Full-frame images beat many rects**: ~3.6 ms per rect vs a flat ~50 ms for one
  72×16 image, so animated widgets render into `Frame` and push a single PNG.
  `Glyph` exists for the middle ground — a small bitmap drawn as rects — and it
  merges horizontal runs, because an 8×8 icon as 64 single-pixel rects is ~230 ms.
  It also emits a fixed number of element ids per glyph: elements persist by id,
  so a 10-rect icon followed by a 6-rect one would leave four rects behind.
- **Auth**: HTTP access key as `X-API-Token`, enforced over Wi-Fi only.
- **The switch cannot be inferred from priority.** Apps and Settings are *scenes
  of the bar's own busy app*, which sits at PASSTHROUGH (9) the whole time it is
  not running a session — so the canvas accepts a widget's draw at Apps exactly
  as it does at Off. The position is only published as an *event*, on
  `/api/status/ws`, as protobuf `StateUpdate.input(11).switch_event(2).position(1)`
  (BUSY 0, CUSTOM 1, OFF 2, APPS 3, SETTINGS 4). `SwitchWatcher` reads it with a
  ~40-line wire-format walker; the schema is public at busy-app/busybar-protobuf.
  It is *not* in the state snapshot, so the position is unknown until the switch
  is first moved.
- **Draw priority**, for what it is still worth: the canvas rejects a draw at
  `priority <= current` from another app, but `priority < current` once you own
  the screen — so a value that loses to an app at 10 has to be below 10, and
  widgets sit at 9. A session raises the busy app to BLOCKING (101), which is the
  409 every widget already handles.
- **Banners need no session.** Every theme is a stock animation the device
  already has: each `theme.json` points `bg_path` at
  `shared/animations/<theme>_72x16.anim`, and a draw with
  `{"type": "animation", "stock_path": "shared/on_call_72x16.anim"}` plays it. The
  focus-session route (`/api/busy/snapshot`) also starts the bar's busy timer and
  flips the device into its busy state, which is not what showing a banner should
  do. There is no "busy" theme on the device, despite it being this app's default
  for years.
- **Never let `JSONSerialization` escape slashes.** It writes "/" as `\/`, which
  is valid JSON that the bar rejects with **HTTP 400** — so a widget reading
  "485km/h" or "NE 1m/s" had every frame thrown away and sat there black, while
  the identical text posted by curl or python drew fine. `BarClient.bodyOptions`
  carries `.withoutEscapingSlashes`; every request body must use it.
- **A rejected draw is a black bar**, because `Runner.start` clears first. One bad
  character in one element throws away the whole frame, and if the widget also
  animates, the animation's draws keep landing — which looks like a bar showing
  nothing but rolling digits. That symptom means "the frame is being rejected",
  not "the animation is broken".
- **Some characters are refused outright**: "↑↗→" gives HTTP 400, "°" and Cyrillic
  do not. `deviceSafe` in `BarClient` swaps the known-bad ones on the way out.
  It is a deny-list on purpose — channel names and track titles are not ASCII,
  and filtering to ASCII cost the YouTube widget its (Cyrillic) channel name.
- **100 elements per request, ~104 ids per app**; beyond that, HTTP 400. Measured.
- **The fonts carry more than ASCII**: all eight arrows (↑↗→↘↓↙←↖) and °, all
  measured. Nothing in the app draws a character as a bitmap — `Glyph` is for
  pictures only (weather icons, the YouTube mark).
- **Elements outlive the app.** Quitting kills the widget tasks without a clear,
  so the bar keeps whatever was last drawn — including elements an animation was
  mid-way through, which the widget's ordinary frame has no id for and can never
  overwrite. `Runner.start` therefore clears the app's namespace before anything
  else. Nothing is replayed over the top: a widget's first frame comes from
  `WebCache`, which holds the *data* it fetched a moment ago rather than a
  picture of it.
- **The device fonts are proportional.** In `small` a digit advances 4px but "."
  advances 2, "I" 2 and "M" 6, so `count * 4` is wrong for anything but digits —
  it is what put the flight route's ">" on top of its origin. `DeviceFont` holds
  the advances, measured from the firmware's own TTFs
  (`assets/shared/fonts/ttf`) at the ppem `convert_all.sh` bakes them at: 16px
  for all of them, except `extra_large`, which is `busy_regular_7px` at **32px**
  — the 7px face doubled, hence its 2px-thick strokes and 14 rows of height.
  Metrics only: the firmware is GPLv2 and this app is MIT, so no glyph data from
  it can ship here. Re-measure with CoreText at those ppem values if the firmware
  changes its fonts.
- **Element coordinates may be negative** (the schema allows -4096…4095), which
  is what makes `Roll` possible: a character can be told to sit half a line above
  where it belongs and the display clips it. Nothing else clips, so the parts
  that land in the 3-row gutter between the two text lines are covered with black
  rects — and that gutter is why the throw is 3px and no more.
- **Element ids are a budget.** `Roll` animates at most 4 characters (3 ids
  each) and the weather icon's two layers are budgeted at exactly what their
  busiest member needs (16 + 10), not a round number.
- **Roll animates the device's own font**: it covers each changed character with
  a black rect and redraws that one character as its own text element, which can
  then be given a negative `y`. The number's own element is left alone. Its first
  frame creates every element it will touch — cover, characters, masks, in that
  order — because the bar paints elements in the order it first saw them. Text is
  erased with `""`, rects by going `#00000000`. A reading whose characters change
  width (a "1" is 3px, every other digit 4) re-lays out, so it is redrawn rather
  than rolled.

## Debugging what the bar is doing

`barLog` (`os.Logger`, subsystem `ru.shbbl.BusyBar`) records every widget status
line and every draw that does not return 200 or 409. This is the only way to see
what an installed app is doing, since the bar cannot be reached from a sandboxed
shell:

```sh
log show --last 5m --info --debug --predicate 'subsystem == "ru.shbbl.BusyBar"'
```

`draw weather 30 elements -> HTTP 400` is what found the slash-escaping bug after
four wrong theories. When a widget misbehaves, read the log before theorising.

## Conventions

- A widget is a `MiniApp`: loop until `Task.isCancelled`, release the display on
  the way out, report one-line human status through the `status` callback.
- Read config from `UserDefaults` at the start of `run`, not continuously.
- `exclusive: false` in `AppEntry` marks a monitor that coexists with the active
  widget (On Call, Timer, Pomodoro); everything else is one-at-a-time.
- Cleanup after cancellation must run detached — URLSession refuses to send from
  a cancelled task, so a `clear()` in the normal path never reaches the device.
- The carousel stops the outgoing member itself rather than relying on
  `Runner.start`'s eviction, because `exclusive: false` monitors are built to
  coexist and would otherwise pile up. `Runner` knows nothing about the carousel:
  `AppRow` calls `carousel.stop()` before `runner.toggle`, so manual intent wins.

## Gotchas that cost time

- **Local Network permission binds to the executable's UUID**, so every rebuild
  is a new identity. Overwriting an installed app silently voids its grant and
  `tccutil reset LocalNetwork` does not work (the state lives in the
  networkextension store, not the TCC db). Do not try to pin the UUID to dodge
  this — that is defeating the consent mechanism, not fixing a bug. The recovery
  is to install to a fresh *path* in /Applications, grant the prompt, then move
  the bundle over the real name; the grant survives the move and no rebuild is
  needed. Full recipe and how to read the denial out of the log:
  docs/troubleshooting.md.
- On macOS 26/27 betas the prompt may never appear for any app; the known fix is
  deleting `/Library/Preferences/com.apple.networkextension.*.plist` from
  Recovery. See docs/troubleshooting.md.
- **NSPopover crashes** on the macOS 27 beta from deep inside AppKit ViewBridge;
  settings are presented as sheets for that reason.
- The Music widget is notification-driven (`com.apple.Music.playerInfo`), which
  needs no Automation permission — deliberately, because that prompt is also
  unreliable on the beta. It only learns state on the first play/pause after
  launch; there is no way to poll it without AppleScript.
- Theme ids come from the firmware's `applications/main/busy/resources/apps_assets/busy/themes/`
  folder names — note it is `dnd`, not `do_not_disturb`.
- Banner artwork is CC-BY-SA-4.0 (Flipper FZCO), not MIT like the rest. Keep the
  attribution in `Resources/Themes/ATTRIBUTION.md`, the README and the About
  window in step if it changes.
- Clock, Nyan Cat, ISS Alert, Music and Flightradar are ports of @maxswinkels'
  apps from the BUSY Bar Apps gallery, and Claude Limits of @rbhbokka's — all
  MIT, whose notices must travel with the code. `THIRD-PARTY.md` carries them in
  full; the README table and the About window mirror it. Port another gallery app
  and it needs a row in all three.
