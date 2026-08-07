import SwiftUI

/// A watchlist on the bar: the ticker at full height on the left, the price and
/// the day's change stacked on the right. Quotes come from Yahoo's chart
/// endpoint, which needs no key. Note it is unofficial — a widget that stops
/// working is the first thing to suspect if Yahoo changes it.
final class StocksApp: MiniApp {
    let app = "stocks"

    static let quoteTemplate =
        "https://query1.finance.yahoo.com/v8/finance/chart/%@?interval=1d&range=1d"
    // Yahoo answers a bare URLSession user agent with 429 often enough to matter.
    static let userAgent = "Mozilla/5.0 (Macintosh) busybar-stocks/1.0"

    static let ink = "#FFFFFFFF"
    static let dim = "#7A7A7AFF"
    static let up = "#22DD44FF"
    static let down = "#FF3322FF"
    /// Market closed: direction is stale, so the arrow says so by going grey.
    static let shut = "#888888FF"

    // Same two-line geometry as Flightradar: the small font's ink sits ~2px below
    // its nominal y, and the font's 1px right bearing means x=73 lands flush.
    static let yLine1 = 0
    static let yLine2 = 8
    static let xRight = 73
    /// The ticker is vertically centred on the whole 16px height, so it reads as
    /// the headline and the price column as the detail.
    static let symbolY = 8
    /// Gap between the ticker and the price column.
    static let gap = 2

    /// Fonts the ticker can use, tallest first. `extra_large` is the 7px face at
    /// double size — 14 rows of 2px-thick strokes, the full height of the bar —
    /// and `bold` keeps the thick strokes when only 7 rows will fit.
    static let symbolFonts: [DeviceFont] = [.extraLarge, .large, .bold, .normal, .small]

    struct Quote {
        var symbol = "", price = 0.0, prevClose = 0.0
        var marketOpen = false
        /// ISO code from the quote — the same ticker is priced in dollars on one
        /// exchange and euros on another, so it is not something to assume.
        var currency = ""
    }

    // MARK: - Main loop

    func run(client: BarClient, status: @escaping @Sendable (String) -> Void) async {
        let d = UserDefaults.standard
        let symbols = Self.parseSymbols(d.string(forKey: "stocks.symbols") ?? "AAPL")
        let refresh = max(5, d.object(forKey: "stocks.refresh") as? Double ?? 60)
        let flip = max(1, d.object(forKey: "stocks.flip") as? Double ?? 4)

        // Refetched per symbol only when its own entry has gone stale, so one
        // loop drives both the flipping and the polling.
        var cache: [String: (quote: Quote, at: Double)] = [:]
        var tick = 0, polled = false
        /// What the bar is showing, so a moved number can roll to the new one.
        var shown: (symbol: String, price: String, pct: String)?

        while !Task.isCancelled {
            guard !symbols.isEmpty else {
                status("add symbols in settings")
                if !(await barSleep(flip)) { break }
                continue
            }
            let symbol = symbols[tick % symbols.count]
            let now = Date().timeIntervalSince1970

            if cache[symbol].map({ now - $0.at > refresh }) ?? true {
                do {
                    cache[symbol] = (try await fetchQuote(symbol, fresh: polled), now)
                    polled = true
                } catch {
                    // Keep whatever is on the bar; a stale price beats a blank.
                    status("\(symbol): \(Self.describe(error))")
                }
            }

            if let q = cache[symbol]?.quote {
                let priceText = Self.priceText(q)
                let pctText = Self.fmtPct(Self.pctChange(price: q.price, prevClose: q.prevClose))
                let els = Self.frame(q)
                // Only the same symbol's own numbers roll: flipping AAPL to MSFT
                // is a new subject, not a value that moved.
                var fields: [Roll.Field] = []
                if shown?.symbol == symbol, let was = shown {
                    if was.price != priceText {
                        fields.append(Roll.Field(id: "price", from: was.price, to: priceText,
                                                 anchor: .right(Self.xRight),
                                                 y: Self.yLine1 + DeviceFont.smallInkOffset,
                                                 color: Self.ink))
                    }
                    if was.pct != pctText {
                        fields.append(Roll.Field(id: "pct", from: was.pct, to: pctText,
                                                 anchor: .right(Self.xRight),
                                                 y: Self.yLine2 + DeviceFont.smallInkOffset,
                                                 color: Self.color(q)))
                    }
                }
                shown = (symbol, priceText, pctText)
                if fields.isEmpty {
                    do {
                        let code = try await client.draw(app: app, elements: els)
                        status(code == 409 ? "paused — bar in use" : Self.statusLine(q))
                    } catch {
                        status("draw error: \(error.localizedDescription)")
                    }
                } else {
                    await Roll.play(client: client, app: app, fields: fields,
                                    then: els)
                    status(Self.statusLine(q))
                }
            }

            tick += 1
            if !(await barSleep(flip)) { break }
        }
        await client.clear(app: app)
    }

    // MARK: - Data

    /// `fresh: false` for the first quote of a run: `WebCache` still has the
    /// last answer, so a widget coming back draws at once.
    func fetchQuote(_ symbol: String, fresh: Bool) async throws -> Quote {
        let enc = symbol.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? symbol
        guard let url = URL(string: String(format: Self.quoteTemplate, enc)) else {
            throw WebError.bad
        }
        let obj = try await fetchJSON(url, userAgent: Self.userAgent, fresh: fresh)
        guard let result = ((obj["chart"] as? [String: Any])?["result"] as? [[String: Any]])?.first,
              let meta = result["meta"] as? [String: Any],
              let price = Self.num(meta["regularMarketPrice"]) else { throw WebError.bad }

        // This endpoint carries chartPreviousClose, not previousClose.
        let prev = Self.num(meta["chartPreviousClose"]) ?? price
        let regular = (meta["currentTradingPeriod"] as? [String: Any])?["regular"] as? [String: Any]
        let open = Self.isOpen(now: Date().timeIntervalSince1970,
                              start: Self.num(regular?["start"]),
                              end: Self.num(regular?["end"]))
        return Quote(symbol: symbol, price: price, prevClose: prev, marketOpen: open,
                     currency: meta["currency"] as? String ?? "")
    }

    // MARK: - Pure helpers

    static func parseSymbols(_ raw: String) -> [String] {
        raw.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() }
            .filter { !$0.isEmpty }
    }

    /// There is no marketState field on this endpoint; the regular trading window
    /// is in epoch seconds, so no timezone maths — and it is per-exchange, which
    /// beats assuming NYSE hours.
    static func isOpen(now: Double, start: Double?, end: Double?) -> Bool {
        guard let start, let end else { return false }
        return now >= start && now < end
    }

    static func pctChange(price: Double, prevClose: Double) -> Double {
        guard prevClose != 0 else { return 0 }
        return (price - prevClose) / prevClose * 100
    }

    /// No decimals past a thousand: a tenth of a dollar on a $1704 share is noise,
    /// and those four pixels are what let a four-letter ticker keep the tall face.
    static func fmtPrice(_ v: Double) -> String {
        String(format: v >= 1000 ? "%.0f" : "%.2f", v)
    }

    /// What goes in front of the price. "$" where a currency uses one, otherwise
    /// the ISO code: the bar throws away any frame containing a character it does
    /// not have, and "€" is not one this app has ever been able to test on the
    /// device. A wide "EUR" beats a widget that goes black.
    static func currencyMark(_ code: String) -> String {
        switch code.uppercased() {
        case "": return ""
        case "USD", "CAD", "AUD", "NZD", "HKD", "SGD", "TWD", "MXN": return "$"
        default: return code.uppercased()
        }
    }

    static func priceText(_ q: Quote) -> String {
        currencyMark(q.currency) + fmtPrice(q.price)
    }

    /// Sign and number in one element. The font does carry an up arrow, but at
    /// five pixels tall its head and shaft merge into something that reads as a
    /// plus, so "+" and "-" — which is what it looked like anyway — say it
    /// plainly. Direction is also in the colour.
    ///
    /// One decimal, not two: the second one cost 4px, and 4px is the difference
    /// between a four-letter ticker in the 14-row face and in the 11-row one.
    static func fmtPct(_ pct: Double) -> String {
        String(format: "%@%.1f%%", pct < 0 ? "-" : "+", abs(pct))
    }

    /// Width the price column needs: the price above, the arrow and percentage
    /// below, whichever is wider.
    static func rightWidth(price: String, pct: String) -> Int {
        max(DeviceFont.small.width(price), DeviceFont.small.width(pct))
    }

    /// The tallest font the ticker fits in without eating into the price column.
    ///
    /// Both measurements matter to the pixel: the price column is right-aligned at
    /// `xRight`, so its ink starts at `xRight - width`, and the ticker's ink stops
    /// a bearing short of its own advance. Getting either wrong by one costs a
    /// whole font step — ASML wants 48px of ink and has 50.
    static func symbolFont(_ symbol: String, price: String, pct: String) -> DeviceFont {
        let budget = xRight - rightWidth(price: price, pct: pct) - gap
        return symbolFonts.first { $0.inkWidth(symbol) <= budget } ?? .small
    }

    static func color(_ q: Quote) -> String {
        guard q.marketOpen else { return shut }
        let pct = pctChange(price: q.price, prevClose: q.prevClose)
        return pct < 0 ? down : up
    }

    static func statusLine(_ q: Quote) -> String {
        let pct = pctChange(price: q.price, prevClose: q.prevClose)
        return "\(q.symbol)  \(priceText(q))  \(fmtPct(pct))"
            + (q.marketOpen ? "" : "  (closed)")
    }

    static func describe(_ error: Error) -> String {
        switch error {
        case WebError.notFound: return "no such symbol"
        case WebError.http(let c): return "HTTP \(c)"
        case WebError.bad: return "unexpected response"
        default: return error.localizedDescription
        }
    }

    static func num(_ v: Any?) -> Double? {
        if let n = v as? NSNumber { return n.doubleValue }
        if let s = v as? String { return Double(s) }
        return nil
    }

    // MARK: - Frame

    static func frame(_ q: Quote) -> [[String: Any]] {
        let pct = pctChange(price: q.price, prevClose: q.prevClose)
        let tint = color(q)
        let priceText = Self.priceText(q), pctText = fmtPct(pct)
        var els: [[String: Any]] = [
            // Full height on the left, in the largest font the price column can
            // spare — a four-letter ticker gets the 2px-thick 14-row face.
            textEl("sym", q.symbol, x: 0, y: symbolY,
                   font: symbolFont(q.symbol, price: priceText, pct: pctText).api,
                   color: ink, align: "mid_left"),
            textEl("price", priceText, x: xRight, y: yLine1, font: "small",
                   color: ink, align: "top_right"),
        ]
        // Arrow and percentage are one right-aligned element under the price.
        // Grey is the closed-market signal, so nothing else marks it.
        els.append(textEl("pct", pctText, x: xRight, y: yLine2, font: "small",
                          color: tint, align: "top_right"))
        return els
    }

    #if DEBUG
    static func selfCheck() {
        assert(parseSymbols(" aapl , msft ,, ") == ["AAPL", "MSFT"],
               "symbols trimmed, upcased, blanks dropped")
        assert(parseSymbols("") == [], "no symbols means no rotation")

        // 312.24 against a 311.00 close is +0.40%.
        let pct = pctChange(price: 312.24, prevClose: 311.0)
        assert(abs(pct - 0.3987) < 0.001, "day change percentage")
        assert(fmtPct(pct) == "+0.4%", "signed, one decimal")
        assert(fmtPct(-12.345) == "-12.3%", "and the sign is a sign")
        assert(pctChange(price: 10, prevClose: 0) == 0, "a zero close cannot divide")

        // The real window from the endpoint: 1786023000...1786046400.
        assert(isOpen(now: 1786044753, start: 1786023000, end: 1786046400), "inside")
        assert(!isOpen(now: 1786050000, start: 1786023000, end: 1786046400), "after close")
        assert(!isOpen(now: 1786010000, start: 1786023000, end: 1786046400), "before open")
        assert(!isOpen(now: 1786044753, start: nil, end: nil), "no window means closed")

        // Closed beats direction: grey either way.
        assert(color(Quote(price: 2, prevClose: 1, marketOpen: true)) == up, "up green")
        assert(color(Quote(price: 1, prevClose: 2, marketOpen: true)) == down, "down red")
        assert(color(Quote(price: 2, prevClose: 1, marketOpen: false)) == shut, "closed grey")

        assert(fmtPrice(312.244) == "312.24" && fmtPrice(1704.37) == "1704",
               "cents under a thousand, whole units above it")
        assert(currencyMark("USD") == "$" && currencyMark("usd") == "$", "dollars get a sign")
        assert(currencyMark("EUR") == "EUR" && currencyMark("GBp") == "GBP",
               "everything else gets its code, because the sign may not be drawable")
        assert(currencyMark("") == "", "an unknown currency adds nothing")
        assert(priceText(Quote(price: 1704.37, currency: "USD")) == "$1704", "the shape on the bar")
        assert(priceText(Quote(price: 312.41, currency: "")).allSatisfy { $0.isASCII },
               "and it is always ASCII")

        // The ticker takes the tallest font that leaves the price column intact.
        assert(symbolFont("F", price: "$312.24", pct: fmtPct(0.4)) == .extraLarge,
               "a one-letter ticker can be as tall as the bar")
        assert(symbolFont("AAPL", price: "$312.41", pct: fmtPct(0.4)) == .extraLarge,
               "and so can four letters — what the second decimal was spent on")
        // The one that started this: 48px of ink against a 52px budget.
        assert(symbolFont("ASML", price: priceText(Quote(price: 1704.37, currency: "USD")),
                          pct: fmtPct(1.56)) == .extraLarge,
               "ASML is 48px of ink and fits, which counting advances said it did not")
        assert(symbolFont("MSFT", price: "$312.41", pct: fmtPct(0.4)) == .large,
               "an M is 16px in the tall face, so a wider four-letter ticker steps down")
        assert(symbolFont(String(repeating: "X", count: 14), price: "9.99", pct: fmtPct(0.4)) == .small,
               "an absurd ticker falls back to the small font rather than overflowing")
        // Whatever font is chosen, the ticker's ink must stop before the price
        // column's ink starts, with the gap between them.
        for sym in ["F", "AAPL", "MSFT", "ASML", "^GSPC", "BRK-B"] {
            for price in ["$312.41", "$1704", "EUR650.00"] {
                let pct = fmtPct(-12.3)
                let f = symbolFont(sym, price: price, pct: pct)
                assert(f.inkWidth(sym) + gap <= xRight - rightWidth(price: price, pct: pct),
                       "\(sym) in \(f.api) runs into \(price)")
            }
        }
    }
    #endif
}

struct StocksSettingsView: View {
    @AppStorage("stocks.symbols") private var symbols = "AAPL"
    @AppStorage("stocks.refresh") private var refresh = 60.0
    @AppStorage("stocks.flip") private var flip = 4.0

    var body: some View {
        Form {
            TextField("Symbols", text: $symbols, prompt: Text("AAPL, MSFT, ^GSPC"))
            TextField("Refresh quotes every (s)", value: $refresh, format: .number)
            TextField("Change symbol every (s)", value: $flip, format: .number)
            Text("Comma-separated. Arrow is green up, red down, grey while that symbol's exchange is closed.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(width: 280)
    }
}
