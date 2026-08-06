import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

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
    func draw(app: String, elements: [[String: Any]], priority: Int? = nil,
              ledNotificationColor: String? = nil) async throws -> Int {
        var body: [String: Any] = ["application_name": app, "elements": elements]
        if let priority { body["priority"] = priority }
        if let ledNotificationColor { body["led_notification_color"] = ledNotificationColor }
        var req = request(base.appendingPathComponent("api/display/draw"), method: "POST")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (_, resp) = try await Self.session.data(for: req)
        return (resp as? HTTPURLResponse)?.statusCode ?? 0
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
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
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
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (_, resp) = try await Self.session.data(for: req)
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

// MARK: - Element builders (same JSON shapes the python scripts sent)

func textEl(_ id: String, _ text: String, x: Int, y: Int, font: String = "normal",
            color: String = "#FFFFFFFF", align: String? = nil) -> [String: Any] {
    var el: [String: Any] = ["id": id, "type": "text", "text": text,
                             "x": x, "y": y, "font": font, "color": color]
    if let align { el["align"] = align }
    return el
}

func rectEl(_ id: String, x: Int, y: Int, w: Int, h: Int, color: String) -> [String: Any] {
    ["id": id, "type": "rectangle", "x": x, "y": y, "width": w, "height": h,
     "border_width": 0, "fill": "solid", "fill_colors": [color]]
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
