import SwiftUI

/// Tracks one flight by number: while it is airborne the bar shows its callsign
/// and aircraft type with the speed alongside, and the route over a progress bar
/// with the altitude. Data from opendata.adsb.fi, route enrichment (including the
/// airport coordinates the progress bar needs) from api.adsbdb.com.
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
    /// The flight number is the thing you looked up, so it gets its own colour.
    static let flightColor = "#5AC8FAFF"
    /// Origin and destination are told apart by colour, not just by the arrow —
    /// at 5px "AMS>LHR" is four pixels of difference otherwise. The progress bar
    /// uses the same two, so the colours read as "where from" and "where to".
    static let originColor = "#FFA028FF"
    static let destColor = "#30D158FF"
    /// The unflown part of the route: a rule, not a second bar.
    static let track = "#3A3A38FF"
    /// Transparent: the only way to make a rect disappear, since elements persist
    /// by id until they are overwritten.
    static let clear = "#00000000"

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
    /// The 1px route progress bar lives in the gutter between the two ink bands
    /// (rows 2-6 and 10-14), so it costs no text space.
    static let yBar = 8
    /// The origin, separator and destination are three separately coloured
    /// elements, so each one's x comes from the measured width of what precedes
    /// it. The font is proportional: "AMS" is 16px, not 3 x 4.
    static let font = DeviceFont.small
    // The device font carries a 1px right-side bearing (advance = ink + 1), so
    // right-aligning one column past the 72px width lands the ink flush right.
    static let xRight = 73

    static let routeCacheFound = Double.infinity  // routes found: forever
    static let routeCacheNotFound = 6.0 * 3600    // 404: 6h TTL
    static let routeCacheError = 120.0            // network error: 120s TTL

    struct Route {
        var originIata = "", originIcao = "", destIata = "", destIcao = ""
        /// adsbdb ships airport coordinates with the route, which is the only
        /// reason the progress bar needs no second lookup.
        var originLat: Double?, originLon: Double?
        var destLat: Double?, destLon: Double?
    }

    struct Plane {
        var hex = "", callsign = "", type = "", reg = ""
        var altFt: Double?, gs: Double?
        var lat: Double?, lon: Double?
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
        /// What the two readings currently say, so a changed one can roll.
        var shown: (alt: String, speed: String)?

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
                let els = buildFrame(p, route: route, units: units)
                let text = Self.readings(p, units: units)
                // Each reading rolls in its own place: altitude on line 2, speed
                // in the top corner. Neither ever shows the other's number.
                var fields: [Roll.Field] = []
                if let was = shown, was.alt != text.alt, !text.alt.isEmpty {
                    fields.append(Roll.Field(id: "l2right", from: was.alt, to: text.alt,
                                             anchor: .right(Self.xRight),
                                             y: Self.yLine2 + DeviceFont.smallInkOffset,
                                             color: Self.bright))
                }
                if let was = shown, was.speed != text.speed, !text.speed.isEmpty {
                    fields.append(Roll.Field(id: "speed", from: was.speed, to: text.speed,
                                             anchor: .right(Self.xRight),
                                             y: Self.yLine1 + DeviceFont.smallInkOffset,
                                             color: Self.bright))
                }
                shown = text
                do {
                    if fields.isEmpty {
                        let code = try await client.draw(app: app, elements: els,
                                                         ledNotificationColor: onScreen ? nil : Self.ledColor)
                        if code == 409 {
                            status("paused — bar in use")
                        } else {
                            onScreen = true
                            status(Self.statusLine(p, route: route, units: units))
                        }
                    } else {
                        // The progress bar lives in the gutter the masks paint
                        // over, so it is handed to the roll to keep on top.
                        await Roll.play(client: client, app: app, fields: fields,
                                       
                                        over: Self.barEls(Self.progress(p, route)),
                                        then: els)
                        status(Self.statusLine(p, route: route, units: units))
                    }
                } catch {
                    status("draw error: \(error.localizedDescription)")
                }
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
                     altFt: altFt, gs: num(ac["gs"]),
                     lat: num(ac["lat"]), lon: num(ac["lon"]))
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
                     destIcao: dest["icao_code"] as? String ?? "",
                     originLat: Self.num(origin["latitude"]),
                     originLon: Self.num(origin["longitude"]),
                     destLat: Self.num(dest["latitude"]),
                     destLon: Self.num(dest["longitude"]))
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
        guard let (origin, dest) = routePair(route) else { return nil }
        return "\(origin)>\(dest)"
    }

    /// The two airport codes, or nil when the route is unusable.
    static func routePair(_ route: Route?) -> (String, String)? {
        guard let r = route else { return nil }
        let origin = r.originIata.isEmpty ? r.originIcao : r.originIata
        let dest = r.destIata.isEmpty ? r.destIcao : r.destIata
        if origin.isEmpty || dest.isEmpty || origin == dest { return nil }
        return (origin, dest)
    }

    /// How far along the great circle the aircraft is, 0-1, or nil when either the
    /// aircraft or an airport has no position. Measured from the destination, so a
    /// flight that departed from somewhere other than its filed origin (diversion,
    /// mid-route pickup) still shows a sane distance-to-go rather than >1.
    static func progress(_ plane: Plane, _ route: Route?) -> Double? {
        guard let r = route,
              let plat = plane.lat, let plon = plane.lon,
              let olat = r.originLat, let olon = r.originLon,
              let dlat = r.destLat, let dlon = r.destLon else { return nil }
        let total = greatCircleKm(olat, olon, dlat, dlon)
        guard total > 20 else { return nil }   // same airport, or a bad record
        let left = greatCircleKm(plat, plon, dlat, dlon)
        return min(1, max(0, 1 - left / total))
    }

    static func greatCircleKm(_ lat1: Double, _ lon1: Double,
                              _ lat2: Double, _ lon2: Double) -> Double {
        let r = 6371.0, rad = Double.pi / 180
        let dLat = (lat2 - lat1) * rad, dLon = (lon2 - lon1) * rad
        let a = pow(sin(dLat / 2), 2)
            + cos(lat1 * rad) * cos(lat2 * rad) * pow(sin(dLon / 2), 2)
        return 2 * r * asin(min(1, sqrt(a)))
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

    /// The identity: "WZZ4QX (A21N)". The aircraft type is dropped when the line
    /// will not take it — the speed in the corner is live, the type is not, so
    /// the type is what gives way.
    static func ident(_ plane: Plane, speed: String) -> String {
        let base = fmtIdent(plane)
        guard !plane.type.isEmpty else { return base }
        let full = "\(base) (\(plane.type))"
        // 1px of gap, not 2: every character's advance already carries a 1px
        // right bearing, so the visible gap is 2px and "WZZ4QX (A21N)" next to
        // "450kt" comes to exactly 72.
        let room = 72 - font.width(speed) - 1
        return font.width(full) <= room ? full : base
    }

    /// Speed on line 1, altitude on line 2 — each in its own place, so both can
    /// roll when they change instead of taking turns in one slot.
    static func readings(_ plane: Plane, units: Units) -> (alt: String, speed: String) {
        (fmtAlt(plane.altFt, units), fmtSpeed(plane.gs, units))
    }

    func buildFrame(_ plane: Plane, route: Route?, units: Units) -> [[String: Any]] {
        var els: [[String: Any]] = []
        let (altText, speedText) = Self.readings(plane, units: units)

        // Line 1: flight number and type on the left, speed flush right.
        els.append(textEl("callsign", Self.ident(plane, speed: speedText), x: 0, y: Self.yLine1,
                          font: "small", color: Self.flightColor, align: "top_left"))
        els.append(textEl("speed", speedText, x: Self.xRight, y: Self.yLine1,
                          font: "small", color: Self.bright, align: "top_right"))
        // "type" is retired: the aircraft type now travels with the flight number.
        els.append(textEl("type", "", x: Self.xRight, y: Self.yLine1,
                          font: "small", color: Self.dim, align: "top_right"))

        // Line 2: the route on the left, origin and destination coloured apart,
        // and the altitude flush right. Every id is always sent — an omitted
        // element keeps its old value on the device, so "" is the only eraser.
        let (origin, dest) = Self.routePair(route) ?? ("", "")
        let leftText = origin.isEmpty ? "no route" : ""
        let rightText = altText
        let sep = origin.isEmpty ? "" : ">"
        els.append(textEl("orig", origin, x: 0, y: Self.yLine2,
                          font: "small", color: Self.originColor, align: "top_left"))
        els.append(textEl("sep", sep, x: Self.font.width(origin), y: Self.yLine2,
                          font: "small", color: Self.dim, align: "top_left"))
        els.append(textEl("dest", dest, x: Self.font.width(origin + sep), y: Self.yLine2,
                          font: "small", color: Self.destColor, align: "top_left"))
        els.append(textEl("l2left", leftText, x: 0, y: Self.yLine2,
                          font: "small", color: Self.bright, align: "top_left"))
        els.append(textEl("l2right", rightText, x: Self.xRight, y: Self.yLine2,
                          font: "small", color: Self.bright, align: "top_right"))
        els += Self.barEls(Self.progress(plane, route))
        return els
    }

    #if DEBUG
    static func selfCheck() {
        // Amsterdam to Heathrow is ~370 km; halfway is halfway.
        let ams = (52.31, 4.76), lhr = (51.47, -0.45)
        let route = Route(originIata: "AMS", destIata: "LHR",
                          originLat: ams.0, originLon: ams.1,
                          destLat: lhr.0, destLon: lhr.1)
        let total = greatCircleKm(ams.0, ams.1, lhr.0, lhr.1)
        assert(abs(total - 370) < 30, "AMS-LHR is about 370 km, got \(total)")
        var p = Plane(lat: ams.0, lon: ams.1)
        assert(progress(p, route)! < 0.01, "at the gate at the origin, nothing flown")
        p = Plane(lat: lhr.0, lon: lhr.1)
        assert(progress(p, route)! > 0.99, "over the destination, all of it flown")
        p = Plane(lat: (ams.0 + lhr.0) / 2, lon: (ams.1 + lhr.1) / 2)
        assert(abs(progress(p, route)! - 0.5) < 0.05, "the midpoint reads about half")

        // Beyond the destination clamps instead of overshooting the bar.
        p = Plane(lat: 50.0, lon: -3.0)
        assert(progress(p, route)! <= 1, "past the destination stays at full")
        // Missing pieces mean no bar at all, not a bar at zero.
        assert(progress(Plane(), route) == nil, "no aircraft position, no progress")
        assert(progress(p, Route(originIata: "AMS", destIata: "LHR")) == nil,
               "no airport coordinates, no progress")
        assert(progress(p, nil) == nil, "no route, no progress")
        assert(progress(Plane(lat: ams.0, lon: ams.1),
                        Route(originLat: ams.0, originLon: ams.1,
                              destLat: ams.0, destLon: ams.1)) == nil,
               "origin and destination at the same spot is a bad record")

        // Both rects always ship, so the bar can be erased.
        assert(barEls(nil).count == 2 && barEls(0.5).count == 2, "always two rects")
        assert(barEls(0).allSatisfy { ($0["width"] as? Int ?? 0) >= 1 },
               "a zero-width rect would be silently dropped, so the flown part is 1px")
        assert((barEls(0.5)[0]["id"] as? String) == "prog_track",
               "the track is drawn first, the fill on top of it")
        assert((barEls(1)[1]["width"] as? Int) == 72, "an arrived flight fills the bar")
        assert((barEls(0.5)[1]["width"] as? Int) == 36, "halfway is half the width")
        assert(routePair(Route(originIata: "LTN", destIata: "LTN")) == nil,
               "a round trip to the same airport is not a route")
        assert(routePair(Route(originIcao: "EHAM", destIcao: "EGLL"))! == ("EHAM", "EGLL"),
               "ICAO is the fallback when IATA is missing")

        // Line 1 carries the flight number, its type in brackets, and the speed
        // flush right — and gives up the type rather than let them collide.
        var plane = Plane(callsign: "WZZ4QX", type: "A21N")
        assert(ident(plane, speed: "450kt") == "WZZ4QX (A21N)", "the shape asked for")
        assert(font.width(ident(plane, speed: "450kt")) + font.width("450kt") <= 72,
               "and it fits next to an imperial speed")
        assert(ident(plane, speed: "833km/h") == "WZZ4QX",
               "a metric speed leaves no room for the type, so the type goes")
        plane.type = ""
        assert(ident(plane, speed: "450kt") == "WZZ4QX", "no type, no brackets")
        plane = Plane(hex: "4cafc4", type: "B738")
        assert(ident(plane, speed: "450kt") == "4CAFC4",
               "with no callsign the hex is the identity, and letters are wide "
               + "enough that the type has to go")
        assert(ident(Plane(callsign: "KL643", type: "B738"), speed: "450kt") == "KL643 (B738)",
               "a shorter callsign keeps its type")
    }
    #endif

    /// The progress bar: an orange fill on a grey track. Two colours of the same
    /// weight side by side read as two bars rather than one filling up, so the
    /// part still to fly is a dim rule and only the flown part is bright.
    ///
    /// Both rects are always sent, so the bar disappears when the position is
    /// unknown instead of freezing at its last reading.
    static func barEls(_ frac: Double?) -> [[String: Any]] {
        guard let frac else {
            return [rectEl("prog_track", x: 0, y: yBar, w: 72, h: 1, color: clear),
                    rectEl("prog_done", x: 0, y: yBar, w: 1, h: 1, color: clear)]
        }
        let done = min(72, max(1, Int((frac * 72).rounded())))
        return [rectEl("prog_track", x: 0, y: yBar, w: 72, h: 1, color: track),
                rectEl("prog_done", x: 0, y: yBar, w: done, h: 1, color: originColor)]
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
