# Widget visibility + Carousel — design

Date: 2026-08-06
Status: approved, ready for implementation planning

Spec 1 of 2. Spec 2 covers the new data widgets (stock ticker, weather, YouTube
subscriber count, Apple Mail unread) and is written after this one ships, so each
widget lands into a main window that already handles crowding.

## Problem

The main window lists every widget in `registry` unconditionally. At 11 widgets
it is already long, and spec 2 adds four more. Two features fix this:

1. **Visibility** — choose which widgets appear in the main window's list.
2. **Carousel** — rotate the bar through a chosen set of widgets every X seconds.

They are separate features with separate windows and separate selections.

## Non-goals

- No portfolio tracker (deferred; every free-tier service needs self-hosting or a
  paid plan, and local holdings priced off the stock widget's quotes is the
  better trade — revisit after the ticker ships).
- No per-widget dwell time. One global interval.
- No reordering of the widget list. Registry order stands.
- No changes to `BarClient`, the `MiniApp` protocol, or any existing widget.

## Architecture

Two new files, one purpose each:

```
Sources/WidgetVisibility.swift    ~50 lines
  visibleRegistry() -> [AppEntry]     registry minus UserDefaults "widgets.hidden"
  WidgetsView                         checkbox per registry entry

Sources/Carousel.swift            ~110 lines
  Carousel: ObservableObject          rotation task; members, interval, enabled
  CarouselView                        on/off + interval field + checkbox per entry
```

Both windows list **every** entry in `registry`, hidden ones included — the two
selections are independent.

Changes to existing files:

- `BusyBarApp.swift` — two `Window` scenes (`id: "widgets"`, `id: "carousel"`),
  two menu items under the Window menu, `ForEach(registry)` becomes
  `ForEach(visibleRegistry())`, plus one carousel row above the list: an on/off
  switch and the current member's name, so the rotation can be started and read
  without opening its window.
- No change to `MiniApp.swift`. See "Manual toggle" below for why.

### Persisted state (UserDefaults)

| Key | Type | Default |
|---|---|---|
| `widgets.hidden` | `[String]` of widget ids | `[]` (all visible) |
| `carousel.members` | `[String]` of widget ids | `[]` |
| `carousel.interval` | `Double`, seconds | `30` |
| `carousel.enabled` | `Bool` | `false` |

Storing *hidden* rather than *shown* means widgets added in spec 2 appear by
default instead of being silently invisible after an upgrade.

## Carousel behaviour

```swift
@MainActor final class Carousel: ObservableObject {
    @Published var current: String?   // widget id on the bar right now
    func toggle()
    func start()
    func stop()                       // cancels the rotation task only
}
```

Rotation step, looping until cancelled:

1. Resolve members to `[AppEntry]` in registry order, dropping ids no longer in
   the registry.
2. `runner.stop(previous)` when the previous member differs from the next.
3. `runner.start(next)`, set `current`.
4. `await barSleep(max(5, interval))`; a false return means cancelled — exit.

Explicitly stopping the previous member is what makes monitors rotate. `Status`,
`Timer`, `Pomodoro` and `On Call` are `exclusive: false` precisely so they
coexist with the active widget, so `Runner.start` alone would never evict them
and they would pile up on the bar.

- **Interval floor.** `max(5, interval)`, default 30 s. Below ~5 s several
  widgets never finish their first fetch (Flightradar polls every 15 s, Claude
  Limits reads files, Music only learns state on the next play/pause), so the
  bar would show blanks.
- **Empty member set.** `start()` refuses and the status line says to pick
  widgets in the Carousel window.
- **`stop()` leaves the current widget running.** Switching the carousel off
  keeps whatever you are looking at on the bar.
- **A member that exits on its own** (network failure, `ISS` clearing itself)
  needs no handling — `Runner` drops it from `running` and the next step moves
  on regardless.
- **Restore on launch** next to `runner.restore()`, when `carousel.enabled`.

### Manual toggle stops the carousel

`AppRow` calls `carousel.stop()` before `runner.toggle(entry)`. The view already
holds both objects, so `Runner` learns nothing about the carousel and
`MiniApp.swift` is untouched. Manual intent wins and the bar stays where you put
it.

## Resolved design questions

- **Hiding a running widget stops it.** Otherwise it keeps drawing to the bar
  with no row left to switch it off.
- **Carousel membership is independent of visibility.** A hidden widget can
  still be cycled. The main window's carousel row names the current member, so
  what the bar is doing is never invisible.

## Error handling

Nothing here touches the network, so there is no new failure mode. The two
windows read and write `UserDefaults` only. The carousel's own failure modes are
the two guarded above (empty membership, too-short interval); a member that
fails to draw reports through its existing `status` callback exactly as it does
when started by hand.

## Verification

The repo has no test target and "system frameworks only, no packages" is a hard
rule, so standing one up for a UI rotation loop is disproportionate.

- Wrap-around order lives in a pure `static func rotation(members:) -> [AppEntry]`
  with one `#if DEBUG` assert-based self-check run at launch.
- Manual acceptance: three members, 5 s interval, carousel on — confirm the
  rotation wraps, that `MirrorView` follows it, that a monitor member is stopped
  when its turn ends, and that toggling a widget by hand switches the carousel
  off.
- Hide a running widget and confirm it stops; relaunch and confirm hidden set,
  members, interval and enabled state all survive.
