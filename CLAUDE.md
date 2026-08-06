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
  Glyphs.swift               "#" bitmaps → rect elements (arrows, weather icons)
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
