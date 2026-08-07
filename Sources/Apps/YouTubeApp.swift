import SwiftUI

/// Channel title and subscriber count from the YouTube Data API. Needs the
/// user's own API key (Google Cloud console → YouTube Data API v3).
final class YouTubeApp: MiniApp {
    let app = "youtube"

    static let endpoint = "https://youtube.googleapis.com/youtube/v3/channels"
    static let userAgent = "busybar-youtube/1.0"

    static let ink = "#FFFFFFFF"
    static let dim = "#8A8A8AFF"
    static let brand = "#FF3B30FF"

    static let yLine1 = 0
    static let yLine2 = 8
    static let xRight = 73
    /// The 9x7 mark, then the title clear of it.
    static let logoX = 0
    static let logoY = 1
    static let xTitle = 11
    /// ~4px per character in the 5px font across what the mark leaves of 72px.
    static let titleChars = 15

    struct Channel {
        var title = "", subs = 0
        var hidden = false
    }

    // MARK: - Main loop

    func run(client: BarClient, status: @escaping @Sendable (String) -> Void) async {
        let d = UserDefaults.standard
        let key = (d.string(forKey: "yt.apiKey") ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let channel = (d.string(forKey: "yt.channel") ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // channels.list costs 1 unit against 10,000/day, so even a minute would
        // be fine; five is simply enough for a subscriber count.
        let interval = max(30, d.object(forKey: "yt.interval") as? Double ?? 300)
        var shown = "", polled = false

        while !Task.isCancelled {
            guard !key.isEmpty, !channel.isEmpty else {
                status(key.isEmpty ? "add an API key in settings"
                                   : "add a channel in settings")
                if !(await barSleep(interval)) { break }
                continue
            }
            do {
                let c = try await fetch(channel: channel, key: key, fresh: polled)
                polled = true
                let els = Self.frame(c)
                let subs = c.hidden ? "hidden" : Self.fmtSubs(c.subs)
                if !shown.isEmpty, shown != subs, subs != "hidden", shown != "hidden" {
                    await Roll.play(client: client, app: app, fields: [
                        Roll.Field(id: "subs", from: shown, to: subs, anchor: .left(0),
                                   y: Self.yLine2 + DeviceFont.smallInkOffset, color: Self.brand),
                    ], then: els)
                    status(Self.statusLine(c))
                } else {
                    let code = try await client.draw(app: app, elements: els)
                    status(code == 409 ? "paused — bar in use" : Self.statusLine(c))
                }
                shown = subs
            } catch {
                status("youtube: \(Self.describe(error))")
            }
            if !(await barSleep(interval)) { break }
        }
        await client.clear(app: app)
    }

    // MARK: - Data

    /// `fresh: false` for the first fetch of a run: `WebCache` still has the
    /// last answer, so a widget coming back draws at once.
    func fetch(channel: String, key: String, fresh: Bool) async throws -> Channel {
        var comps = URLComponents(string: Self.endpoint)!
        comps.queryItems = [
            URLQueryItem(name: "part", value: "snippet,statistics"),
            Self.selector(channel),
            URLQueryItem(name: "key", value: key),
        ]
        guard let url = comps.url else { throw WebError.bad }
        let obj = try await fetchJSON(url, userAgent: Self.userAgent, fresh: fresh)
        guard let item = (obj["items"] as? [[String: Any]])?.first else {
            throw WebError.notFound   // a valid key with no match returns items: []
        }
        let stats = item["statistics"] as? [String: Any] ?? [:]
        let snippet = item["snippet"] as? [String: Any] ?? [:]
        return Channel(title: snippet["title"] as? String ?? channel,
                       subs: Int(stats["subscriberCount"] as? String ?? "") ?? 0,
                       hidden: (stats["hiddenSubscriberCount"] as? Bool) ?? false)
    }

    // MARK: - Pure helpers

    /// Channel ids start with `UC`; anything else is treated as a handle, which
    /// the API wants with a leading `@`.
    static func selector(_ channel: String) -> URLQueryItem {
        if channel.hasPrefix("UC") {
            return URLQueryItem(name: "id", value: channel)
        }
        let handle = channel.hasPrefix("@") ? channel : "@" + channel
        return URLQueryItem(name: "forHandle", value: handle)
    }

    /// Google rounds subscriber counts to three significant figures, so more
    /// precision than this would be invented.
    static func fmtSubs(_ n: Int) -> String {
        let v = Double(n)
        if n >= 1_000_000 { return String(format: "%.2fM", v / 1_000_000) }
        if n >= 1_000 { return String(format: "%.1fK", v / 1_000) }
        return "\(n)"
    }

    /// Two dots, not an ellipsis: U+2026 makes the device reject the whole draw.
    static func truncate(_ s: String, _ max: Int) -> String {
        s.count <= max ? s : String(s.prefix(max - 2)) + ".."
    }

    static func statusLine(_ c: Channel) -> String {
        c.hidden ? "\(c.title) — subscribers hidden"
                 : "\(c.title) — \(fmtSubs(c.subs)) subscribers"
    }

    static func describe(_ error: Error) -> String {
        switch error {
        case WebError.notFound: return "no such channel"
        // 403 is the quota/key rejection, and the one users actually hit.
        case WebError.http(403): return "key rejected or quota exhausted"
        case WebError.http(let c): return "HTTP \(c)"
        case WebError.bad: return "unexpected response"
        default: return error.localizedDescription
        }
    }

    // MARK: - Frame

    static func frame(_ c: Channel) -> [[String: Any]] {
        // The play triangle has to follow the tile it sits in: rects paint in the
        // order they are sent.
        var els = Glyph.els("ytbody", Glyph.ytBody, x: logoX, y: logoY,
                            color: brand, slots: Glyph.ytBodySlots)
        els += Glyph.els("ytplay", Glyph.ytPlay, x: logoX + 3, y: logoY + 1,
                         color: ink, slots: Glyph.ytPlaySlots)
        els += [
            textEl("title", truncate(c.title, titleChars), x: xTitle, y: yLine1,
                   font: "small", color: ink, align: "top_left"),
            textEl("subs", c.hidden ? "hidden" : fmtSubs(c.subs), x: 0, y: yLine2,
                   font: "small", color: brand, align: "top_left"),
            textEl("label", "subs", x: xRight, y: yLine2,
                   font: "small", color: dim, align: "top_right"),
        ]
        return els
    }

    #if DEBUG
    static func selfCheck() {
        assert(selector("UCabc123").name == "id", "a UC prefix is a channel id")
        assert(selector("@mkbhd").value == "@mkbhd", "a handle keeps its @")
        assert(selector("mkbhd").value == "@mkbhd", "a bare handle gains one")
        assert(selector("mkbhd").name == "forHandle", "handles use forHandle")

        assert(fmtSubs(742) == "742", "small counts are exact")
        assert(fmtSubs(12_300) == "12.3K", "thousands")
        assert(fmtSubs(1_230_000) == "1.23M", "millions")
        assert(fmtSubs(999) == "999" && fmtSubs(1_000) == "1.0K", "the K boundary")
        assert(fmtSubs(0) == "0", "a new channel is not an error")

        assert(truncate("Short", titleChars) == "Short", "short titles are untouched")
        assert(truncate(String(repeating: "x", count: 30), titleChars).count == titleChars,
               "long titles are cut to the display width")
        assert(truncate(String(repeating: "x", count: 30), titleChars).allSatisfy { $0.isASCII },
               "and cut with characters the device accepts")
        // The title has to start clear of the mark and still fit the display.
        assert(xTitle >= logoX + 9, "the title clears the 9px mark")
        // Widest realistic case: the title is proportional, so measure it rather
        // than counting characters.
        assert(xTitle + DeviceFont.small.width(String(repeating: "M", count: titleChars)) > 72,
               "a title of M's overflows, which is why truncate is by characters")
        assert(xTitle + DeviceFont.small.width(String(repeating: "n", count: titleChars)) <= 72,
               "a title of average letters fits the space the mark leaves")
    }
    #endif
}

struct YouTubeSettingsView: View {
    @AppStorage("yt.apiKey") private var apiKey = ""
    @AppStorage("yt.channel") private var channel = ""
    @AppStorage("yt.interval") private var interval = 300.0

    var body: some View {
        Form {
            SecureField("API key", text: $apiKey)
            Link("Get an API key →",
                 destination: URL(string: "https://console.cloud.google.com/apis/library/youtube.googleapis.com")!)
                .font(.caption)
            Text("Enable the YouTube Data API v3 for a project, then create an API key under Credentials.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextField("Channel", text: $channel, prompt: Text("@mkbhd or UCxxxx"))
            TextField("Check every (s)", value: $interval, format: .number)
            Text("Google rounds subscriber counts to three significant figures, so the last digits are not live.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(width: 300)
    }
}
