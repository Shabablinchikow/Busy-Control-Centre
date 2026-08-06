import Foundation

/// Tiny bitmaps drawn as rectangle elements. `#` is ink, any other character is
/// blank. Used for the stock arrows and the weather icons, neither of which can
/// come from the device font.
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

    // MARK: - Stock arrows

    /// Shaft from the far corner, head as the right angle on the right.
    static let arrowDown = ["#   #",
                           " #  #",
                           "  # #",
                           "   ##",
                           "#####"]

    /// The down arrow mirrored top-to-bottom.
    static let arrowUp = arrowDown.reversed().map { $0 }

    static let arrowSlots = 8

    // MARK: - Weather icons (8x8)

    static let sun = ["   ##   ",
                      "#  ##  #",
                      " ###### ",
                      " ###### ",
                      "########",
                      " ###### ",
                      "#  ##  #",
                      "   ##   "]

    static let moon = ["  ####  ",
                      " ###    ",
                      "###     ",
                      "###     ",
                      "###     ",
                      "###     ",
                      " ###    ",
                      "  ####  "]

    static let cloud = ["        ",
                        "  ####  ",
                        " ###### ",
                        "########",
                        "########",
                        " ###### ",
                        "        ",
                        "        "]

    static let fog = ["        ",
                      " ###### ",
                      "        ",
                      "########",
                      "        ",
                      " ###### ",
                      "        ",
                      "########"]

    static let rain = ["  ####  ",
                       " ###### ",
                       "########",
                       " ###### ",
                       "        ",
                       " #  #  #",
                       "#  #  # ",
                       " #  #  #"]

    static let snow = ["  ####  ",
                       " ###### ",
                       "########",
                       " ###### ",
                       "        ",
                       " #  #  #",
                       "  #  #  ",
                       " #  #  #"]

    static let storm = ["  ####  ",
                        " ###### ",
                        "########",
                        " ###### ",
                        "   ###  ",
                        "  ###   ",
                        "   #    ",
                        "  #     "]

    /// Enough slots for the busiest icon above (fog, 4 rows x 1 run + rain's
    /// dotted rows at 3 runs each).
    static let iconSlots = 20

    /// WMO weather code to icon. Codes from open-meteo's documented table.
    static func weatherIcon(code: Int, isDay: Bool) -> [String] {
        switch code {
        case 0:            return isDay ? sun : moon
        case 1, 2, 3:      return cloud
        case 45, 48:       return fog
        case 71...77, 85, 86: return snow
        case 95...99:      return storm
        default:           return rain   // 51-67 drizzle/rain, 80-82 showers
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

        // The up arrow is the down arrow's row-reverse.
        assert(arrowUp == arrowDown.reversed().map { $0 }, "up is down mirrored")
        assert(arrowUp.first == "#####" && arrowDown.last == "#####",
               "the solid row swaps ends")

        // Fixed slot count, so a smaller glyph cannot leave the old one behind.
        let wide = els("g", rain, x: 0, y: 0, color: "#FFFFFFFF", slots: iconSlots)
        let thin = els("g", sun, x: 0, y: 0, color: "#FFFFFFFF", slots: iconSlots)
        assert(wide.count == iconSlots && thin.count == iconSlots,
               "every glyph emits exactly iconSlots elements")
        assert(runs(rain).count <= iconSlots && runs(storm).count <= iconSlots,
               "iconSlots covers the busiest icon")
        assert(runs(arrowUp).count <= arrowSlots, "arrowSlots covers the arrows")
    }
    #endif
}
