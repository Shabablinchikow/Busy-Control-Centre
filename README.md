# Busy Control Centre

A native macOS app for the [BUSY Bar](https://busy.app) — a launcher for small
widgets that draw on the bar's 72×16 LED panel, plus focus sessions and a live
mirror of the display.

Everything talks to the device's local HTTP API. No cloud, no accounts, no
third-party dependencies — SwiftUI and the system frameworks only.

## Widgets

| | |
|---|---|
| **Clock** | Big time, refreshed every second |
| **Nyan Cat** | Pop-tart cat, rainbow trail, twinkling stars |
| **ISS Alert** | Quiet until the space station passes near you |
| **Music** | Spectrum bars following the Music app, with track title |
| **Flightradar** | Tracks one flight by number: route, altitude, speed |
| **Claude Limits** | Live Claude Code usage bars with the Clawd mascot |
| **pISS Stream** | ISS urine-tank level from NASA telemetry, à la [pISSStream](https://github.com/Jaennaet/pISSStream) |
| **Timer** | Countdown run by the bar, with your choice of banner |
| **Pomodoro** | Work/rest cycles run by the bar |
| **On Call** | Mic in use → the bar shows an ON CALL banner |

Widgets draw via `/api/display/draw`. Timer, Pomodoro and On Call instead drive
the device's built-in focus session (`/api/busy/snapshot`), which renders the
bar's own themed animations at session priority.

**Priority.** Sessions outrank widgets, and the mic outranks everything: when
On Call takes the screen it captures any running timer and restores that exact
snapshot afterwards, so the countdown resumes rather than restarting.

## Display mirror

The main window can mirror what the bar is showing, drawn as an LED matrix —
one dot per device pixel, with bloom on lit dots.

`/api/screen` is worth a note for anyone else building against it: it advertises
`Content-Type: image/bmp`, but the body is **base64-encoded BGR888 with no
header**. Payload length identifies the panel — 3456 bytes for the front
(72×16), 38400 for the back (160×80).

## Building

Requires macOS 14+, Xcode 15+, and [xcodegen](https://github.com/yonaskolb/XcodeGen).

```sh
brew install xcodegen
xcodegen generate
open BusyBar.xcodeproj
```

The Xcode project is generated from `project.yml` and is not committed. Set
`DEVELOPMENT_TEAM` in `project.yml` to your own team ID before signing.

Releases are built by CI on tag push (`v*`); see `.github/workflows/release.yml`.
Signing and notarisation are optional and enabled by setting the repository
secrets documented in that workflow — without them CI still produces an
unsigned build for testing.

## Banner artwork

The banner picker shows the device's theme cards. That artwork belongs to BUSY
and is **not** included in this repository. Without it the picker falls back to
plain text labels, which work fine.

To use the real cards locally, drop PNGs into `BusyBar/Resources/Themes/` named
after the theme id: `busy.png`, `on_call.png`, `meeting.png`, `do_not_disturb.png`,
`keep_out.png`, `on_air.png`, `flow.png`, `coding.png`, `booked.png`,
`back_soon.png`, `lunch.png`, `chill_time.png`, `low_social_battery.png`.

## Connecting

Over USB the bar is always at `10.0.4.20` and needs no key. Over Wi-Fi, enter
its IP and the HTTP access key from Settings → HTTP Access on the device; the
app sends it as `X-API-Token`.

macOS will ask for Local Network permission on first launch. If the prompt never
appears and the app cannot reach the bar, see [docs/troubleshooting.md](docs/troubleshooting.md).

## License

MIT — see [LICENSE](LICENSE). Not affiliated with or endorsed by BUSY.
