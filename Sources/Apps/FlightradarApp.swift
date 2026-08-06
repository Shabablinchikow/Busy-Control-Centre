import SwiftUI

/// Tracks one flight by number: while it is airborne the bar shows its callsign,
/// aircraft type, route and altitude/speed. Data from opendata.adsb.fi, route
/// enrichment from api.adsbdb.com.
final class FlightradarApp: MiniApp {
    let app = "flightradar"

    enum Units: String { case imperial, metric }
    enum FetchError: Error { case http(Int), notFound, bad }

    static let adsbTemplate = "https://opendata.adsb.fi/api/v2/callsign/%@"
    static let adsbdbTemplate = "https://api.adsbdb.com/v0/callsign/%@"
    static let userAgent = "busybar-flightradar/1.0"

    // Warm cream palette.
    static let bright = "#F0F0DCFF"
    static let dim = "#6C6C63FF"
    static let ledColor = "#F0F0DCFF"

    // Two lines of the 5px small font, no separator. The small-font ink sits ~2px
    // lower than its nominal y, so line 1 at y=0 lands on ink rows 2-6 and line 2
    // at y=8 on rows 10-14.
    //
    // Trade-off (intentional, do not "fix"): the bar plays a 1px settle animation
    // whenever a text element's content changes (altitude updates every poll). It
    // is hidden only when the ink is flush to the bottom edge (y=9), where the
    // extra frame clips off-screen; at y=8 it shows as a small bounce. y=8 is
    // chosen for the better vertical centring. The draw API cannot disable it.
    static let yLine1 = 0
    static let yLine2 = 8
    // The device font carries a 1px right-side bearing (advance = ink + 1), so
    // right-aligning one column past the 72px width lands the ink flush right.
    static let xRight = 73

    static let routeCacheFound = Double.infinity  // routes found: forever
    static let routeCacheNotFound = 6.0 * 3600    // 404: 6h TTL
    static let routeCacheError = 120.0            // network error: 120s TTL

    struct Route {
        var originIata = "", originIcao = "", destIata = "", destIcao = ""
    }

    struct Plane {
        var hex = "", callsign = "", type = "", reg = ""
        var altFt: Double?, gs: Double?
    }

    var routeCache: [String: (expires: Double, route: Route?)] = [:]

    // MARK: - Main loop

    func run(client: BarClient, status: @escaping @Sendable (String) -> Void) async {
        let d = UserDefaults.standard
        let callsign = (d.string(forKey: "fr.callsign") ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let interval = max(1, d.object(forKey: "fr.interval") as? Double ?? 15)
        let units = Units(rawValue: d.string(forKey: "fr.units") ?? "") ?? .imperial

        var onScreen = false
        var tick = 0

        while !Task.isCancelled {
            guard !callsign.isEmpty else {
                status("set a flight number in settings")
                if !(await barSleep(interval)) { break }
                continue
            }

            var plane: Plane?
            var fetched = false
            do {
                plane = try await fetchFlight(callsign)
                fetched = true
            } catch {
                // Transient feed trouble: leave whatever is on the bar alone.
                status("adsb.fi: \(error.localizedDescription)")
            }

            if fetched, let p = plane {
                let route = await getRoute(callsign, now: Date().timeIntervalSince1970)
                let els = buildFrame(p, route: route, tick: tick, units: units)
                do {
                    let code = try await client.draw(app: app, elements: els, priority: 60,
                                                     ledNotificationColor: onScreen ? nil : Self.ledColor)
                    if code == 409 {
                        status("display busy")
                    } else {
                        onScreen = true
                        status(Self.statusLine(p, route: route, units: units))
                    }
                } catch {
                    status("draw error: \(error.localizedDescription)")
                }
                tick += 1
            } else if fetched {
                if onScreen {
                    await client.clear(app: app)
                    onScreen = false
                }
                status("\(callsign) not airborne")
            }

            if !(await barSleep(interval)) { break }
        }
        await client.clear(app: app)
    }

    // MARK: - Data

    /// First airborne aircraft currently broadcasting this callsign, or nil.
    func fetchFlight(_ callsign: String) async throws -> Plane? {
        let obj = try await getJSON(Self.adsbTemplate, callsign)
        let list = obj["ac"] as? [[String: Any]] ?? []
        return list.compactMap(Self.airborne).first
    }

    static func airborne(_ ac: [String: Any]) -> Plane? {
        if ac["alt_baro"] as? String == "ground" { return nil }
        let altFt = num(ac["alt_baro"])
        // On the ground a plane reports a small negative barometric altitude
        // rather than the "ground" string on a high-QNH day.
        if let a = altFt, a <= 0 { return nil }
        return Plane(hex: ac["hex"] as? String ?? "",
                     callsign: trimmed(ac["flight"]).uppercased(),
                     type: trimmed(ac["t"]), reg: trimmed(ac["r"]),
                     altFt: altFt, gs: num(ac["gs"]))
    }

    /// Cached route or a fresh adsbdb fetch. Hits never touch the network; 404s
    /// and errors are cached negatively so a routeless flight is asked about at
    /// most a couple of times per session.
    func getRoute(_ callsign: String, now: Double) async -> Route? {
        if let hit = routeCache[callsign] {
            if now < hit.expires { return hit.route }
            routeCache.removeValue(forKey: callsign)
        }
        do {
            let r = try await fetchRoute(callsign)
            routeCache[callsign] = (now + Self.routeCacheFound, r)
            return r
        } catch FetchError.notFound {
            routeCache[callsign] = (now + Self.routeCacheNotFound, nil)
            return nil
        } catch {
            routeCache[callsign] = (now + Self.routeCacheError, nil)
            return nil
        }
    }

    func fetchRoute(_ callsign: String) async throws -> Route {
        let obj = try await getJSON(Self.adsbdbTemplate, callsign)
        guard let response = obj["response"] as? [String: Any] else { throw FetchError.bad }
        let route = response["flightroute"] as? [String: Any] ?? [:]
        let origin = route["origin"] as? [String: Any] ?? [:]
        let dest = route["destination"] as? [String: Any] ?? [:]
        return Route(originIata: origin["iata_code"] as? String ?? "",
                     originIcao: origin["icao_code"] as? String ?? "",
                     destIata: dest["iata_code"] as? String ?? "",
                     destIcao: dest["icao_code"] as? String ?? "")
    }

    private func getJSON(_ template: String, _ callsign: String) async throws -> [String: Any] {
        let enc = callsign.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? callsign
        guard let url = URL(string: String(format: template, enc)) else { throw FetchError.bad }
        var req = URLRequest(url: url)
        req.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 10
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code == 404 { throw FetchError.notFound }
        if code >= 400 { throw FetchError.http(code) }
        return try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
    }

    // MARK: - Formatting

    static func fmtAlt(_ altFt: Double?, _ units: Units) -> String {
        guard let a = altFt else { return "---" }
        if units == .metric {
            // Always metres, never km, with a Dutch thousands separator: "10.000m".
            return groupThousands(Int((a * 0.3048).rounded())) + "m"
        }
        if a >= 10000 { return "FL\(Int((a / 100).rounded()))" }
        return "\(Int(a.rounded()))ft"
    }

    static func fmtSpeed(_ gs: Double?, _ units: Units) -> String {
        guard let g = gs else { return "---" }
        if units == .metric { return "\(Int((g * 1.852).rounded()))km/h" }
        return "\(Int(g.rounded()))kt"
    }

    static func fmtIdent(_ plane: Plane) -> String {
        if !plane.callsign.isEmpty { return plane.callsign }
        if !plane.reg.isEmpty { return plane.reg }
        return plane.hex.uppercased()
    }

    /// "AMS>LHR", or nil when unknown. adsbdb occasionally returns a route whose
    /// origin and destination are the same airport (round-trip / positioning
    /// flights, or an incomplete record); "LTN>LTN" is meaningless on the bar, so
    /// treat it as unknown and let the frame fall back to altitude/speed.
    static func fmtRoute(_ route: Route?) -> String? {
        guard let r = route else { return nil }
        let origin = r.originIata.isEmpty ? r.originIcao : r.originIata
        let dest = r.destIata.isEmpty ? r.destIcao : r.destIata
        if origin.isEmpty || dest.isEmpty || origin == dest { return nil }
        return "\(origin)>\(dest)"
    }

    static func statusLine(_ plane: Plane, route: Route?, units: Units) -> String {
        var parts = [fmtIdent(plane)]
        if let r = fmtRoute(route) { parts.append(r.replacingOccurrences(of: ">", with: "→")) }
        parts.append(fmtAlt(plane.altFt, units))
        parts.append(fmtSpeed(plane.gs, units))
        return parts.joined(separator: "  ")
    }

    static func groupThousands(_ n: Int) -> String {
        let digits = String(abs(n))
        var out = n < 0 ? "-" : ""
        for (i, ch) in digits.enumerated() {
            if i > 0 && (digits.count - i) % 3 == 0 { out.append(".") }
            out.append(ch)
        }
        return out
    }

    static func num(_ v: Any?) -> Double? {
        if let n = v as? NSNumber { return n.doubleValue }
        if let s = v as? String { return Double(s) }
        return nil
    }

    static func trimmed(_ v: Any?) -> String {
        (v as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Frame builder

    func buildFrame(_ plane: Plane, route: Route?, tick: Int, units: Units) -> [[String: Any]] {
        let altStr = Self.fmtAlt(plane.altFt, units)
        let speedStr = Self.fmtSpeed(plane.gs, units)

        var els: [[String: Any]] = []

        // Line 1: callsign/ident left, aircraft type right (if known).
        els.append(textEl("callsign", Self.fmtIdent(plane), x: 0, y: Self.yLine1,
                          font: "small", color: Self.bright, align: "top_left"))
        if !plane.type.isEmpty {
            els.append(textEl("type", plane.type, x: Self.xRight, y: Self.yLine1,
                              font: "small", color: Self.dim, align: "top_right"))
        }

        // Line 2: with a route, show it left and flap altitude<->speed right;
        // without one, show altitude and speed side by side.
        let leftText: String, rightText: String
        if let r = Self.fmtRoute(route) {
            leftText = r
            rightText = tick % 2 == 0 ? altStr : speedStr
        } else {
            leftText = altStr
            rightText = speedStr
        }
        els.append(textEl("l2left", leftText, x: 0, y: Self.yLine2,
                          font: "small", color: Self.bright, align: "top_left"))
        els.append(textEl("l2right", rightText, x: Self.xRight, y: Self.yLine2,
                          font: "small", color: Self.bright, align: "top_right"))
        return els
    }
}

struct FlightradarSettingsView: View {
    @AppStorage("fr.callsign") private var callsign = ""
    @AppStorage("fr.interval") private var interval = 15.0
    @AppStorage("fr.units") private var units = "imperial"

    var body: some View {
        Form {
            TextField("Flight number", text: $callsign, prompt: Text("KLM643"))
            TextField("Check every (s)", value: $interval, format: .number)
            // Segmented, not the default menu style: a menu Picker opens an
            // out-of-process NSRemoteView, which throws inside AppKit here.
            Picker("Units", selection: $units) {
                Text("ft / kt").tag("imperial")
                Text("m / km/h").tag("metric")
            }
            .pickerStyle(.segmented)
        }
        .frame(width: 240)
    }
}
