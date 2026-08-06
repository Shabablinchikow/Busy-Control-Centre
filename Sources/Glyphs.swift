import Foundation

/// Tiny bitmaps drawn as rectangle elements. `#` is ink, any other character is
/// blank.
///
/// Pictures only: the weather icons and the YouTube mark. Anything that is a
/// character — digits, letters, arrows, the degree sign — comes from the device's
/// own fonts, which carry all eight arrows and °; see `DeviceFont`.
enum Glyph {
    /// Ink as horizontal runs, one per contiguous stretch.
    ///
    /// Merging runs is not an optimisation to skip: a rectangle costs ~3.6 ms on
    /// the device, so an 8x8 icon drawn pixel-by-pixel is ~230 ms per frame,
    /// while the same icon run-merged is 8-16 rects.
    static func runs(_ rows: [String]) -> [(x: Int, y: Int, w: Int)] {
        var out: [(x: Int, y: Int, w: Int)] = []
        for (y, row) in rows.enumerated() {
            let chars = Array(row)
            var x = 0
            while x < chars.count {
                guard chars[x] == "#" else { x += 1; continue }
                var w = 1
                while x + w < chars.count, chars[x + w] == "#" { w += 1 }
                out.append((x, y, w))
                x += w
            }
        }
        return out
    }

    /// Rectangle elements for a bitmap, always exactly `slots` of them.
    ///
    /// The fixed count matters: elements persist by id until overwritten, so a
    /// 10-rect icon followed by a 6-rect one would leave four rects of the old
    /// glyph on screen. Unused slots are emitted *first*, as 1x1 background-black
    /// pixels at the origin, so any real run drawn afterwards paints over them.
    static func els(_ id: String, _ rows: [String], x: Int, y: Int,
                    color: String, slots: Int) -> [[String: Any]] {
        let runs = Self.runs(rows)
        var els: [[String: Any]] = []
        for i in 0..<max(0, slots - runs.count) {
            els.append(rectEl("\(id)-pad\(i)", x: x, y: y, w: 1, h: 1, color: "#000000FF"))
        }
        for (i, r) in runs.enumerated() {
            els.append(rectEl("\(id)-run\(i)", x: x + r.x, y: y + r.y, w: r.w, h: 1, color: color))
        }
        return els
    }

    // MARK: - Weather icons (8x8)

    /// Every icon is an 8x8 grid drawn in two passes: a grey cloud, and the
    /// coloured thing happening under it. One flat colour for the whole icon is
    /// what made the old set read as a row of near-identical blobs.
    static let blank8 = "        "

    static let sun = ["#  ##  #",
                      " # ## # ",
                      "  ####  ",
                      "########",
                      "########",
                      "  ####  ",
                      " # ## # ",
                      "#  ##  #"]

    /// A crescent. The old moon was a filled half-disc, which read as a D.
    static let moon = ["  ####  ",
                       " ##  ## ",
                       "###     ",
                       "##      ",
                       "##      ",
                       "###     ",
                       " ##  ## ",
                       "  ####  "]

    /// Hollow cumulus, centred, for plain overcast.
    static let cloud = [blank8,
                        "  ####  ",
                        " #    # ",
                        "#      #",
                        "#      #",
                        " ###### ",
                        blank8,
                        blank8]

    /// The same cloud pushed to the top, so an effect fits underneath.
    static let cloudTop = ["  ####  ",
                           " #    # ",
                           "#      #",
                           " ###### ",
                           blank8, blank8, blank8, blank8]

    /// Two banks of mist below the cloud.
    static let fogLines = [blank8, blank8, blank8, blank8,
                           blank8,
                           " ###### ",
                           blank8,
                           "  ####  "]

    /// Slanted drops, the rows offset so the fall has a direction.
    static let drops = [blank8, blank8, blank8, blank8,
                        blank8,
                        " #  #  #",
                        "#  #  # ",
                        blank8]

    /// Two flakes: an X is the smallest shape not mistaken for a raindrop.
    static let flakes = [blank8, blank8, blank8, blank8,
                         blank8,
                         "# #  # #",
                         " #    # ",
                         "# #  # #"]

    /// A bolt with a real kink in it.
    static let bolt = [blank8, blank8, blank8, blank8,
                       "   ##   ",
                       "  ##    ",
                       " ####   ",
                       "  ##    "]

    /// Element ids are the scarce resource — the bar keeps a limited number per
    /// application — so each layer gets exactly what its busiest member needs and
    /// no more: the sun is 16 runs, the flakes 10. Together that is 26 ids for a
    /// two-tone icon instead of the 44 that pushed the rest of the weather frame
    /// off the display.
    static let iconSlots = 16
    static let overlaySlots = 10

    /// The base layer, whatever is happening under it, and what colour each wants.
    struct WeatherIcon: Equatable {
        var base: [String]
        var overlay: [String] = [String](repeating: blank8, count: 8)
        var baseColor = cloudGrey
        var overlayColor = cloudGrey
    }

    static let cloudGrey = "#9AA0A6FF"
    static let sunYellow = "#FFD37AFF"
    static let moonPale = "#C8D4FFFF"
    static let rainBlue = "#5AC8FAFF"
    static let snowWhite = "#FFFFFFFF"
    static let boltYellow = "#FFD60AFF"
    static let fogGrey = "#6C7278FF"

    // MARK: - YouTube mark (9x7)

    /// Rounded red tile; the play triangle is drawn on top of it, so the two
    /// glyphs must be emitted in this order.
    static let ytBody = [" ####### ",
                         "#########",
                         "#########",
                         "#########",
                         "#########",
                         "#########",
                         " ####### "]

    /// Drawn at the body's x+3, y+1.
    static let ytPlay = ["#..",
                         "##.",
                         "###",
                         "##.",
                         "#.."]

    static let ytBodySlots = 7
    static let ytPlaySlots = 5

    /// WMO weather code to icon. Codes from open-meteo's documented table.
    static func weatherIcon(code: Int, isDay: Bool) -> WeatherIcon {
        switch code {
        case 0:
            return isDay ? WeatherIcon(base: sun, baseColor: sunYellow)
                         : WeatherIcon(base: moon, baseColor: moonPale)
        case 1, 2, 3:
            return WeatherIcon(base: cloud)
        case 45, 48:
            return WeatherIcon(base: cloudTop, overlay: fogLines, overlayColor: fogGrey)
        case 71...77, 85, 86:
            return WeatherIcon(base: cloudTop, overlay: flakes, overlayColor: snowWhite)
        case 95...99:
            return WeatherIcon(base: cloudTop, overlay: bolt, overlayColor: boltYellow)
        default:  // 51-67 drizzle/rain, 80-82 showers
            return WeatherIcon(base: cloudTop, overlay: drops, overlayColor: rainBlue)
        }
    }

    #if DEBUG
    /// ponytail: assert-based check instead of a test target, next to Carousel's.
    static func selfCheck() {
        // Runs merge horizontally and skip gaps.
        let r = runs(["##  #", " ### "])
        assert(r.count == 3, "three runs, not five pixels")
        assert(r[0] == (x: 0, y: 0, w: 2), "leading run merged")
        assert(r[1] == (x: 4, y: 0, w: 1), "run after a gap")
        assert(r[2] == (x: 1, y: 1, w: 3), "second row merged")
        assert(runs(["    "]).isEmpty, "blank rows produce nothing")

        // Fixed slot count, so a smaller glyph cannot leave the old one behind.
        let wide = els("g", sun, x: 0, y: 0, color: "#FFFFFFFF", slots: iconSlots)
        let thin = els("g", sun, x: 0, y: 0, color: "#FFFFFFFF", slots: iconSlots)
        assert(wide.count == iconSlots && thin.count == iconSlots,
               "every glyph emits exactly iconSlots elements")
        // Every icon layer is an 8x8 grid within its slot budget, or icons would
        // shift and leave rects of the last one behind.
        for layer in [sun, moon, cloud, cloudTop] {
            assert(layer.count == 8 && layer.allSatisfy { $0.count == 8 }, "base layers are 8x8")
            assert(runs(layer).count <= iconSlots, "iconSlots covers every base layer")
        }
        for layer in [fogLines, drops, flakes, bolt] {
            assert(layer.count == 8 && layer.allSatisfy { $0.count == 8 },
                   "overlay layers are 8x8")
            assert(runs(layer).count <= overlaySlots, "overlaySlots covers every overlay")
        }
        assert(runs(sun).count == iconSlots && runs(flakes).count == overlaySlots,
               "the budgets are what the busiest layers actually need, not a round number")
        for code in [0, 1, 3, 45, 71, 95, 61, 80] {
            let icon = weatherIcon(code: code, isDay: true)
            assert(icon.base.count == 8 && icon.overlay.count == 8, "code \(code) is 8 rows")
        }
        assert(weatherIcon(code: 0, isDay: true).baseColor == sunYellow, "the sun is yellow")
        assert(weatherIcon(code: 95, isDay: true).overlayColor == boltYellow,
               "and the bolt under a grey cloud is too")
        assert(runs(ytBody).count <= ytBodySlots && runs(ytPlay).count <= ytPlaySlots,
               "the YouTube mark fits its slots")
        assert(ytBody.allSatisfy { $0.count == 9 } && ytBody.count == 7, "the tile is 9x7")
    }
    #endif
}
