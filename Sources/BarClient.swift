import Foundation
import CoreGraphics
import os
import ImageIO
import UniformTypeIdentifiers

/// Everything the app tells the device, and what it said back. Read it with
///   log show --last 5m --predicate 'subsystem == "ru.shbbl.BusyBar"'
/// which is the only way to see what a widget is doing once the app is installed
/// — the bar itself cannot be reached from a sandboxed shell.
let barLog = Logger(subsystem: "ru.shbbl.BusyBar", category: "bar")

/// Thin client for the BUSY Bar HTTP API. Over USB the bar is always at
/// 10.0.4.20; a host override targets a Wi-Fi bar or the emulator.
/// Full API docs are served by the device: http://10.0.4.20/docs
struct BarClient {
    /// The bar handles very few sockets at once: widget draws and mirror frames
    /// racing each other make requests fail outright. One connection per host,
    /// so URLSession queues them instead.
    static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.httpMaximumConnectionsPerHost = 1
        c.timeoutIntervalForRequest = 8
        c.waitsForConnectivity = false
        return URLSession(configuration: c)
    }()

    /// **`withoutEscapingSlashes` is load-bearing.** `JSONSerialization` writes a
    /// forward slash as `\/`, which is valid JSON that the bar's parser rejects
    /// with HTTP 400 — so a widget showing "485km/h" or "NE 1m/s" had *every*
    /// frame thrown away and sat there black, while the same text posted by
    /// anything that does not escape slashes (curl, python) drew fine.
    static let bodyOptions: JSONSerialization.WritingOptions = [.withoutEscapingSlashes]

    /// What widgets draw at. It matches the firmware's PASSTHROUGH priority
    /// exactly, and that is the whole trick.
    ///
    /// The bar's idle scene sets itself to PASSTHROUGH (9) — literally
    /// `busy_set_priority(instance, false)` — while every app the switch starts
    /// runs at DEFAULT (10) and a session at BLOCKING (101). The canvas then
    /// rejects a draw when `priority < current` if we already own the screen, and
    /// when `priority <= current` if somebody else does. At 9 that means:
    ///
    /// - switch at Off: 9 is not < 9, so widgets draw;
    /// - switch at Apps, Settings, Busy: 9 < 10, so they stop — even mid-widget,
    ///   which 10 did not, because holding the canvas made the test strict.
    ///
    /// The device does the gating; nothing has to watch the switch. A widget at
    /// 60 was simply shouting over the bar's own screens.
    ///
    /// On Call is the exception, and draws at its own higher priority.
    static let widgetPriority = 9

    let base: URL
    /// HTTP access key (4–10 digit PIN, Settings → HTTP Access on the bar).
    /// Enforced only over Wi-Fi on current firmware; sent as X-API-Token.
    let token: String?

    init(host: String, token: String? = nil) {
        var h = host.replacingOccurrences(of: "http://", with: "")
        h = h.replacingOccurrences(of: "https://", with: "")
        while h.hasSuffix("/") { h.removeLast() }
        base = URL(string: "http://\(h)")!
        self.token = (token?.isEmpty == false) ? token : nil
    }

    private func request(_ url: URL, method: String) -> URLRequest {
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.timeoutInterval = 8
        if let token { req.setValue(token, forHTTPHeaderField: "X-API-Token") }
        return req
    }

    /// POST /api/display/draw. Returns the HTTP status code — the device answers
    /// 409 when a higher-priority app owns the display; callers keep ticking.
    @discardableResult
    func draw(app: String, elements: [[String: Any]], priority: Int? = widgetPriority,
              ledNotificationColor: String? = nil) async throws -> Int {
        // The bar has a screen of its own up: do not draw over it. Reported as
        // 409, which every widget already treats as "not now, keep polling".
        if await BarState.shared.paused(app) { return 409 }

        var body: [String: Any] = ["application_name": app, "elements": elements]
        if let priority { body["priority"] = priority }
        if let ledNotificationColor { body["led_notification_color"] = ledNotificationColor }
        var req = request(base.appendingPathComponent("api/display/draw"), method: "POST")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body, options: Self.bodyOptions)
        let (_, resp) = try await Self.session.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        // 409 is routine (something outranks us); anything else that is not 200
        // means the frame did not land, which on a cleared display is a black bar.
        if code != 200 && code != 409 {
            barLog.error("draw \(app, privacy: .public) \(elements.count) elements -> HTTP \(code)")
        } else {
            barLog.debug("draw \(app, privacy: .public) \(elements.count) elements -> \(code)")
        }
        await BarState.shared.note(draw: code)
        if code == 409 {
            // Refused, so a session is running. Stopping is not enough: whatever
            // we drew last would sit on top of it until something removes it.
            await clear(app: app)
        }
        return code
    }

    /// DELETE /api/display/draw?application_name=… — release the screen. Best effort.
    func clear(app: String) async {
        var comps = URLComponents(url: base.appendingPathComponent("api/display/draw"),
                                  resolvingAgainstBaseURL: false)!
        comps.queryItems = [URLQueryItem(name: "application_name", value: app)]
        let req = request(comps.url!, method: "DELETE")
        _ = try? await Self.session.data(for: req)
    }

    /// GET /api/screen?display=… — one BMP frame. Front = 0 (72x16), back = 1 (160x80).
    func screen(display: Int) async throws -> Data {
        var comps = URLComponents(url: base.appendingPathComponent("api/screen"),
                                  resolvingAgainstBaseURL: false)!
        comps.queryItems = [URLQueryItem(name: "display", value: String(display))]
        var req = request(comps.url!, method: "GET")
        req.timeoutInterval = 4
        let (data, _) = try await Self.session.data(for: req)
        return data
    }

    /// GET /api/busy/snapshot — the built-in focus session's current state.
    func busySnapshot() async throws -> [String: Any] {
        let req = request(base.appendingPathComponent("api/busy/snapshot"), method: "GET")
        let (data, _) = try await Self.session.data(for: req)
        return try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
    }

    /// PUT /api/busy/snapshot with a snapshot captured earlier, verbatim. Keeping
    /// the original snapshot_timestamp_ms lets the device work out how much time
    /// elapsed while it was interrupted, so a restored timer resumes correctly.
    @discardableResult
    func restoreBusySnapshot(_ body: [String: Any]) async throws -> Int {
        var req = request(base.appendingPathComponent("api/busy/snapshot"), method: "PUT")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body, options: Self.bodyOptions)
        let (_, resp) = try await Self.session.data(for: req)
        return (resp as? HTTPURLResponse)?.statusCode ?? 0
    }

    /// GET /api/busy/profiles/{slot} — "busy" or "custom".
    func busyProfile(slot: String) async -> [String: Any]? {
        let req = request(base.appendingPathComponent("api/busy/profiles/\(slot)"), method: "GET")
        guard let (data, _) = try? await Self.session.data(for: req),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              obj["id"] != nil else { return nil }
        return obj
    }

    /// PUT /api/busy/snapshot. A running session owns the screen at priority 90,
    /// above every widget, and renders the device's own themed animation.
    ///
    /// The card_id must point at a profile whose timer settings match the
    /// snapshot: clients (the phone app) render the session through that
    /// profile, so an INFINITE session on an INTERVAL profile shows up as
    /// "timer is up". The "custom" slot ships as INFINITE, so untimed sessions
    /// go there.
    @discardableResult
    func setBusySession(theme: String, running: Bool, triggerSmartHome: Bool) async throws -> Int {
        var snapshot: [String: Any] = [
            "busy_bar_settings": ["theme": theme,
                                  "show_work_phase_only": false,
                                  "trigger_smart_home": triggerSmartHome],
        ]
        if running {
            let profile = await busyProfile(slot: "custom")
            let infinite = (profile?["timer_settings"] as? [String: Any])?["type"] as? String == "INFINITE"
            snapshot["type"] = "INFINITE"
            snapshot["card_id"] = (infinite ? profile?["id"] as? String : nil)
                ?? "00000000-0000-0000-0000-000000000002"
            snapshot["is_paused"] = false
        } else {
            snapshot["type"] = "NOT_STARTED"
        }
        let body: [String: Any] = [
            "snapshot": snapshot,
            "snapshot_timestamp_ms": Int(Date().timeIntervalSince1970 * 1000),
        ]
        var req = request(base.appendingPathComponent("api/busy/snapshot"), method: "PUT")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body, options: Self.bodyOptions)
        let (_, resp) = try await Self.session.data(for: req)
        return (resp as? HTTPURLResponse)?.statusCode ?? 0
    }

    /// POST /api/smart_home/switch — the emulated switch the bar exposes to Matter.
    /// Called directly now that the banners no longer ride on a focus session,
    /// which used to carry `trigger_smart_home` for us.
    @discardableResult
    func setSmartHomeSwitch(on: Bool) async -> Int {
        var req = request(base.appendingPathComponent("api/smart_home/switch"), method: "POST")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["state": on],
                                                   options: Self.bodyOptions)
        let (_, resp) = (try? await Self.session.data(for: req)) ?? (Data(), URLResponse())
        return (resp as? HTTPURLResponse)?.statusCode ?? 0
    }

    /// POST /api/assets/upload?application_name=…&file=… with raw bytes.
    /// Returns the HTTP status code (508 = asset briefly locked by a draw).
    @discardableResult
    func uploadAsset(app: String, file: String, data: Data) async throws -> Int {
        var comps = URLComponents(url: base.appendingPathComponent("api/assets/upload"),
                                  resolvingAgainstBaseURL: false)!
        comps.queryItems = [URLQueryItem(name: "application_name", value: app),
                            URLQueryItem(name: "file", value: file)]
        var req = request(comps.url!, method: "POST")
        req.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        req.httpBody = data
        let (_, resp) = try await Self.session.data(for: req)
        return (resp as? HTTPURLResponse)?.statusCode ?? 0
    }
}

/// Whether the bar is showing a screen of its own, and so whether widgets should
/// keep off the display.
///
/// Two sources, because neither is enough alone:
///
/// - **The switch**, streamed from the device (see `SwitchWatcher`). Anywhere but
///   Off means the bar has its own screen up. Priority cannot substitute for
///   this: Apps and Settings are scenes of the bar's own busy app, which stays at
///   PASSTHROUGH throughout, so the canvas accepts a widget's draw at Apps
///   exactly as it does at Off.
/// - **A 409 from the canvas**, which is what a running session looks like.
///
/// The position is unknown until the switch is first moved — the device publishes
/// it as an event and leaves it out of the state snapshot — so a widget started
/// while the switch is already at Apps draws once, until the switch next moves.
@MainActor
final class BarState: ObservableObject {
    static let shared = BarState()

    /// Widgets that may draw over the bar's own screens. A call is happening
    /// whether or not somebody left the switch on Settings.
    static let mayOverride: Set<String> = ["on-call"]

    @Published private(set) var position = SwitchPosition.off
    /// The canvas refused the last draw — a session is running.
    @Published private(set) var refused = false

    /// The bar is showing something of its own.
    var busy: Bool { !position.isOff || refused }

    /// Whether this widget should stay off the display right now.
    ///
    /// The switch alone decides this — deliberately. Gating on `refused` as well
    /// deadlocked: a paused draw never reaches the device, so once a session had
    /// set `refused` there was no 200 left to clear it and every widget stayed
    /// paused for good, with the switch at Off and the bar blank. A session needs
    /// no help from us anyway; the canvas refuses those draws itself.
    func paused(_ app: String) -> Bool {
        !position.isOff && !Self.mayOverride.contains(app)
    }

    func note(draw code: Int) {
        switch code {
        case 200: refused = false
        case 409: refused = true
        default: break  // a rejected frame says nothing about who owns the screen
        }
    }

    /// A new connection means our idea of the switch may be stale — positions
    /// arrive as events, so a flick that happened while the socket was down is
    /// simply lost, and a widget would stay paused for ever waiting for an "Off"
    /// that already came and went. Assume Off and let the next flick correct it:
    /// a bar stuck showing nothing is worse than one that draws a frame it should
    /// not have.
    func noteReconnected() {
        if !position.isOff { barLog.info("switch stream reconnected; assuming Off") }
        position = .off
    }

    func note(switch new: SwitchPosition) {
        guard new != position else { return }
        let wasOff = position.isOff
        position = new
        // Leaving Off: take everything of ours off the display. Elements persist
        // until something removes them, so simply going quiet would leave the last
        // frame sitting on top of the bar's own screen.
        if wasOff, !new.isOff { Task { await Self.clearAll() } }
    }

    private static func clearAll() async {
        let host = UserDefaults.standard.string(forKey: "host") ?? "10.0.4.20"
        let client = BarClient(host: host,
                               token: UserDefaults.standard.string(forKey: "accessKey"))
        for entry in registry where !mayOverride.contains(entry.id) {
            await client.clear(app: entry.id)
        }
    }
}

// MARK: - Element builders (same JSON shapes the python scripts sent)

func textEl(_ id: String, _ text: String, x: Int, y: Int, font: String = "normal",
            color: String = "#FFFFFFFF", align: String? = nil) -> [String: Any] {
    var el: [String: Any] = ["id": id, "type": "text", "text": deviceSafe(text),
                             "x": x, "y": y, "font": font, "color": color]
    if let align { el["align"] = align }
    return el
}

/// Swaps out the handful of characters the bar refuses. One of them makes the
/// *whole draw* fail with HTTP 400, which blanks an entire widget — measured:
/// posting "↑↗→" is rejected, "°" is not.
///
/// Deliberately a small deny-list rather than an ASCII filter: channel names,
/// track titles and place names are not ASCII, and the device draws Cyrillic
/// perfectly well. Stripping everything non-ASCII cost the YouTube widget its
/// channel name.
func deviceSafe(_ s: String) -> String {
    guard s.contains(where: { deviceFallback[$0] != nil }) else { return s }
    return String(s.map { deviceFallback[$0] ?? String($0) }.joined())
}

/// Readable stand-ins for the characters the bar will not take. Arrows are the
/// ones this app kept reaching for; the rest are the typographic characters that
/// arrive in text copied from elsewhere.
private let deviceFallback: [Character: String] = [
    "↑": "+", "↓": "-", "→": ">", "←": "<", "↗": ">", "↘": ">", "↖": "<", "↙": "<",
    "…": "..", "—": "-", "–": "-", "•": ".", "·": ".", "×": "x", "−": "-",
    "“": "\"", "”": "\"", "‘": "'", "’": "'", "≈": "~",
]

func rectEl(_ id: String, x: Int, y: Int, w: Int, h: Int, color: String) -> [String: Any] {
    ["id": id, "type": "rectangle", "x": x, "y": y, "width": w, "height": h,
     "border_width": 0, "fill": "solid", "fill_colors": [color]]
}

/// Plays one of the device's own animations — the banner themes live at
/// `shared/<theme>_72x16.anim`, which is the very path each theme.json points
/// its `bg_path` at. Drawing one shows the real banner without starting a focus
/// session, so the bar's timer and busy status stay untouched.
func animationEl(_ id: String, stock: String, x: Int = 0, y: Int = 0,
                 loop: Bool = true) -> [String: Any] {
    ["id": id, "type": "animation", "stock_path": stock, "x": x, "y": y, "loop": loop]
}

func imageEl(_ id: String, path: String, x: Int = 0, y: Int = 0) -> [String: Any] {
    ["id": id, "type": "image", "path": path, "x": x, "y": y]
}

// MARK: - 72x16 RGBA frame buffer -> PNG

/// Full-frame renderer: the cat/visualizer scripts push one 72x16 image per tick
/// because individual rects cost ~3.6 ms each on the device while a full-frame
/// image is a flat ~50 ms.
struct Frame {
    static let W = 72, H = 16
    var px: [UInt8]

    init() {
        px = [UInt8](repeating: 0, count: Frame.W * Frame.H * 4)
        for i in stride(from: 3, to: px.count, by: 4) { px[i] = 255 }
    }

    /// Fill a solid rect, clipped to the display.
    mutating func rect(_ x: Int, _ y: Int, _ w: Int, _ h: Int, _ c: (r: UInt8, g: UInt8, b: UInt8)) {
        let x2 = min(Frame.W, x + w), y2 = min(Frame.H, y + h)
        let x0 = max(0, x), y0 = max(0, y)
        guard x0 < x2, y0 < y2 else { return }
        for yy in y0..<y2 {
            for xx in x0..<x2 {
                let i = (yy * Frame.W + xx) * 4
                px[i] = c.r; px[i + 1] = c.g; px[i + 2] = c.b; px[i + 3] = 255
            }
        }
    }

    func png() -> Data {
        let provider = CGDataProvider(data: Data(px) as CFData)!
        let img = CGImage(width: Frame.W, height: Frame.H, bitsPerComponent: 8,
                          bitsPerPixel: 32, bytesPerRow: Frame.W * 4,
                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                          bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                          provider: provider, decode: nil, shouldInterpolate: false,
                          intent: .defaultIntent)!
        let out = NSMutableData()
        let dest = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, img, nil)
        CGImageDestinationFinalize(dest)
        return out as Data
    }
}
