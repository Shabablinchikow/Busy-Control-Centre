import Foundation

/// Character advances for the fonts the bar draws with, so layout maths is
/// measured instead of guessed.
///
/// The bar's fonts are **proportional**. In `small` a digit advances 4px, but
/// "." advances 2 and "M" advances 6 — so placing an element at `count * 4`
/// lands on top of the text in front of it, which is exactly how the flight
/// route's ">" ended up on top of its origin.
///
/// Measured from the firmware's own TTFs (`assets/shared/fonts/ttf`) at the ppem
/// its `convert_all.sh` bakes them at: 16px for everything here, except
/// `extra_large`, which is the 7px face baked at 32px — every stroke doubled,
/// which is where the chunky 2px-thick capitals come from. Metrics only: no
/// glyph data is copied, and could not be — the firmware is GPLv2 and this app
/// is MIT.
enum DeviceFont: String {
    case small, normal, condensed, bold, large
    case extraLarge = "extra_large"

    /// What the draw API wants in `font`.
    var api: String { rawValue }

    /// Advance of one character. Anything the tables do not cover falls back to
    /// the digit width, which is the best guess available and never zero.
    func advance(_ ch: Character) -> Int {
        // extra_large is the normal face at double size, so it is double
        // throughout rather than a table of its own.
        if self == .extraLarge { return 2 * DeviceFont.normal.advance(ch) }
        guard let ascii = ch.asciiValue, ascii >= 32, ascii <= 126 else {
            return Self.digitWidth[self] ?? 4
        }
        let table = Self.table[self] ?? Self.tableSmall
        let i = table.index(table.startIndex, offsetBy: Int(ascii) - 32)
        return Int(table[i].asciiValue! - 48)
    }

    func width(_ s: String) -> Int { s.reduce(0) { $0 + advance($1) } }

    /// Rows between a `top_*` element's nominal y and its first row of ink.
    /// Established on the bar for `small`; the others are not used for anything
    /// that needs pixel alignment yet.
    static let smallInkOffset = 2

    // MARK: - Measured tables (ASCII 32...126, advance encoded as '0' + px)

    static let tableSmall =
        "224645523344232343444444442344445555555552454655" +
        "55554546444333445444443442342644443434464444245"
    static let tableNormal =
        "534668723346344566666666662346468666666664565866" +
        "66666668666353655555555554454655554555666554346"
    static let tableCondensed =
        "534668723346344555555555552346468666666664565866" +
        "66666668666353655555555554454655554555666554346"
    static let tableBold =
        "54489982444734467777777777235757:777766775676:87" +
        "7777778;777464755666666665565866665666787665456"
    static let tableLarge =
        "63498:92446634467577777777235656:877877884777:88" +
        "7877888:8873636656666656644648666656566:6664248"

    static let table: [DeviceFont: String] = [
        .small: tableSmall, .normal: tableNormal, .condensed: tableCondensed,
        .bold: tableBold, .large: tableLarge,
    ]
    static let digitWidth: [DeviceFont: Int] = [
        .small: 4, .normal: 6, .condensed: 5, .bold: 7, .large: 7, .extraLarge: 12,
    ]

    /// The compass points, clockwise from north. The TTFs do contain arrow
    /// glyphs, but the device rejects the whole draw with HTTP 400 for any
    /// character above U+00FF — measured — so directions are spelled out.
    static let compass = ["N", "NE", "E", "SE", "S", "SW", "W", "NW"]

    static func point(bearing: Double) -> String {
        let i = Int((bearing.truncatingRemainder(dividingBy: 360) / 45).rounded())
        return compass[((i % 8) + 8) % 8]
    }

    #if DEBUG
    static func selfCheck() {
        // The measurements this whole file exists for.
        assert(DeviceFont.small.advance("0") == 4, "small digits advance 4")
        assert(DeviceFont.small.advance(".") == 2, "but a full stop is only 2")
        assert(DeviceFont.small.advance("M") == 6 && DeviceFont.small.advance("I") == 2,
               "small is proportional, which is the point")
        assert(DeviceFont.small.width("AMS") == 16, "not 12 — this is the route bug")
        assert(DeviceFont.small.width("42.3%") == 19, "a percentage is narrower than 5 cells")
        assert(DeviceFont.small.width("312.24") == 21 && DeviceFont.small.width("AAPL") == 19,
               "the two readings the stocks layout is built around")

        // extra_large is the normal face doubled, so it must measure double.
        for ch in "AAPL 0123456789.%" {
            assert(DeviceFont.extraLarge.advance(ch) == 2 * DeviceFont.normal.advance(ch),
                   "\(ch) doubles")
        }
        assert(DeviceFont.extraLarge.width("AAPL") == 46, "the widest ticker that fits")
        assert(DeviceFont.large.width("MSFT") == 32, "and the one that has to step down")
        assert(DeviceFont.bold.width("AAPL") == 27, "bold keeps 2px strokes at 7px tall")

        // Every table covers the printable range and nothing reads as zero.
        for f in [DeviceFont.small, .normal, .condensed, .bold, .large, .extraLarge] {
            assert((32...126).allSatisfy { f.advance(Character(UnicodeScalar($0)!)) > 0 },
                   "\(f.api) advances every printable character")
            assert(f.advance("→") > 0, "and answers for characters it has never seen")
        }
        assert(tableSmall.count == 95 && tableLarge.count == 95, "95 printable characters")

        // Nothing but ASCII survives the trip, so the compass is spelled out and
        // the degree sign is gone.
        assert(point(bearing: 0) == "N" && point(bearing: 90) == "E"
                 && point(bearing: 180) == "S" && point(bearing: 270) == "W", "cardinals")
        assert(point(bearing: 45) == "NE" && point(bearing: 225) == "SW", "diagonals")
        assert(point(bearing: 359) == "N" && point(bearing: 360) == "N", "north wraps")
        assert(point(bearing: -90) == "W", "a negative bearing still lands somewhere")
        assert(point(bearing: 22) == "N" && point(bearing: 23) == "NE", "45 degree buckets")

        // Anything the device cannot take is replaced before it is sent — one
        // stray character and the whole frame is rejected.
        assert(deviceSafe("↗33m/s") == ">33m/s", "an arrow becomes a chevron")
        assert(deviceSafe("19°C") == "19°C", "a degree sign the bar accepts is left alone")
        assert(deviceSafe("Ролевка") == "Ролевка", "and so is a Cyrillic channel name")
        assert(deviceSafe("Long title…") == "Long title..", "an ellipsis becomes dots")
        assert(deviceSafe("plain") == "plain", "ASCII is left alone")
        assert(deviceSafe("naïve — 5µs") == "naïve - 5µs", "only the em dash is swapped")
    }
    #endif
}
