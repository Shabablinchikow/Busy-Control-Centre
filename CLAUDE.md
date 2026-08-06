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
  Banners.swift              device themes + BannerPicker
  MirrorView.swift           LED-matrix mirror of /api/screen
  LocalNetworkPermission.swift  Bonjour trigger for the TCC prompt
  Apps/*.swift               one file per widget
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
- **Auth**: HTTP access key as `X-API-Token`, enforced over Wi-Fi only.

## Conventions

- A widget is a `MiniApp`: loop until `Task.isCancelled`, release the display on
  the way out, report one-line human status through the `status` callback.
- Read config from `UserDefaults` at the start of `run`, not continuously.
- `exclusive: false` in `AppEntry` marks a monitor that coexists with the active
  widget (On Call, Timer, Pomodoro); everything else is one-at-a-time.
- Cleanup after cancellation must run detached — URLSession refuses to send from
  a cancelled task, so a `clear()` in the normal path never reaches the device.

## Gotchas that cost time

- **Local Network permission binds to the executable's UUID**, so every rebuild
  is a new identity. Overwriting an installed app silently voids its grant and
  `tccutil reset LocalNetwork` does not work (the state lives in the
  networkextension store, not the TCC db). Installing under a fresh name gets a
  new prompt. Do not try to pin the UUID to dodge this — that is defeating the
  consent mechanism, not fixing a bug.
- On macOS 26/27 betas the prompt may never appear for any app; the known fix is
  deleting `/Library/Preferences/com.apple.networkextension.*.plist` from
  Recovery. See docs/troubleshooting.md.
- **NSPopover crashes** on the macOS 27 beta from deep inside AppKit ViewBridge;
  settings are presented as sheets for that reason.
- The Music widget is notification-driven (`com.apple.Music.playerInfo`), which
  needs no Automation permission — deliberately, because that prompt is also
  unreliable on the beta. It only learns state on the first play/pause after
  launch; there is no way to poll it without AppleScript.
- Theme card artwork is BUSY's and is gitignored; the picker degrades to labels.
