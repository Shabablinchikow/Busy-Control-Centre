import SwiftUI

/// Condition icon, temperature, UV index and rain probability. Open-Meteo needs
/// no key and answers all four in one `current=` block.
final class WeatherApp: MiniApp {
    let app = "weather"

    static let template = "https://api.open-meteo.com/v1/forecast"
    static let userAgent = "busybar-weather/1.0"

    static let ink = "#FFFFFFFF"
    static let dim = "#8A8A8AFF"
    static let iconTint = "#FFD37AFF"

    // Two 5px text lines, right-aligned at x=73 (the font's 1px right bearing),
    // with the 8x8 icon vertically centred at the left.
    static let yLine1 = 0
    static let yLine2 = 8
    static let xRight = 73
    static let iconX = 0
    static let iconY = 4
    /// Left edge of the text, clear of the icon.
    static let xText = 10

    enum Units: String { case metric, imperial }

    struct Conditions {
        var tempC = 0.0, uv = 0.0
        var rainPct = 0
        var code = 0
        var isDay = true
    }

    // MARK: - Main loop

    func run(client: BarClient, status: @escaping @Sendable (String) -> Void) async {
        let d = UserDefaults.standard
        let lat = d.object(forKey: "wx.lat") as? Double ?? 52.37
        let lon = d.object(forKey: "wx.lon") as? Double ?? 4.89
        // Open-Meteo's current block advances every 900s, so polling faster than
        // that just re-fetches the same numbers.
        let interval = max(60, d.object(forKey: "wx.interval") as? Double ?? 600)
        let units = Units(rawValue: d.string(forKey: "wx.units") ?? "") ?? .metric

        while !Task.isCancelled {
            do {
                let c = try await fetch(lat: lat, lon: lon)
                let code = try await client.draw(app: app, elements: Self.frame(c, units: units),
                                                 priority: 60)
                status(code == 409 ? "display busy" : Self.statusLine(c, units: units))
            } catch {
                // Leave the last reading on the bar; weather does not go stale fast.
                status("open-meteo: \(error.localizedDescription)")
            }
            if !(await barSleep(interval)) { break }
        }
        await client.clear(app: app)
    }

    // MARK: - Data

    func fetch(lat: Double, lon: Double) async throws -> Conditions {
        var comps = URLComponents(string: Self.template)!
        comps.queryItems = [
            URLQueryItem(name: "latitude", value: String(lat)),
            URLQueryItem(name: "longitude", value: String(lon)),
            URLQueryItem(name: "current",
                         value: "temperature_2m,weather_code,is_day,uv_index,precipitation_probability"),
            URLQueryItem(name: "timezone", value: "auto"),
        ]
        guard let url = comps.url else { throw WebError.bad }
        let obj = try await fetchJSON(url, userAgent: Self.userAgent)
        guard let cur = obj["current"] as? [String: Any] else { throw WebError.bad }
        return Conditions(tempC: Self.num(cur["temperature_2m"]) ?? 0,
                          uv: Self.num(cur["uv_index"]) ?? 0,
                          rainPct: Int(Self.num(cur["precipitation_probability"]) ?? 0),
                          code: Int(Self.num(cur["weather_code"]) ?? 0),
                          isDay: (Self.num(cur["is_day"]) ?? 1) != 0)
    }

    // MARK: - Pure helpers

    /// Always requested in Celsius and converted here, so the unit setting does
    /// not change the request and a cached reading stays valid across a switch.
    static func temp(_ c: Conditions, _ units: Units) -> Double {
        units == .imperial ? c.tempC * 9 / 5 + 32 : c.tempC
    }

    /// "C"/"F" rather than a degree sign: every other widget sticks to ASCII the
    /// device font is known to carry (Flightradar's m/ft/kt), and a missing glyph
    /// shows as a box.
    static func fmtTemp(_ c: Conditions, _ units: Units) -> String {
        "\(Int(temp(c, units).rounded()))\(units == .imperial ? "F" : "C")"
    }

    /// The UV index is a 0-11 scale, so a whole number is the honest precision.
    static func fmtUV(_ uv: Double) -> String { "UV \(Int(uv.rounded()))" }

    static func fmtRain(_ pct: Int) -> String { "\(pct)%" }

    static func statusLine(_ c: Conditions, units: Units) -> String {
        "\(fmtTemp(c, units))  \(fmtUV(c.uv))  rain \(fmtRain(c.rainPct))"
    }

    static func num(_ v: Any?) -> Double? {
        if let n = v as? NSNumber { return n.doubleValue }
        if let s = v as? String { return Double(s) }
        return nil
    }

    // MARK: - Frame

    static func frame(_ c: Conditions, units: Units) -> [[String: Any]] {
        var els = Glyph.els("wx", Glyph.weatherIcon(code: c.code, isDay: c.isDay),
                            x: iconX, y: iconY, color: iconTint, slots: Glyph.iconSlots)
        els.append(textEl("temp", fmtTemp(c, units), x: xRight, y: yLine1,
                          font: "small", color: ink, align: "top_right"))
        els.append(textEl("uv", fmtUV(c.uv), x: xText, y: yLine2,
                          font: "small", color: dim, align: "top_left"))
        els.append(textEl("rain", fmtRain(c.rainPct), x: xRight, y: yLine2,
                          font: "small", color: ink, align: "top_right"))
        return els
    }

    #if DEBUG
    static func selfCheck() {
        var c = Conditions(tempC: 18.9, uv: 0.2, rainPct: 0, code: 0, isDay: true)
        assert(fmtTemp(c, .metric) == "19C", "rounded Celsius")
        assert(fmtTemp(c, .imperial) == "66F", "18.9C is 66F")
        assert(fmtUV(0.2) == "UV 0" && fmtUV(7.4) == "UV 7", "whole-number UV")
        assert(fmtRain(0) == "0%" && fmtRain(100) == "100%", "rain probability")

        // Code mapping, including the day/night split on clear skies.
        assert(Glyph.weatherIcon(code: 0, isDay: true) == Glyph.sun, "clear day")
        assert(Glyph.weatherIcon(code: 0, isDay: false) == Glyph.moon, "clear night")
        assert(Glyph.weatherIcon(code: 3, isDay: true) == Glyph.cloud, "overcast")
        assert(Glyph.weatherIcon(code: 48, isDay: true) == Glyph.fog, "fog")
        assert(Glyph.weatherIcon(code: 71, isDay: true) == Glyph.snow, "snow")
        assert(Glyph.weatherIcon(code: 99, isDay: true) == Glyph.storm, "thunderstorm")
        assert(Glyph.weatherIcon(code: 61, isDay: true) == Glyph.rain, "rain")
        assert(Glyph.weatherIcon(code: 81, isDay: true) == Glyph.rain, "showers")

        // Below-zero temperatures must not lose their sign.
        c.tempC = -4.4
        assert(fmtTemp(c, .metric) == "-4C", "negative Celsius keeps its sign")
        assert(fmtTemp(c, .imperial) == "24F", "-4.4C is 24F")
        // Halves round away from zero, so negatives behave like positives do.
        c.tempC = -4.5
        assert(fmtTemp(c, .metric) == "-5C", "-4.5 rounds away from zero")
        c.tempC = 18.5
        assert(fmtTemp(c, .metric) == "19C", "and so does 18.5")
    }
    #endif
}

struct WeatherSettingsView: View {
    @AppStorage("wx.lat") private var lat = 52.37
    @AppStorage("wx.lon") private var lon = 4.89
    @AppStorage("wx.interval") private var interval = 600.0
    @AppStorage("wx.units") private var units = "metric"
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
            // Segmented: a menu Picker opens an out-of-process NSRemoteView,
            // which throws inside AppKit on this macOS beta.
            Picker("Units", selection: $units) {
                Text("C").tag("metric")
                Text("F").tag("imperial")
            }
            .pickerStyle(.segmented)
        }
        .frame(width: 240)
    }
}
