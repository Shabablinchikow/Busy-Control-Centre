import Foundation

/// Port of pISSStream (github.com/Jaennaet/pISSStream) — the live fill level of
/// the ISS urine tank, straight from NASA's public telemetry.
///
/// The upstream app links the Lightstreamer SDK; we speak the wire protocol
/// (TLCP) directly instead: an HTTP streaming `create_session` connection plus a
/// one-shot `control` POST to add the subscription. Both items come from the
/// ISSLIVE adapter set:
///   NODE3000005 → Value       = urine tank, percent full
///   TIME_000001 → Status.Class = "24" while the station has signal (AOS)
/// TIME_000001 also doubles as a heartbeat: it ticks ~25x/s unthrottled, so the
/// subscription caps it at 0.2 Hz and a gap means loss of signal.
final class PissStreamApp: MiniApp {
    let app = "piss-stream"

    static let endpoint = "https://push.lightstreamer.com/lightstreamer/"
    /// Identifies the client library to the server; required by TLCP.
    static let cid = "mgQkwtwdysogQz2BJ4Ji kOj2Bg"
    /// No TIME_000001 tick for this long means the telemetry link is down.
    static let staleAfter = 30.0

    static let fill = "#FFD60AFF", fillDim = "#7A6605FF"
    static let outline = "#5A5A50FF", label = "#A0A090FF"
    static let bright = "#F0F0DCFF", dim = "#6C6C63FF", los = "#C06000FF"

    func run(client: BarClient, status: @escaping @Sendable (String) -> Void) async {
        let tank = Telemetry()
        let feed = Task { await Self.feed(tank) }
        status("connecting to ISS…")

        var lastKey = "", lastDraw = Date.distantPast, lastStatus = ""
        while !Task.isCancelled {
            let s = await tank.snapshot()
            // Redraw on change, and at least every ~10s so the bar keeps the frame.
            let key = "\(s.percent ?? -1)|\(s.stale)"
            if key != lastKey || Date().timeIntervalSince(lastDraw) > 9 {
                _ = try? await client.draw(app: app, elements: build(s))  // 409 = bar busy
                lastKey = key
                lastDraw = Date()
            }
            let line = Self.statusLine(s)
            if line != lastStatus { status(line); lastStatus = line }
            if !(await barSleep(1)) { break }
        }

        feed.cancel()
        await client.clear(app: app)
    }

    static func statusLine(_ s: Telemetry.Snapshot) -> String {
        guard let p = s.percent else {
            return s.online ? "waiting for telemetry…" : "connecting to ISS…"
        }
        let pct = String(format: "%.1f%%", p)
        if !s.online { return "signal lost, reconnecting (last \(pct))" }
        if s.stale { return "LOS — no telemetry, last \(pct)" }
        return "urine tank \(pct)"
    }

    // MARK: - Display

    /// Label and reading on the top line, a full-width tank gauge on the bottom.
    /// Loss of signal dims the reading and tags it "LOS", keeping the last value.
    func build(_ s: Telemetry.Snapshot) -> [[String: Any]] {
        var els = [textEl("label", "ISS URINE", x: 0, y: 0, font: "small",
                          color: Self.label, align: "top_left")]

        let lost = s.percent != nil && s.stale
        let text = s.percent.map { String(format: "%.1f%%", $0) } ?? "--%"
        els.append(textEl("pct", text, x: 73, y: 0, font: "small",
                          color: lost ? Self.dim : Self.bright, align: "top_right"))

        els.append(rectEl("g_top", x: 0, y: 8, w: 72, h: 1, color: Self.outline))
        els.append(rectEl("g_bot", x: 0, y: 15, w: 72, h: 1, color: Self.outline))
        els.append(rectEl("g_left", x: 0, y: 9, w: 1, h: 6, color: Self.outline))
        els.append(rectEl("g_right", x: 71, y: 9, w: 1, h: 6, color: Self.outline))
        if let p = s.percent {
            let w = Int((min(100, max(0, p)) / 100 * 70).rounded())
            if w > 0 {
                els.append(rectEl("fill", x: 1, y: 9, w: w, h: 6,
                                  color: lost ? Self.fillDim : Self.fill))
            }
        }
        // Always sent, drawn after the fill so it overlays the gauge. Elements
        // persist on the device by id, so omitting it after LOS ends would
        // leave a stale "LOS" on screen — empty text is the eraser.
        els.append(textEl("los", lost ? "LOS" : "", x: 36, y: 9, font: "small",
                          color: Self.los, align: "top_mid"))
        return els
    }

    // MARK: - Telemetry state

    actor Telemetry {
        struct Snapshot { let percent: Double?; let online: Bool; let stale: Bool }

        private var percent: Double?
        private var hasSignal = false
        private var online = false
        private var lastBeat = Date.distantPast

        func snapshot() -> Snapshot {
            let gap = Date().timeIntervalSince(lastBeat)
            return Snapshot(percent: percent, online: online,
                            stale: !online || !hasSignal || gap > PissStreamApp.staleAfter)
        }

        func setPercent(_ v: Double) { percent = v }
        func setSignal(_ ok: Bool) { hasSignal = ok }
        func beat() { lastBeat = Date() }
        func setOnline(_ v: Bool) { online = v }
    }

    // MARK: - Minimal TLCP client

    static func feed(_ tank: Telemetry) async {
        var backoff = 2.0
        while !Task.isCancelled {
            do {
                try await session(tank)
                backoff = 2
            } catch {
                backoff = min(60, backoff * 2)
            }
            await tank.setOnline(false)
            if !(await barSleep(backoff)) { break }
        }
    }

    /// Opens the streaming session and pumps update lines until it drops.
    static func session(_ tank: Telemetry) async throws {
        var req = URLRequest(url: URL(string: endpoint + "create_session.txt?LS_protocol=TLCP-2.1.0")!)
        req.httpMethod = "POST"
        req.timeoutInterval = 30  // server sends keepalives every 5s
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = form(["LS_adapter_set": "ISSLIVE", "LS_cid": cid, "LS_send_sync": "false"])

        let (bytes, resp) = try await URLSession.shared.bytes(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }

        for try await line in bytes.lines {
            if Task.isCancelled { return }
            // Field data can contain commas, so keep the tail intact.
            let p = line.split(separator: ",", maxSplits: 3, omittingEmptySubsequences: false)
            switch p.first {
            case "CONOK":
                guard p.count > 1 else { throw URLError(.badServerResponse) }
                try await subscribe(session: String(p[1]))
                await tank.setOnline(true)
            case "U":
                guard p.count == 4 else { break }
                let f = fields(String(p[3]))
                if p[2] == "1", let v = f[1], let pct = Double(v) { await tank.setPercent(pct) }
                if p[2] == "2" {
                    await tank.beat()
                    if let cls = f[2] { await tank.setSignal(cls == "24") }
                }
            case "CONERR", "END", "LOOP":
                return  // server wants us gone or rebound; reconnect from scratch
            default:
                break   // SUBOK / CONF / PROBE / NOOP / SERVNAME …
            }
        }
    }

    static func subscribe(session: String) async throws {
        var req = URLRequest(url: URL(string: endpoint + "control.txt?LS_protocol=TLCP-2.1.0")!)
        req.httpMethod = "POST"
        req.timeoutInterval = 15
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = form([
            "LS_session": session, "LS_reqId": "1", "LS_op": "add", "LS_subId": "1",
            "LS_mode": "MERGE", "LS_group": "NODE3000005 TIME_000001",
            "LS_schema": "Value Status.Class", "LS_snapshot": "true",
            "LS_requested_max_frequency": "0.2"])
        _ = try await URLSession.shared.data(for: req)
    }

    /// TLCP packs an update as `v1|v2|…` where an empty slot means "unchanged",
    /// `^n` means n unchanged slots, and `#`/`$` mean null/empty. Returns the
    /// 1-based fields that actually carry a value. Escape sequences are ignored —
    /// these two fields are always numeric.
    static func fields(_ s: String) -> [Int: String] {
        var out: [Int: String] = [:]
        var i = 1
        for tok in s.split(separator: "|", omittingEmptySubsequences: false) {
            if tok.hasPrefix("^") {
                i += Int(tok.dropFirst()) ?? 1
            } else {
                if !tok.isEmpty, tok != "#", tok != "$" { out[i] = String(tok) }
                i += 1
            }
        }
        return out
    }

    static func form(_ d: [String: String]) -> Data {
        d.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? $0.value)" }
            .joined(separator: "&").data(using: .utf8)!
    }
}
