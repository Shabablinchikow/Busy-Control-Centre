import SwiftUI
import CoreLocation

/// Port of iss.py — stays quiet until the space station passes near you.
final class ISSApp: MiniApp {
    let app = "iss-alert"
    static let issURL = URL(string: "https://api.wheretheiss.at/v1/satellites/25544")!
    static let far = 1500.0, near = 700.0  // state thresholds (km)

    enum State: String { case far, approach, overhead, departing }

    // Starfield in the sky band (rows 0-7): (x, y, tier) with tier 0 = bright,
    // 1 = mid, 2 = dim. Stars twinkle one tier brighter in turn on each redraw,
    // and a plus-shaped glint wanders between a few fixed spots.
    static let stars: [(x: Int, y: Int, tier: Int)] = [
        (3, 6, 2), (6, 1, 1), (11, 3, 2), (15, 6, 1), (19, 1, 2), (24, 4, 0),
        (29, 7, 2), (33, 0, 1), (38, 3, 2), (43, 6, 1), (47, 1, 2), (51, 5, 0),
        (55, 2, 2), (59, 7, 1), (63, 0, 2), (66, 4, 1), (69, 2, 2), (70, 6, 0)]
    static let starColors = ["#FFFFFFFF", "#969696FF", "#505050FF"]
    static let glints = [(8, 2), (62, 5), (26, 1), (55, 3)]

    func run(client: BarClient, status: @escaping @Sendable (String) -> Void) async {
        let d = UserDefaults.standard
        let lat = d.object(forKey: "iss.lat") as? Double ?? 52.37
        let lon = d.object(forKey: "iss.lon") as? Double ?? 4.89
        let interval = d.object(forKey: "iss.interval") as? Double ?? 30

        var prevDistance: Double?
        var onScreen = false
        var ledNotified = false  // true after first overhead LED notification per pass
        var prevState: State?
        var tick = 0             // advances the star twinkle every redraw

        status("watching the sky (lat \(lat), lon \(lon))")

        while !Task.isCancelled {
            var distance: Double
            var fetched = false
            do {
                var req = URLRequest(url: Self.issURL)
                req.setValue("busybar-iss-alert/1.0", forHTTPHeaderField: "User-Agent")
                req.timeoutInterval = 10
                let (data, _) = try await URLSession.shared.data(for: req)
                let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
                let ilat = obj["latitude"] as? Double ?? 0
                let ilon = obj["longitude"] as? Double ?? 0
                distance = Self.haversine(lat, lon, ilat, ilon)
                fetched = true
            } catch {
                // No fresh data — keep the previous distance to avoid false state changes.
                guard let prev = prevDistance else {
                    status("fetch error: \(error.localizedDescription)")
                    if !(await barSleep(interval)) { break }
                    continue
                }
                distance = prev
            }

            let state = Self.classify(distance, prevDistance)
            if state != prevState {
                status("\(state.rawValue)  (\(Int(distance)) km)")
            } else if fetched {
                status("\(state.rawValue)  ISS \(Int(distance)) km")
            }

            switch state {
            case .far:
                if onScreen {
                    await client.clear(app: app)
                    onScreen = false
                    ledNotified = false
                }
            case .approach, .departing:
                let els = buildPass(distance: distance, tick: tick, departing: state == .departing)
                if let code = try? await client.draw(app: app, elements: els, priority: 60),
                   code != 409 { onScreen = true }
            case .overhead:
                var notify: String?
                if !ledNotified { notify = "#00A8FFFF"; ledNotified = true }
                let els = buildOverhead(distance: distance, tick: tick)
                if let code = try? await client.draw(app: app, elements: els, priority: 60,
                                                     ledNotificationColor: notify),
                   code != 409 { onScreen = true }
            }

            // When the pass ends, reset so the next pass notifies again.
            if state == .far, let p = prevState, p != .far { ledNotified = false }

            prevState = state
            prevDistance = distance
            tick += 1
            if !(await barSleep(interval)) { break }
        }
        await client.clear(app: app)
    }

    static func classify(_ distance: Double, _ prev: Double?) -> State {
        if distance <= near { return .overhead }
        if distance <= far {
            if prev == nil || distance < prev! { return .approach }
            return .departing
        }
        return .far
    }

    /// Great-circle distance in km.
    static func haversine(_ lat1: Double, _ lon1: Double, _ lat2: Double, _ lon2: Double) -> Double {
        let r = 6371.0
        let phi1 = lat1 * .pi / 180, phi2 = lat2 * .pi / 180
        let dphi = (lat2 - lat1) * .pi / 180
        let dlam = (lon2 - lon1) * .pi / 180
        let a = pow(sin(dphi / 2), 2) + cos(phi1) * cos(phi2) * pow(sin(dlam / 2), 2)
        return r * 2 * asin(sqrt(a))
    }

    // MARK: - Display elements

    func starfield(_ tick: Int) -> [[String: Any]] {
        var els: [[String: Any]] = []
        for (i, s) in Self.stars.enumerated() {
            let t = max(0, s.tier - ((i + tick) % 4 == 0 ? 1 : 0))
            els.append(rectEl("star\(i)", x: s.x, y: s.y, w: 1, h: 1, color: Self.starColors[t]))
        }
        let (gx, gy) = Self.glints[tick % Self.glints.count]
        els.append(rectEl("glint_h", x: gx - 1, y: gy, w: 3, h: 1, color: "#787878FF"))
        els.append(rectEl("glint_v", x: gx, y: gy - 1, w: 1, h: 3, color: "#787878FF"))
        els.append(rectEl("glint_c", x: gx, y: gy, w: 1, h: 1, color: "#FFFFFFFF"))
        return els
    }

    /// Pseudo-3D ISS, ~22x7 at offset x0: four slanted solar arrays with a lit
    /// top and shaded bottom half, a truss with a drop shadow, and a module
    /// stack with a lit side, a shadow side and cyan docking ports.
    func sprite(_ x0: Int) -> [[String: Any]] {
        let light = "#FFC832FF", dark = "#B46400FF"
        let white = "#FFFFFFFF", gray = "#8C8C8CFF", cyan = "#00E5FFFF"
        var els: [[String: Any]] = []
        for px in [0, 3, 15, 18] {
            for r in 0..<7 {
                let off = (6 - r) / 3  // rows shift right toward the top: slanted panels
                els.append(rectEl("panel_\(px)_\(r)", x: x0 + px + off, y: r, w: 2, h: 1,
                                  color: r < 3 ? light : dark))
            }
        }
        els.append(rectEl("truss", x: x0 + 2, y: 3, w: 17, h: 1, color: white))
        els.append(rectEl("truss_shadow", x: x0 + 3, y: 4, w: 15, h: 1, color: "#505050FF"))
        els.append(rectEl("module_lit", x: x0 + 9, y: 1, w: 2, h: 5, color: white))
        els.append(rectEl("module_shadow", x: x0 + 11, y: 1, w: 1, h: 5, color: gray))
        els.append(rectEl("dock_top", x: x0 + 10, y: 0, w: 1, h: 1, color: cyan))
        els.append(rectEl("dock_bottom", x: x0 + 10, y: 6, w: 1, h: 1, color: cyan))
        return els
    }

    /// Approach: slide toward the center (1500 km = far left, ≤700 km = centered).
    /// Departing: continue from the center off the right edge.
    func buildPass(distance: Double, tick: Int, departing: Bool) -> [[String: Any]] {
        let x: Int
        if departing {
            let frac = max(0, min(1, (distance - Self.near) / (Self.far - Self.near)))
            x = Int(25 + frac * (72 - 25))
        } else {
            let frac = max(0, min(1, (Self.far - distance) / (Self.far - Self.near)))
            x = Int(2 + frac * (25 - 2))
        }
        var els = starfield(tick) + sprite(x)
        els.append(textEl("info_text", "ISS  \(Int(distance)) KM", x: 36, y: 9,
                          font: "small", align: "top_mid"))
        return els
    }

    func buildOverhead(distance: Double, tick: Int) -> [[String: Any]] {
        var els = starfield(tick) + sprite(25)
        els.append(textEl("info_text", "OVERHEAD  \(Int(distance)) KM", x: 36, y: 9,
                          font: "small", color: "#00E5FFFF", align: "top_mid"))
        return els
    }
}

struct ISSSettingsView: View {
    @AppStorage("iss.lat") private var lat = 52.37
    @AppStorage("iss.lon") private var lon = 4.89
    @AppStorage("iss.interval") private var interval = 30.0
    @StateObject private var location = LocationOnce()

    var body: some View {
        Form {
            TextField("Latitude", value: $lat, format: .number)
            TextField("Longitude", value: $lon, format: .number)
            Button("Use current location") {
                location.request { lat = $0.latitude; lon = $0.longitude }
            }
            if let err = location.error {
                Text(err).font(.caption).foregroundStyle(.red)
            }
            TextField("Check every (s)", value: $interval, format: .number)
        }
        .frame(width: 220)
    }
}

/// One-shot CLLocation fetch for settings forms.
final class LocationOnce: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published var error: String?
    private let mgr = CLLocationManager()
    private var done: ((CLLocationCoordinate2D) -> Void)?

    func request(_ done: @escaping (CLLocationCoordinate2D) -> Void) {
        self.done = done
        error = nil
        mgr.delegate = self
        mgr.desiredAccuracy = kCLLocationAccuracyKilometer
        // ponytail: if the auth prompt appears, the first click only grants —
        // clicking the button again then fills the fields
        mgr.requestWhenInUseAuthorization()
        mgr.requestLocation()
    }

    func locationManager(_ m: CLLocationManager, didUpdateLocations locs: [CLLocation]) {
        if let c = locs.first?.coordinate { done?(c) }
        done = nil
    }

    func locationManager(_ m: CLLocationManager, didFailWithError e: Error) {
        error = "location unavailable: \(e.localizedDescription)"
        done = nil
    }
}
