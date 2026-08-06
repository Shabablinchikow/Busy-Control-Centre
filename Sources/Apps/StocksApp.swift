import SwiftUI

/// A watchlist on the bar: symbol and price on the top line, an arrow and the
/// day's change underneath. Quotes come from Yahoo's chart endpoint, which needs
/// no key. Note it is unofficial — a widget that stops working is the first thing
/// to suspect if Yahoo changes it.
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
    /// The 5px arrow, aligned with line 2's ink rows (10-14).
    static let arrowY = 10
    /// Advance per character in the device's 5px font.
    static let charW = 4

    struct Quote {
        var symbol = "", price = 0.0, prevClose = 0.0
        var marketOpen = false
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
        var tick = 0

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
                    cache[symbol] = (try await fetchQuote(symbol), now)
                } catch {
                    // Keep whatever is on the bar; a stale price beats a blank.
                    status("\(symbol): \(Self.describe(error))")
                }
            }

            if let q = cache[symbol]?.quote {
                do {
                    let code = try await client.draw(app: app, elements: Self.frame(q),
                                                     priority: 60)
                    status(code == 409 ? "display busy" : Self.statusLine(q))
                } catch {
                    status("draw error: \(error.localizedDescription)")
                }
            }

            tick += 1
            if !(await barSleep(flip)) { break }
        }
        await client.clear(app: app)
    }

    // MARK: - Data

    func fetchQuote(_ symbol: String) async throws -> Quote {
        let enc = symbol.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? symbol
        guard let url = URL(string: String(format: Self.quoteTemplate, enc)) else {
            throw WebError.bad
        }
        let obj = try await fetchJSON(url, userAgent: Self.userAgent)
        guard let result = ((obj["chart"] as? [String: Any])?["result"] as? [[String: Any]])?.first,
              let meta = result["meta"] as? [String: Any],
              let price = Self.num(meta["regularMarketPrice"]) else { throw WebError.bad }

        // This endpoint carries chartPreviousClose, not previousClose.
        let prev = Self.num(meta["chartPreviousClose"]) ?? price
        let regular = (meta["currentTradingPeriod"] as? [String: Any])?["regular"] as? [String: Any]
        let open = Self.isOpen(now: Date().timeIntervalSince1970,
                              start: Self.num(regular?["start"]),
                              end: Self.num(regular?["end"]))
        return Quote(symbol: symbol, price: price, prevClose: prev, marketOpen: open)
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

    static func fmtPrice(_ v: Double) -> String {
        String(format: v >= 1000 ? "%.1f" : "%.2f", v)
    }

    /// The arrow carries the direction, so the number itself is unsigned.
    static func fmtPct(_ pct: Double) -> String {
        String(format: "%.2f%%", abs(pct))
    }

    /// Left edge of the arrow, so it sits just clear of the right-aligned
    /// percentage underneath the price. Right-aligned text ends flush at x=72.
    static func arrowX(pct text: String) -> Int {
        max(0, 72 - text.count * charW - 2 - 5)
    }

    static func color(_ q: Quote) -> String {
        guard q.marketOpen else { return shut }
        let pct = pctChange(price: q.price, prevClose: q.prevClose)
        return pct < 0 ? down : up
    }

    static func statusLine(_ q: Quote) -> String {
        let pct = pctChange(price: q.price, prevClose: q.prevClose)
        let sign = pct < 0 ? "−" : "+"
        return "\(q.symbol)  \(fmtPrice(q.price))  \(sign)\(fmtPct(pct))"
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
        var els: [[String: Any]] = [
            textEl("sym", q.symbol, x: 0, y: yLine1, font: "small",
                   color: ink, align: "top_left"),
            textEl("price", fmtPrice(q.price), x: xRight, y: yLine1, font: "small",
                   color: ink, align: "top_right"),
        ]
        // Arrow and percentage sit at the right, under the price. The grey arrow
        // is the closed-market signal, so nothing else marks it.
        let pctText = fmtPct(pct)
        els += Glyph.els("arrow", pct < 0 ? Glyph.arrowDown : Glyph.arrowUp,
                         x: arrowX(pct: pctText), y: arrowY, color: tint,
                         slots: Glyph.arrowSlots)
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
        assert(fmtPct(pct) == "0.40%", "unsigned, two decimals")
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

        assert(fmtPrice(312.244) == "312.24" && fmtPrice(1234.56) == "1234.6",
               "four significant-ish digits so wide prices still fit")

        // The arrow tracks the width of the percentage it precedes.
        assert(arrowX(pct: "0.40%") == 45, "5 characters leaves the arrow at 45")
        assert(arrowX(pct: "12.34%") < arrowX(pct: "0.40%"),
               "a wider percentage pushes the arrow left")
        assert(arrowX(pct: String(repeating: "9", count: 30)) == 0,
               "an absurd percentage clamps instead of going negative")
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
