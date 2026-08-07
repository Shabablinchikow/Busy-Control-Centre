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

    /// What widgets draw at: DEFAULT, the lowest the firmware calls useful.
    ///
    /// The canvas compares against whatever holds the screen, and the comparison
    /// is strict only when nothing is rendering or when the draw comes from the
    /// app that already owns it:
    ///
    ///     gui == NULL || same app  ->  rejected if priority <  current
    ///     someone else rendering   ->  rejected if priority <= current
    ///
    /// The bar's idle busy app sits at PASSTHROUGH (9), so a draw at 9 gets in
    /// only while the bar renders nothing at all — the moment its own app puts
    /// anything on screen, 9 <= 9 and every widget is locked out for good, which
    /// is exactly how pISS went blank and took the carousel's rotation with it.
    /// 10 is admitted in every one of those states, and a session, which raises
    /// the busy app to BLOCKING (101), still refuses it.
    ///
    /// What priority cannot do is tell Apps and Settings from Off: those are
    /// scenes of that same busy app, still at PASSTHROUGH. `SwitchWatcher` is
    /// what stops widgets there.
    static let widgetPriority = 10

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

    /// Remembered across launches: the device only publishes the switch when it
    /// moves, so a fresh app has no way to ask where it is. Without this, quitting
    /// with the switch on Apps and starting again drew straight over the bar's own
    /// screen until the switch was next touched.
    private static let positionKey = "switch.position"

    @Published private(set) var position = BarState.savedPosition()

    private static func savedPosition() -> SwitchPosition {
        let saved = UserDefaults.standard.object(forKey: positionKey) as? Int
        return saved.flatMap(SwitchPosition.init(rawValue:)) ?? .off
    }
    /// Bumped whenever the bar may have thrown our elements away — which is any
    /// time its own screens come or go. Elements do not survive the bar's app
    /// taking the canvas, and a widget that draws once and then leaves the
    /// element alone (the banners, so their animation does not restart and
    /// flicker) has no other way to know it needs to draw again.
    @Published private(set) var generation = 0

    /// The bar is showing something of its own.
    ///
    /// The switch decides this and nothing else. A 409 used to count too, which
    /// stalled the carousel for no good reason: the widget that draws most often
    /// is the one most likely to catch a *transient* refusal — pISS redraws every
    /// four seconds and rolls its digits frame by frame — and every one of those
    /// re-armed the pause. A refusal means somebody else has the screen this
    /// instant, which is not the same as the bar having its own screen up.
    var busy: Bool { !position.isOff }

    /// Whether this widget should stay off the display right now.
    ///
    /// A session needs no help from us: the canvas refuses those draws itself,
    /// and it owns the screen outright while it does.
    func paused(_ app: String) -> Bool {
        !position.isOff && !Self.mayOverride.contains(app)
    }

    /// The stream came back. What we last saw is kept rather than reset: the
    /// device publishes the switch only when it moves, so guessing Off here would
    /// undo both the remembered position and any flick made while the socket was
    /// down — and drawing over the bar's own screen is the thing this is for. A
    /// flick of the switch corrects it either way.
    func noteReconnected() {
        barLog.info("switch stream connected; last known position \(self.position.name, privacy: .public)")
    }

    func note(switch new: SwitchPosition) {
        guard new != position else { return }
        let wasOff = position.isOff
        position = new
        generation += 1
        UserDefaults.standard.set(new.rawValue, forKey: Self.positionKey)
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
