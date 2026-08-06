# Data widgets: stocks, weather, YouTube, Mail — design

Date: 2026-08-06
Status: approved, ready for implementation

Spec 2 of 2. Spec 1 (widget visibility + carousel) shipped in `07a21e4`, so these
four land into a main window that already handles crowding and can rotate them.

## Scope

| Widget | Source | Key needed |
|---|---|---|
| Stocks | `query1.finance.yahoo.com/v8/finance/chart/{symbol}` | no |
| Weather | `api.open-meteo.com/v1/forecast` | no |
| YouTube | `youtube.googleapis.com/youtube/v3/channels` | yes, user-supplied |
| Mail | Apple Mail over AppleScript | no, but an Automation grant |

Portfolio tracking is out (deferred in spec 1: every free-tier service needs
self-hosting or a paid plan). Once Stocks ships, holdings priced off its quotes
is the cheaper path — revisit then.

## New files

```
Sources/WebJSON.swift        ~18 lines   fetchJSON(url, headers) -> [String: Any]
Sources/Glyphs.swift         ~60 lines   "#" bitmaps -> [rectEl], run-length merged
Sources/Apps/StocksApp.swift ~170 lines
Sources/Apps/WeatherApp.swift ~150 lines
Sources/Apps/YouTubeApp.swift ~110 lines
Sources/Apps/MailApp.swift   ~120 lines
```

`BusyBarApp.swift` gains four `AppEntry` rows. `project.yml` and
`BusyBar.entitlements` gain the Apple Events entitlement (see Mail).

### Why two shared helpers

`FlightradarApp` and `ISSApp` each carry a private `getJSON`. Three of the four
new widgets need the same thing, so a fourth and fifth copy is where that stops
being reasonable — `WebJSON.swift` holds one. The existing two are left alone;
this is not a refactoring pass.

`Glyphs.swift` exists because Stocks needs 2 bitmaps and Weather needs 7, and
both need the same bitmap→rect conversion. **The conversion must merge horizontal
runs**: a rect costs ~3.6 ms on the device, so an 8×8 icon drawn pixel-by-pixel
would cost ~230 ms, while run-merged it is 8–16 rects. Naive per-pixel rects are
the trap here.

## Stocks

Watchlist of comma-separated symbols, flipping between them. One loop with a tick
counter: each tick shows `symbols[tick % count]`, refetching that symbol only if
its cached quote is older than `refresh`. No second timer, no barrier.

```
AAPL              312.24
▲ 0.40%
```

- Line 1: symbol left, price right. Line 2: arrow + day change percent.
- Change is `(regularMarketPrice - chartPreviousClose) / chartPreviousClose * 100`.
  `meta.previousClose` does not exist on this endpoint; `chartPreviousClose` does.
- **Market open** is `now` inside `meta.currentTradingPeriod.regular.start...end`
  (epoch seconds, so no timezone maths). There is no `marketState` field on this
  endpoint, and the trading window is per-exchange, which is more correct than a
  hardcoded NYSE schedule.
- Arrow colour: green up, red down, **grey whenever the market is closed**,
  regardless of direction.

### Arrow bitmaps

5×5, down as specified, up mirrored top-to-bottom so the shaft still runs from
the far corner and the head stays on the right:

```
  down            up
  #   #           #####
   #  #              ##
    # #             # #
     ##            #  #
  #####           #   #
```

Settings: `stocks.symbols` (default `AAPL`), `stocks.refresh` (60 s),
`stocks.flip` (4 s).

## Weather

One Open-Meteo call gives everything:
`current=temperature_2m,weather_code,is_day,uv_index,precipitation_probability`.

```
[icon]  18°
        UV 0.2   10%
```

- Line 1: 8×8 icon left, temperature right. Line 2: UV index left, rain
  probability right.
- WMO `weather_code` maps to seven icons: clear (sun or moon by `is_day`),
  cloud (1–3), fog (45, 48), drizzle/rain (51–67, 80–82), snow (71–77, 85–86),
  thunderstorm (95–99).
- Own coordinates in `wx.lat` / `wx.lon`, defaulting to the same 52.37 / 4.89 the
  ISS widget uses, with the same "Use my location" button — `ISSApp`'s
  `LocationOnce` helper is reused rather than duplicated.
- Poll every 10 minutes (`wx.interval`). Open-Meteo's `current` block has a
  900 s interval, so polling faster returns identical data.

## YouTube

`channels?part=statistics,snippet` with the user's API key. One field accepts
either form: input starting with `UC` is sent as `id=`, anything else as
`forHandle=` (a leading `@` is added if missing).

```
Channel Name
1.23M subs
```

- Settings: `yt.apiKey`, `yt.channel`, `yt.interval` (5 min).
- `channels.list` costs 1 quota unit against a 10,000/day free allowance, so even
  a 60 s poll is 1,440 units. 5 minutes is the default anyway.
- **`subscriberCount` is rounded to three significant figures by Google** and
  `hiddenSubscriberCount` may be true. The widget shows the rounded figure and
  the settings sheet says so, because otherwise it reads as a bug.

## Mail

`unread count of inbox` over AppleScript — the unified inbox across accounts,
verified to work and to agree with a live read of the Envelope Index.

```
[envelope]  3            or        ZERO INBOX =)
```

At zero it shows `ZERO INBOX =)` (13 chars ≈ 52 px in the 5 px font, so it fits
72 px), rather than either a bare `0` or going dark.

- **Never launch Mail.** A `tell application "Mail"` against a quit Mail starts
  it. The widget checks `NSRunningApplication.runningApplications` first — the
  pattern `MusicApp` already uses — and reports "Mail is not running" instead.
- Entitlement: `com.apple.security.automation.apple-events` (the sanctioned one,
  not a `temporary-exception`), plus `NSAppleEventsUsageDescription` in
  `Info.plist` or the Automation prompt has no text to show.
- `NSAppleScript` is not `Sendable` and must not run on the widget's task
  directly; the query goes through a `MainActor` hop.
- Poll every 30 s (`mail.interval`).

### Two risks worth stating

1. The Automation TCC prompt is unreliable on this macOS beta — the same reason
   `MusicApp` is notification-driven. If it never appears, this widget cannot
   work and the honest outcome is to drop it, as originally offered.
2. Editing entitlements produces a new binary, which re-triggers the Local
   Network trap. The recovery is now in `docs/troubleshooting.md`: install to a
   fresh path, grant, move it back. No rebuild, no Recovery boot.

## Error handling

Every widget follows the established contract: report one line through `status`,
keep looping, and leave the bar alone on a transient failure rather than
blanking it. HTTP 409 is not fatal (something outranks us). A missing API key or
symbol list reports what to fill in and sleeps instead of spinning.

## Verification

- `Glyphs.swift` run-length merging is pure and gets an assert self-check next to
  `Carousel.selfCheck()`: a known bitmap must produce the expected rect list, and
  the up arrow must be the down arrow's row-reverse.
- Quote maths is pure and asserted: a known price/close pair gives a known
  percentage, and market-open is tested at a timestamp inside and outside the
  regular window.
- Manual acceptance per widget on the device, plus the Mail widget with Mail
  quit, to confirm it reports rather than launching it.
