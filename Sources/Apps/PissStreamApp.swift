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

    static let fill = "#FFD60AFF"
    static let outline = "#5A5A50FF", label = "#A0A090FF"
    static let bright = "#F0F0DCFF", dim = "#6C6C63FF", los = "#FF3B30FF"

    /// Ink row of the "LOS" tag: the gauge owns rows 8-15, so 5 rows of ink
    /// starting at 9 sit centred between its borders. `textEl` is anchored two
    /// rows above its ink in the small font.
    static let losY = 7
    /// The percentage is right-aligned one column past the display so its ink
    /// lands flush; its ink starts two rows below the nominal y.
    static let pctRight = 73, pctInkY = 2

    func run(client: BarClient, status: @escaping @Sendable (String) -> Void) async {
        let tank = Telemetry()
        let feed = Task { await Self.feed(tank) }
        status("connecting to ISS…")

        var lastKey = "", lastDraw = Date.distantPast, lastStatus = "", shown = ""
        while !Task.isCancelled {
            let s = await tank.snapshot()
            // Redraw on change, and often enough that coming back from the bar's
            // own screen is not a long wait staring at nothing.
            let key = "\(s.percent ?? -1)|\(s.stale)"
            if key != lastKey || Date().timeIntervalSince(lastDraw) > 4 {
                let els = build(s)
                let text = Self.pctText(s)
                if !shown.isEmpty, shown != text {
                    // Rolls the digits that moved, then hands the reading back to
                    // the text element in the same frame the rects retire.
                    await Roll.play(client: client, app: app, fields: [
                        Roll.Field(id: "pct", from: shown, to: text,
                                   anchor: .right(Self.pctRight), y: Self.pctInkY,
                                   color: Self.lost(s) ? Self.dim : Self.bright),
                    ], then: els)
                } else {
                    _ = try? await client.draw(app: app, elements: els)  // 409 = bar busy
                }
                shown = text
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

    static func lost(_ s: Telemetry.Snapshot) -> Bool { s.percent != nil && s.stale }

    static func pctText(_ s: Telemetry.Snapshot) -> String {
        s.percent.map { String(format: "%.1f%%", $0) } ?? "--%"
    }

    /// Label and reading on the top line, a full-width tank gauge on the bottom.
    /// Loss of signal dims the reading and tags it "LOS" in red, keeping the last
    /// value. The gauge itself is left alone: its colour is the tank level, not
    /// the link state, and dimming it read as the level having dropped.
    func build(_ s: Telemetry.Snapshot) -> [[String: Any]] {
        var els = [textEl("label", "pISS", x: 0, y: 0, font: "small",
                          color: Self.label, align: "top_left")]

        let lost = Self.lost(s)
        els.append(textEl("pct", Self.pctText(s), x: Self.pctRight, y: 0, font: "small",
                          color: lost ? Self.dim : Self.bright, align: "top_right"))

        els.append(rectEl("g_top", x: 0, y: 8, w: 72, h: 1, color: Self.outline))
        els.append(rectEl("g_bot", x: 0, y: 15, w: 72, h: 1, color: Self.outline))
        els.append(rectEl("g_left", x: 0, y: 9, w: 1, h: 6, color: Self.outline))
        els.append(rectEl("g_right", x: 71, y: 9, w: 1, h: 6, color: Self.outline))
        // Always sent, even with nothing to show, so that the fill's element
        // exists before the LOS tag's does. The bar paints elements in the order
        // it first saw them, so a fill that only appeared once telemetry arrived
        // would be created after the tag and cover it.
        let w = s.percent.map { Int((min(100, max(0, $0)) / 100 * 70).rounded()) } ?? 0
        els.append(rectEl("fill", x: 1, y: 9, w: max(1, w), h: 6,
                          color: w > 0 ? Self.fill : "#00000000"))
        // Always sent too. Elements persist on the device by id, so omitting it
        // after LOS ends would leave a stale "LOS" on screen — empty text is the
        // eraser.
        els.append(textEl("los", lost ? "LOS" : "", x: 36, y: Self.losY, font: "small",
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
