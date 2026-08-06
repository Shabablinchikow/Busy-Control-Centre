import SwiftUI

/// Two-tone condition icon, temperature, wind, UV index and rain probability.
/// Open-Meteo needs no key and answers all of it in one `current=` block.
final class WeatherApp: MiniApp {
    let app = "weather"

    static let template = "https://api.open-meteo.com/v1/forecast"
    static let userAgent = "busybar-weather/1.0"

    static let ink = "#FFFFFFFF"
    static let dim = "#8A8A8AFF"
    static let windTint = "#7FD4FFFF"

    // Two 5px text lines, right-aligned at x=73 (the font's 1px right bearing),
    // with the 8x8 icon vertically centred at the left.
    static let yLine1 = 0
    static let yLine2 = 8
    static let xRight = 73
    static let iconX = 0
    static let iconY = 4
    /// Left edge of the text, clear of the icon.
    static let xText = 10
    /// Ink rows of the two lines: the small font draws two rows below its y.
    /// Wind sits on line 1 next to the icon: the font's own compass arrow, then
    /// the speed, in one element.
    static let windX = 10

    enum Units: String { case metric, imperial }

    struct Conditions {
        var tempC = 0.0, uv = 0.0
        var rainPct = 0
        var code = 0
        var isDay = true
        /// km/h and the meteorological bearing the wind blows *from*.
        var windKmh = 0.0, windDeg = 0.0
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

        var shownTemp = "", shownWind = "", polled = false
        while !Task.isCancelled {
            do {
                let c = try await fetch(lat: lat, lon: lon, fresh: polled)
                polled = true
                let els = Self.frame(c, units: units)
                let temp = Self.fmtTemp(c, units), wind = Self.fmtWind(c, units)
                var fields: [Roll.Field] = []
                if !shownTemp.isEmpty, shownTemp != temp {
                    fields.append(Roll.Field(id: "temp", from: shownTemp, to: temp,
                                             anchor: .right(Self.xRight),
                                             y: Self.yLine1 + DeviceFont.smallInkOffset, color: Self.ink))
                }
                if !shownWind.isEmpty, shownWind != wind {
                    fields.append(Roll.Field(id: "windspd", from: shownWind, to: wind,
                                             anchor: .left(Self.windX),
                                             y: Self.yLine1 + DeviceFont.smallInkOffset, color: Self.windTint))
                }
                shownTemp = temp
                shownWind = wind
                if fields.isEmpty {
                    let code = try await client.draw(app: app, elements: els, priority: 60)
                    status(code == 409 ? "display busy" : Self.statusLine(c, units: units))
                } else {
                    await Roll.play(client: client, app: app, fields: fields,
                                    priority: 60, then: els)
                    status(Self.statusLine(c, units: units))
                }
            } catch {
                // Leave the last reading on the bar; weather does not go stale fast.
                status("open-meteo: \(error.localizedDescription)")
            }
            if !(await barSleep(interval)) { break }
        }
        await client.clear(app: app)
    }

    // MARK: - Data

    /// `fresh: false` for the first fetch of a run, which takes whatever
    /// `WebCache` still holds so a widget coming back draws at once instead of
    /// sitting blank through a round trip.
    func fetch(lat: Double, lon: Double, fresh: Bool) async throws -> Conditions {
        var comps = URLComponents(string: Self.template)!
        comps.queryItems = [
            URLQueryItem(name: "latitude", value: String(lat)),
            URLQueryItem(name: "longitude", value: String(lon)),
            URLQueryItem(name: "current",
                         value: "temperature_2m,weather_code,is_day,uv_index,"
                              + "precipitation_probability,wind_speed_10m,wind_direction_10m"),
            URLQueryItem(name: "timezone", value: "auto"),
        ]
        guard let url = comps.url else { throw WebError.bad }
        let obj = try await fetchJSON(url, userAgent: Self.userAgent, fresh: fresh)
        guard let cur = obj["current"] as? [String: Any] else { throw WebError.bad }
        return Conditions(tempC: Self.num(cur["temperature_2m"]) ?? 0,
                          uv: Self.num(cur["uv_index"]) ?? 0,
                          rainPct: Int(Self.num(cur["precipitation_probability"]) ?? 0),
                          code: Int(Self.num(cur["weather_code"]) ?? 0),
                          isDay: (Self.num(cur["is_day"]) ?? 1) != 0,
                          windKmh: Self.num(cur["wind_speed_10m"]) ?? 0,
                          windDeg: Self.num(cur["wind_direction_10m"]) ?? 0)
    }

    // MARK: - Pure helpers

    /// Always requested in Celsius and converted here, so the unit setting does
    /// not change the request and a cached reading stays valid across a switch.
    static func temp(_ c: Conditions, _ units: Units) -> Double {
        units == .imperial ? c.tempC * 9 / 5 + 32 : c.tempC
    }

    /// "C"/"F" with no degree sign: the bar renders ° perfectly well but rejects
    /// the draw that carries it, because `JSONSerialization` sends raw UTF-8 and
    /// its parser takes ASCII only. One ° blanked this whole widget.
    static func fmtTemp(_ c: Conditions, _ units: Units) -> String {
        "\(Int(temp(c, units).rounded()))\(units == .imperial ? "F" : "C")"
    }

    /// The UV index is a 0-11 scale, so a whole number is the honest precision.
    ///
    /// Lowercase: the device font's capital V reads as a Y at 5px, so "UV 7"
    /// looked like "UY 7" on the bar.
    static func fmtUV(_ uv: Double) -> String { "uv \(Int(uv.rounded()))" }

    static func fmtRain(_ pct: Int) -> String { "rain: \(pct)%" }

    /// m/s in metric, mph in imperial. Open-Meteo answers in km/h either way, so
    /// the conversion happens here and a cached reading survives a unit switch.
    static func windSpeed(_ c: Conditions, _ units: Units) -> Double {
        units == .imperial ? c.windKmh * 0.621371 : c.windKmh / 3.6
    }

    static var windUnit: (Units) -> String { { $0 == .imperial ? "mph" : "m/s" } }

    /// Direction, speed and unit in one element: the font is proportional, so
    /// anything drawn beside the number would have to be repositioned every time
    /// the reading gained or lost a digit.
    ///
    /// Spelled out rather than an arrow — the device rejects the whole draw for
    /// any character above U+00FF, which is what blanked this widget. +180
    /// because open-meteo reports the bearing the wind comes *from*, and naming
    /// where it is going needs no explaining.
    static func fmtWind(_ c: Conditions, _ units: Units) -> String {
        "\(DeviceFont.point(bearing: c.windDeg + 180)) "
            + "\(Int(windSpeed(c, units).rounded()))\(windUnit(units))"
    }

    static func statusLine(_ c: Conditions, units: Units) -> String {
        "\(fmtTemp(c, units))  \(fmtUV(c.uv))  \(fmtRain(c.rainPct))"
            + "  wind \(fmtWind(c, units))"
    }

    static func num(_ v: Any?) -> Double? {
        if let n = v as? NSNumber { return n.doubleValue }
        if let s = v as? String { return Double(s) }
        return nil
    }

    // MARK: - Frame

    static func frame(_ c: Conditions, units: Units) -> [[String: Any]] {
        // Two passes: the cloud (or sun, or moon), then whatever falls out of it.
        let icon = Glyph.weatherIcon(code: c.code, isDay: c.isDay)
        var els = Glyph.els("wx", icon.base, x: iconX, y: iconY,
                            color: icon.baseColor, slots: Glyph.iconSlots)
        els += Glyph.els("wx2", icon.overlay, x: iconX, y: iconY,
                         color: icon.overlayColor, slots: Glyph.overlaySlots)
        els.append(textEl("windspd", fmtWind(c, units), x: windX, y: yLine1,
                          font: "small", color: windTint, align: "top_left"))
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
        // Lowercase, because a 5px capital V reads as a Y.
        assert(fmtUV(0.2) == "uv 0" && fmtUV(7.4) == "uv 7", "whole-number UV")
        assert(!fmtUV(7).contains("V"), "no capital V anywhere in the label")
        assert(fmtRain(0) == "rain: 0%" && fmtRain(100) == "rain: 100%", "labelled rain")
        // Line 2 is "uv N" from x=10 and the rain text flush right; at the widest
        // both must still fit the 72px display without colliding.
        assert(xText + DeviceFont.small.width(fmtUV(11))
                     < 72 - DeviceFont.small.width(fmtRain(100)),
               "the widest uv and rain labels do not overlap")

        // Line 1 carries the wind arrow, the speed, and the temperature flush
        // right; a three-digit gust and a negative temperature must still fit.
        c.windKmh = 120
        assert(fmtWind(c, .metric).hasSuffix("33m/s") && fmtWind(c, .imperial).hasSuffix("75mph"),
               "m/s in metric, mph in imperial, unit shown either way")
        assert(fmtWind(c, .metric).hasPrefix(DeviceFont.point(bearing: c.windDeg + 180)),
               "and the compass point leads, naming where the wind is going")
        assert(fmtWind(c, .metric).allSatisfy { $0.isASCII },
               "nothing above U+00FF, or the device rejects the whole frame")
        var cold = c
        cold.tempC = -12.4
        assert(windX + DeviceFont.small.width(fmtWind(c, .metric))
                     < 72 - DeviceFont.small.width(fmtTemp(cold, .metric)),
               "the widest wind reading clears the widest temperature")
        // Named for where it is going, so it agrees with the arrow the frame draws.
        assert(Self.frame(c, units: .metric).allSatisfy { el in
            (el["text"] as? String ?? "").allSatisfy { $0.unicodeScalars.allSatisfy { $0.value <= 0xFF } }
        }, "every string in the frame is something the device will accept")

        // Code mapping, including the day/night split on clear skies.
        assert(Glyph.weatherIcon(code: 0, isDay: true).base == Glyph.sun, "clear day")
        assert(Glyph.weatherIcon(code: 0, isDay: false).base == Glyph.moon, "clear night")
        assert(Glyph.weatherIcon(code: 3, isDay: true).base == Glyph.cloud, "overcast")
        assert(Glyph.weatherIcon(code: 48, isDay: true).overlay == Glyph.fogLines, "fog")
        assert(Glyph.weatherIcon(code: 71, isDay: true).overlay == Glyph.flakes, "snow")
        assert(Glyph.weatherIcon(code: 99, isDay: true).overlay == Glyph.bolt, "thunderstorm")
        assert(Glyph.weatherIcon(code: 61, isDay: true).overlay == Glyph.drops, "rain")
        assert(Glyph.weatherIcon(code: 81, isDay: true).overlay == Glyph.drops, "showers")

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
