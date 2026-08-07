import AppKit
import SwiftUI
import Security

/// Port of claude.py — live Claude Code usage bars with an animated Clawd mascot.
///
/// Front (72x16): the 8 px mascot on the left, a gray panel on the right holding the
/// 5-hour session bar (top) and the weekly bar (bottom). Both turn dark red above 85%
/// and show their time-to-reset inside the bar above 75%.
/// Back (160x80, OLED): the full dashboard — percentages, bars, reset times, and how
/// many Claude Code sessions are live right now. Both faces go out in one draw; every
/// element carries `display` and a `timeout` so a dead app auto-reverts the screen.
///
/// The Claude Code OAuth token is read **read-only** (Keychain, or
/// ~/.claude/.credentials.json) and never written back; an expired token renders
/// "AUTH EXPIRED - RUN claude" instead. Session activity comes from the mtimes of
/// ~/.claude/projects/*/*.jsonl — transcripts are never opened.
final class ClaudeApp: MiniApp {
    let app = "claude-limits"

    static let animInterval = 0.25       // s; ~4 fps mascot re-push
    static let activityInterval = 2.0    // s; how often the local session scan re-runs
    static let elementTimeout = 480      // s; dead-man window: a dead app clears itself
    static let staleSeconds = 900.0      // last good snapshot older than 15 min -> stale
    static let hold = 120.0              // s; each animation's time on screen
    static let animTimeout = 3           // s; animated rect auto-revert window
    static let highLimit = 85.0          // usage pct above which everything turns dark red

    static let front = "front", back = "back"

    // Two-color usage palette (Claude orange-brown OK / dark red above 85%).
    static let white = "#FFFFFFFF"
    static let cOk = "#CD6E58FF"         // Claude orange-brown ("ok"), same as the crab coral
    static let cHigh = "#B3261EFF"       // dark red ("high", usage > 85%)
    static let cPanel = "#3A3A3AFF"      // gray background behind the front bars
    static let cPanelEdge = "#4A4A4AFF"  // gray panel outline
    static let cBarEdge = "#1F1F1FFF"    // bar track outline
    static let cOnOk = "#1A1A1AFF"       // text on an orange bar fill
    static let cOnHigh = "#FFFFFFFF"     // text on a dark-red bar fill
    // Clawd mascot palette.
    static let cClawd = "#CD6E58FF"      // coral body
    static let cEye = "#000000FF"        // 1x1 black eye
    static let cTrans = "#00000000"      // transparent (blink / eye holes)
    static let cPink = "#F590C0FF"       // decorative heart/confetti
    static let cRain = "#8FB8E8FF"       // pale-blue rain streak
    static let cMoon = "#F4E7A6FF"       // pale-yellow crescent moon

    // MARK: - Model

    struct UsageSnapshot {
        var fivePct: Double
        var fiveResets: Date
        var weekPct: Double
        var weekResets: Date
        var fetchedAt: TimeInterval
    }

    /// How many Claude Code sessions are live, and whether one is mid-turn.
    struct Activity {
        var sessions = 0
        var working = false
    }

    enum Mood { case ok, high, stale, auth }
    enum Eyes { case fwd, left, right, down, blink }

    /// Eye look offsets in 14x8 grid cols/rows, applied per `ss`.
    static let eyeOffset: [Eyes: (Int, Int)] = [
        .fwd: (0, 0), .left: (-1, 0), .right: (1, 0), .down: (0, 1), .blink: (0, 0)]

    /// One animation frame shared by the front (8 px lane) and back crabs.
    struct MascotFrame {
        var t: Double            // normalized progress 0..1 within the current animation
        var dur: Double          // this animation's duration in seconds (schedule)
        var anim: String         // stable animation name
        var mood: Mood = .ok     // derived from the snapshot, not from the animation
        var fx: Int, fy: Int     // front crab origin
        var feyes: Eyes
        var bx: Int, by: Int     // back crab origin
        var beyes: Eyes
        var fextras: [[String: Any]] = []
        var bextras: [[String: Any]] = []
        var working = false      // a Claude Code turn is live right now

        init(_ t: Double, _ dur: Double, _ anim: String, _ fx: Int, _ fy: Int, _ feyes: Eyes,
             _ bx: Int, _ by: Int, _ beyes: Eyes,
             _ fextras: [[String: Any]] = [], _ bextras: [[String: Any]] = []) {
            self.t = t; self.dur = dur; self.anim = anim
            self.fx = fx; self.fy = fy; self.feyes = feyes
            self.bx = bx; self.by = by; self.beyes = beyes
            self.fextras = fextras; self.bextras = bextras
        }
    }

    enum UsageFailure: Error {
        case auth(String)       // the token was rejected — render the auth-degraded frame
        case transient(String)  // keep showing the last good snapshot
    }

    // MARK: - Run loop

    func run(client: BarClient, status: @escaping @Sendable (String) -> Void) async {
        let d = UserDefaults.standard
        // Floored: a cleared settings field stores 0, which would hammer the endpoint.
        let poll = max(5, d.object(forKey: "claude.poll") as? Double ?? 180)
        let priority = min(100, max(1, d.object(forKey: "claude.priority") as? Int ?? 20))
        let mock = d.object(forKey: "claude.mock") as? Bool ?? false
        let (mockFive, mockWeek) = Self.parseMockUsage(d.string(forKey: "claude.mockUsage") ?? "60,70")

        var snap: UsageSnapshot?
        var lastGood: UsageSnapshot?
        var act = Activity()
        var note: String?           // why there is no snapshot, for the status line
        var dir = Self.GrantedDir.resolve()
        var lastData = 0.0
        var lastActivity = 0.0
        var lastStatus = ""

        status("starting…")
        while !Task.isCancelled {
            let now = Date().timeIntervalSince1970
            // The grant can arrive while we run; retry until the bookmark resolves and
            // refresh straight away once it does, so the display recovers on its own.
            if dir == nil, now - lastActivity >= Self.activityInterval,
               let granted = Self.GrantedDir.resolve() {
                dir = granted
                lastData = 0
            }
            if lastData == 0 || now - lastData >= poll {
                if mock {
                    snap = Self.mockSnapshot(now: now, five: mockFive, week: mockWeek)
                    lastGood = snap
                    note = nil
                } else {
                    (snap, lastGood, note) = await Self.refresh(lastGood: lastGood, dir: dir)
                }
                lastData = Date().timeIntervalSince1970
            }
            if now - lastActivity >= Self.activityInterval {
                act = Self.readActivity(now: now, dir: dir)
                lastActivity = now
            }

            var frame = Self.animationFor(snap, now: now, hold: Self.hold)
            frame.working = act.working
            // The full frame goes out every tick: the firmware upserts by id, so a
            // mascot-only push would blank the dashboard between polls.
            let elements = Self.buildElements(snap: snap, act: act, now: now, frame: frame)

            var line = Self.statusLine(snap: snap, act: act, note: note, now: now)
            do {
                let code = try await client.draw(app: app, elements: elements, priority: priority)
                switch code {
                case 200:
                    break
                case 409:
                    // A higher-priority app owns the display; keep trying quietly.
                    line = "display busy: another app has priority (raise it above \(priority))"
                case 401, 403:
                    status("device rejected the access key")
                    await client.clear(app: app)
                    return
                case 400:
                    status("device rejected the frame (HTTP 400)")
                    await client.clear(app: app)
                    return
                default:
                    line = "unexpected HTTP \(code)"
                }
            } catch {
                line = "device unreachable: \(error.localizedDescription)"
            }
            if line != lastStatus { status(line); lastStatus = line }

            if !(await barSleep(Self.animInterval)) { break }
        }
        await client.clear(app: app)
    }

    static func statusLine(snap: UsageSnapshot?, act: Activity, note: String?,
                           now: TimeInterval) -> String {
        var parts: [String] = []
        if let snap {
            if now - snap.fetchedAt > staleSeconds {
                parts.append("stale \(Int((now - snap.fetchedAt) / 60))m")
            }
            parts.append("5h \(pct(snap.fivePct))")
            parts.append("week \(pct(snap.weekPct))")
        } else {
            parts.append(note ?? "AUTH EXPIRED — run claude")
        }
        parts.append("\(act.sessions) session" + (act.sessions == 1 ? "" : "s"))
        if act.working { parts.append("working") }
        return parts.joined(separator: " · ")
    }

    /// Return `(snapshot|nil, lastGood, note)` for this poll. `nil` means "render the
    /// auth-degraded frame"; a transient usage failure falls back to the last good
    /// snapshot, which ages into the stale frame — a usage outage must never
    /// masquerade as an auth problem.
    static func refresh(lastGood: UsageSnapshot?, dir: GrantedDir?) async
        -> (UsageSnapshot?, UsageSnapshot?, String?) {
        let (token, note) = await accessToken(dir: dir)
        guard let token else { return (nil, lastGood, note) }
        do {
            let snap = try await fetchUsage(token: token)
            return (snap, snap, nil)
        } catch UsageFailure.auth(let why) {
            return (nil, lastGood, "AUTH EXPIRED — run claude (\(why))")
        } catch {
            if let lastGood { return (lastGood, lastGood, nil) }
            // No good data ever: synthesise an already-stale snapshot so the display
            // says STALE rather than claiming 0% usage.
            let base = Date()
            return (UsageSnapshot(fivePct: 0, fiveResets: base.addingTimeInterval(3600),
                                  weekPct: 0, weekResets: base.addingTimeInterval(86_400),
                                  fetchedAt: Date().timeIntervalSince1970 - staleSeconds - 60),
                    nil, nil)
        }
    }

    /// Fixture snapshot: no OAuth, no network, no Claude install required.
    static func mockSnapshot(now: TimeInterval, five: Double, week: Double) -> UsageSnapshot {
        let base = Date()
        return UsageSnapshot(fivePct: five,
                             fiveResets: base.addingTimeInterval(2 * 3600 + 13 * 60),
                             weekPct: week,
                             weekResets: base.addingTimeInterval(29 * 3600),
                             fetchedAt: now)
    }

    static func parseMockUsage(_ raw: String) -> (Double, Double) {
        let parts = raw.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard parts.count == 2 else { return (60, 70) }
        return (parts[0], parts[1])
    }

    // MARK: - Sandboxed access to ~/.claude

    static let bookmarkKey = "claude.dirBookmark"
    static let grantHint = "grant ~/.claude access in settings (gear icon)"

    /// The user-granted ~/.claude directory. Under the sandbox there is no path to the
    /// real home, so every read below goes through a security-scoped bookmark the user
    /// creates once from the settings sheet (NSOpenPanel). Access is held for as long
    /// as the instance lives and released in `deinit`.
    final class GrantedDir {
        let url: URL
        private let scoped: Bool

        init?(bookmark: Data) {
            var stale = false
            guard let url = try? URL(resolvingBookmarkData: bookmark,
                                     options: .withSecurityScope, relativeTo: nil,
                                     bookmarkDataIsStale: &stale) else { return nil }
            self.url = url
            scoped = url.startAccessingSecurityScopedResource()
        }

        /// Resolve the bookmark stored by the settings view, if the user granted one.
        static func resolve() -> GrantedDir? {
            guard let data = UserDefaults.standard.data(forKey: ClaudeApp.bookmarkKey),
                  !data.isEmpty else { return nil }
            return GrantedDir(bookmark: data)
        }

        deinit { if scoped { url.stopAccessingSecurityScopedResource() } }
    }

    // MARK: - Claude Code credentials (read-only)

    static let keychainService = "Claude Code-credentials"

    /// The current Claude Code OAuth access token, plus a note when there is none.
    ///
    /// Strictly read-only: the token is never refreshed and never written back.
    /// Refreshing would rotate the refresh token, and persisting the rotation means an
    /// LED widget mutating the Keychain entry your `claude` login depends on — so an
    /// expired token simply renders the degraded frame.
    ///
    /// The Keychain item belongs to another app, so a sandboxed build cannot read it
    /// (unsandboxed dev builds can, after a one-time allow dialog). Any failure is
    /// non-fatal and falls through to `.credentials.json` inside the granted directory.
    static func accessToken(dir: GrantedDir?) async -> (String?, String?) {
        // Serve the token already in hand rather than going back to the Keychain
        // every poll. Each read can pop the system allow dialog, and "Always
        // Allow" does not hold: Claude Code rewrites its own Keychain item when it
        // refreshes the OAuth token, which resets that item's access list and
        // drops the permission this app was given. One read per token instead of
        // one per poll turns a dialog every three minutes into one every few
        // hours.
        let now = Date().timeIntervalSince1970
        if let cached = await tokenCache.token(now: now) { return (cached, nil) }

        var blob = await keychainBlob()
        if blob == nil, let dir {
            blob = try? String(contentsOf: dir.url.appendingPathComponent(".credentials.json"),
                               encoding: .utf8)
        }
        // Nothing readable at all — no grant, the wrong folder, or no Claude Code here.
        guard let blob else { return (nil, grantHint) }
        guard let data = blob.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let oauth = obj["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String,
              let expiresAt = oauth["expiresAt"] as? Double
        else { return (nil, "credentials unreadable — run claude") }
        if expiresAt / 1000 <= now {
            return (nil, "AUTH EXPIRED — run claude")
        }
        await tokenCache.store(token, expiresAt: expiresAt / 1000)
        return (token, nil)
    }

    private static let tokenCache = TokenCache()

    /// The token last read, held until shortly before it expires. In memory only —
    /// nothing about the credentials is written anywhere.
    actor TokenCache {
        /// Re-read this long before expiry, so a token handed out cannot go stale
        /// mid-request.
        static let margin = 120.0

        private var token: String?
        private var expiresAt = 0.0

        func token(now: Double) -> String? {
            guard let token, now < expiresAt - Self.margin else { return nil }
            return token
        }

        func store(_ token: String, expiresAt: Double) {
            self.token = token
            self.expiresAt = expiresAt
        }
    }

    /// Read the generic-password item off the main pool: on an unsandboxed build the
    /// first read of another app's Keychain item pops a system "allow" dialog and blocks
    /// until answered. A sandboxed build just gets an error status back.
    private static func keychainBlob() async -> String? {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .utility).async {
                let query: [String: Any] = [
                    kSecClass as String: kSecClassGenericPassword,
                    kSecAttrService as String: keychainService,
                    kSecReturnData as String: true,
                    kSecMatchLimit as String: kSecMatchLimitOne,
                ]
                var item: CFTypeRef?
                let st = SecItemCopyMatching(query as CFDictionary, &item)
                guard st == errSecSuccess, let data = item as? Data else {
                    return cont.resume(returning: nil)
                }
                cont.resume(returning: String(data: data, encoding: .utf8))
            }
        }
    }

    // MARK: - Usage endpoint

    static let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    static let userAgent = "claude-code/2.1.220"

    /// Fetch the 5-hour and 7-day utilization for the signed-in account.
    ///
    /// NOTE: `/api/oauth/usage` is an **undocumented** endpoint that Claude Code itself
    /// calls, hence the pinned User-Agent. It is the single most likely thing to break
    /// in a future release; everything else here is public API.
    static func fetchUsage(token: String) async throws -> UsageSnapshot {
        var req = URLRequest(url: usageURL)
        req.timeoutInterval = 15
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let data: Data, resp: URLResponse
        do { (data, resp) = try await URLSession.shared.data(for: req) }
        catch { throw UsageFailure.transient("usage request failed: \(error.localizedDescription)") }

        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        switch code {
        case 200: break
        case 401, 403: throw UsageFailure.auth("usage HTTP \(code)")
        case 429: throw UsageFailure.transient("rate limited")
        default: throw UsageFailure.transient("usage HTTP \(code)")
        }

        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let five = obj["five_hour"] as? [String: Any],
              let week = obj["seven_day"] as? [String: Any],
              let fivePct = five["utilization"] as? Double,
              let weekPct = week["utilization"] as? Double
        else { throw UsageFailure.transient("unexpected payload") }
        return UsageSnapshot(fivePct: fivePct,
                             fiveResets: parseResets(five["resets_at"] as? String),
                             weekPct: weekPct,
                             weekResets: parseResets(week["resets_at"] as? String),
                             fetchedAt: Date().timeIntervalSince1970)
    }

    static let isoFrac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    static let iso = ISO8601DateFormatter()

    /// Parse a resets_at timestamp; anything unusable reads as "right now".
    static func parseResets(_ raw: String?) -> Date {
        guard let raw else { return Date() }
        return isoFrac.date(from: raw) ?? iso.date(from: raw) ?? Date()
    }

    // MARK: - Local session activity

    static let sessionWindow = 300.0  // s; a transcript touched this recently is a live session
    static let workingWindow = 10.0   // s; a transcript touched this recently means a live turn

    /// Count live sessions from transcript mtimes under `<granted dir>/projects`.
    /// Only mtimes are read: transcripts run to tens of megabytes and are never opened.
    /// No grant, or any read error, degrades to zero sessions rather than taking the
    /// display down.
    static func readActivity(now: TimeInterval, dir: GrantedDir?) -> Activity {
        guard let dir else { return Activity() }
        let fm = FileManager.default
        let root = dir.url.appendingPathComponent("projects")
        guard let projects = try? fm.contentsOfDirectory(at: root,
                                                         includingPropertiesForKeys: [.isDirectoryKey])
        else { return Activity() }
        var act = Activity()
        for proj in projects {
            guard (try? proj.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
                  let entries = try? fm.contentsOfDirectory(
                      at: proj, includingPropertiesForKeys: [.contentModificationDateKey])
            else { continue }  // one unreadable project must not hide the others
            for entry in entries where entry.pathExtension == "jsonl" {
                guard let mtime = try? entry.resourceValues(forKeys: [.contentModificationDateKey])
                    .contentModificationDate else { continue }
                let age = now - mtime.timeIntervalSince1970
                if age <= sessionWindow { act.sessions += 1 }
                if age <= workingWindow { act.working = true }
            }
        }
        return act
    }

    // MARK: - Element builders
    //
    // Element ids, coordinates, fonts, and text formats are the load-bearing layout
    // contract: element `type` and `display` for a given id must never change (the
    // firmware rejects a redraw with 400 otherwise).

    static func text(_ id: String, _ str: String, _ x: Int, _ y: Int, align: String,
                     font: String, color: String, display: String, timeout: Int) -> [String: Any] {
        ["id": id, "type": "text", "text": str, "font": font, "color": color,
         "align": align, "x": x, "y": y, "timeout": timeout, "display": display]
    }

    static func rect(_ id: String, _ x: Int, _ y: Int, _ w: Int, _ h: Int, fill: String,
                     fillColors: [String], borderWidth: Int, borderColor: String,
                     display: String, timeout: Int) -> [String: Any] {
        ["id": id, "type": "rectangle", "x": x, "y": y, "width": w, "height": h,
         "radius": 0, "fill": fill, "fill_colors": fillColors,
         "border_width": borderWidth, "border_color": borderColor,
         "timeout": timeout, "display": display]
    }

    static func solid(_ id: String, _ x: Int, _ y: Int, _ w: Int, _ h: Int, _ color: String,
                      _ display: String, _ timeout: Int) -> [String: Any] {
        rect(id, x, y, w, h, fill: "solid", fillColors: [color], borderWidth: 0,
             borderColor: cTrans, display: display, timeout: timeout)
    }

    /// Progress fill rect; transparent (invisible 1 px) when pct < 1 so the element id
    /// stays alive without drawing a visible pixel.
    static func barFill(_ id: String, _ x: Int, _ y: Int, _ pct: Double, display: String,
                        timeout: Int, color: String = white, w: Int = 154,
                        h: Int = 6) -> [String: Any] {
        let fw = max(1, Int((Double(w) * pct / 100).rounded(.toNearestOrEven)))
        return rect(id, x, y, fw, h, fill: "solid", fillColors: pct >= 1 ? [color] : [cTrans],
                    borderWidth: 0, borderColor: white, display: display, timeout: timeout)
    }

    static func barOutline(_ id: String, _ x: Int, _ y: Int, display: String,
                           timeout: Int) -> [String: Any] {
        rect(id, x, y, 156, 8, fill: "none", fillColors: [], borderWidth: 1,
             borderColor: white, display: display, timeout: timeout)
    }

    /// A 1x1 animated extra rect on the animTimeout window.
    static func pixel(_ id: String, _ x: Int, _ y: Int, _ color: String,
                      _ display: String) -> [String: Any] {
        solid(id, x, y, 1, 1, color, display, animTimeout)
    }

    /// A 1-char animated extra text on the animTimeout window.
    static func char(_ id: String, _ x: Int, _ y: Int, _ ch: String,
                     _ display: String) -> [String: Any] {
        text(id, ch, x, y, align: "top_left", font: "small", color: white,
             display: display, timeout: animTimeout)
    }

    /// Two-color usage indicator: Claude orange-brown at/below the high threshold,
    /// dark red above it.
    static func limitColor(_ pct: Double) -> String { pct > highLimit ? cHigh : cOk }

    static func pct(_ v: Double) -> String { String(format: "%.0f%%", v) }

    // MARK: - Formatting

    /// Front compact form: `3h59m` or `59m`. Negatives clamp to 0.
    static func fmtRelShort(_ seconds: Double) -> String {
        let s = max(0, Int(seconds))
        let h = s / 3600, m = (s % 3600) / 60
        return h > 0 ? String(format: "%dh%02dm", h, m) : "\(m)m"
    }

    /// Back parenthesized session form: `(3h 59m)` or `(59m)`.
    static func fmtRelLong(_ seconds: Double) -> String {
        let s = max(0, Int(seconds))
        let h = s / 3600, m = (s % 3600) / 60
        return h > 0 ? String(format: "(%dh %02dm)", h, m) : "(\(m)m)"
    }

    /// Week-range form: `6d` at/over 48 h, `1d 5h` from 24 h, else `23h59m` / `59m`.
    static func fmtRelWeek(_ seconds: Double) -> String {
        let s = max(0, Int(seconds))
        let d = s / 3600 / 24, h = (s / 3600) % 24, m = (s % 3600) / 60
        if h + d * 24 >= 48 { return "\(d)d" }
        if d > 0 { return "\(d)d \(h)h" }
        if h > 0 { return String(format: "%dh%02dm", h, m) }
        return "\(m)m"
    }

    /// Back parenthesized week form: `(2d 5h)` or `(23h 59m)`.
    static func fmtRelWeekLong(_ seconds: Double) -> String {
        let s = max(0, Int(seconds))
        let d = s / 3600 / 24, h = (s / 3600) % 24, m = (s % 3600) / 60
        if d > 0 { return "(\(d)d \(h)h)" }
        if h > 0 { return String(format: "(%dh %02dm)", h, m) }
        return "(\(m)m)"
    }

    static let hhmm = localFormatter("HH:mm")
    static let dayHHmm = localFormatter("EEE HH:mm")

    static func localFormatter(_ format: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = format
        return f
    }

    /// A reset time in local time. Session -> `18:05`; weekly -> `18:05` when under a
    /// day away, else weekday `Mon 18:05`.
    static func fmtAbs(_ dt: Date, weekly: Bool) -> String {
        if !weekly || dt.timeIntervalSinceNow < 24 * 3600 { return hhmm.string(from: dt) }
        return dayHHmm.string(from: dt)
    }

    // MARK: - Motion helpers

    static func lerp(_ a: Double, _ b: Double, _ u: Double) -> Double { a + (b - a) * u }

    /// 0 -> 1 -> 0 triangle over u in [0, 1].
    static func ping(_ u: Double) -> Double { u < 0.5 ? 2 * u : 2 * (1 - u) }

    /// +1 / -1 pulse (rounded sine).
    static func trip(_ u: Double) -> Int { Int((sin(u * 2 * .pi)).rounded(.toNearestOrEven)) }

    static func iround(_ v: Double) -> Int { Int(v.rounded(.toNearestOrEven)) }

    /// True inside the last `frac` of each `period`.
    static func blink(_ t: Double, period: Double = 0.9, frac: Double = 0.1) -> Bool {
        t.truncatingRemainder(dividingBy: period) >= period * (1 - frac)
    }

    static func gated(_ u: Double, _ a: Double, _ b: Double) -> Bool { a <= u && u <= b }

    // MARK: - The 21 animations (each f(t) -> MascotFrame)

    static func aBreath(_ t: Double) -> MascotFrame {
        MascotFrame(t, 8, "breath", 2, 4 + trip(t), .fwd, 76, 40 + trip(t), .fwd)
    }

    static func aWalk(_ t: Double) -> MascotFrame {
        let p = ping(t)
        return MascotFrame(t, 10, "walk", iround(lerp(2, 11, p)), 4 + trip(4 * t), .fwd,
                           iround(lerp(10, 130, p)), 40 + trip(4 * t), .fwd)
    }

    static func aJump(_ t: Double) -> MascotFrame {
        let lift = abs(sin(6 * .pi * t))
        let e: Eyes = lift > 0.9 ? .blink : .fwd
        return MascotFrame(t, 6, "jump", 2, 4 - iround(lift * 3), e, 76, 40 - iround(lift * 6), e)
    }

    static func aWaveR(_ t: Double) -> MascotFrame {
        let up = sin(4 * .pi * t) > 0
        let e: Eyes = up ? .right : .fwd
        let (fx, fy, bx, by) = (6, 4, 70, 40)
        let fe = [pixel("fx_4a", fx + 14, fy + 1, cClawd, front),
                  pixel("fx_4b", fx + 15, fy + (up ? 0 : 1), cClawd, front)]
        let be = [pixel("bx_4a", bx + 14, by + 1, cClawd, back),
                  pixel("bx_4b", bx + 15, by + (up ? 0 : 1), cClawd, back)]
        return MascotFrame(t, 6, "wave_r", fx, fy, e, bx, by, e, fe, be)
    }

    static func aWaveL(_ t: Double) -> MascotFrame {
        let up = sin(4 * .pi * t) > 0
        let e: Eyes = up ? .left : .fwd
        let (fx, fy, bx, by) = (8, 4, 70, 40)
        let fe = [pixel("fx_5a", fx - 1, fy + 1, cClawd, front),
                  pixel("fx_5b", fx - 2, fy + (up ? 0 : 1), cClawd, front)]
        let be = [pixel("bx_5a", bx - 1, by + 1, cClawd, back),
                  pixel("bx_5b", bx - 2, by + (up ? 0 : 1), cClawd, back)]
        return MascotFrame(t, 6, "wave_l", fx, fy, e, bx, by, e, fe, be)
    }

    static func aLook(_ t: Double) -> MascotFrame {
        let e: Eyes
        switch t {
        case ..<0.22: e = .right
        case ..<0.44: e = .fwd
        case ..<0.66: e = .left
        case ..<0.88: e = .fwd
        default: e = .right
        }
        var fe: [[String: Any]] = [], be: [[String: Any]] = []
        if gated(t, 0.5, 0.65) {
            fe = [char("fx_6a", 2 + 13, 4 - 2, "?", front)]
            be = [char("bx_6a", 76 + 15, 40 - 2, "?", back)]
        }
        return MascotFrame(t, 8, "look", 2, 4, e, 76, 40, e, fe, be)
    }

    static func aSparkle(_ t: Double) -> MascotFrame {
        let (fx, fy, bx, by) = (2, 4, 76, 40)
        var fe: [[String: Any]] = [], be: [[String: Any]] = []
        if gated(t, 0.3, 0.5) || gated(t, 0.75, 0.9) {
            fe = [pixel("fx_7a", fx + 4, fy + 1, white, front),
                  pixel("fx_7b", fx + 9, fy + 1, white, front)]
            be = [pixel("bx_7a", bx + 4, by + 1, white, back),
                  pixel("bx_7b", bx + 9, by + 1, white, back)]
        }
        if gated(t, 0.55, 0.7) {
            fe += [pixel("fx_7c", fx + 14, fy - 1, cPink, front)]
            be += [pixel("bx_7c", bx + 14, by - 1, cPink, back)]
        }
        return MascotFrame(t, 7, "sparkle", fx, fy, .fwd, bx, by, .fwd, fe, be)
    }

    static func aSleep(_ t: Double) -> MascotFrame {
        let (fx, fy, bx, by) = (2, 6, 76, 42)
        let e: Eyes = t > 0.2 ? .blink : .fwd
        var fe = gated(t, 0.3, 0.6) ? [char("fx_8a", fx + 13, fy - 2, "z", front)] : []
        var be = gated(t, 0.3, 0.6) ? [char("bx_8a", bx + 15, by - 2, "z", back)] : []
        if gated(t, 0.55, 1.0) {
            fe += [char("fx_8b", fx + 15, fy - 3, "Z", front)]
            be += [char("bx_8b", bx + 16, by - 3, "Z", back)]
        }
        return MascotFrame(t, 8, "sleep", fx, fy, e, bx, by, e, fe, be)
    }

    static func aPanic(_ t: Double) -> MascotFrame {
        let (fx, fy, bx, by) = (2 + trip(8 * t), 4, 76 + trip(8 * t) * 2, 40)
        let fe = t > 0.15 ? [pixel("fx_9a", fx + 13, fy + 1, white, front)] : []
        let be = t > 0.15 ? [pixel("bx_9a", bx + 13, by + 1, white, back)] : []
        return MascotFrame(t, 7, "panic", fx, fy, .down, bx, by, .down, fe, be)
    }

    static func aWorry(_ t: Double) -> MascotFrame {
        let (fx, fy, bx, by) = (2, 4, 76, 40)
        let fe = t > 0.2 ? [pixel("fx_10a", fx + 13, fy + 1, white, front)] : []
        let be = t > 0.2 ? [pixel("bx_10a", bx + 13, by + 1, white, back)] : []
        return MascotFrame(t, 7, "worry", fx, fy, .down, bx, by, .down, fe, be)
    }

    static func aDance(_ t: Double) -> MascotFrame {
        let s = sin(4 * .pi * t)
        let fx = 6 + iround(s) * 2, fy = 4 + trip(4 * t)
        let bx = 76 + iround(s) * 4, by = 40 + trip(4 * t)
        let e: Eyes = (t < 0.25 || (0.5 <= t && t < 0.75)) ? .left : .right
        var fe: [[String: Any]] = [], be: [[String: Any]] = []
        if s > 0 {
            fe = [pixel("fx_11a", fx + 13, fy - 1, cPink, front),
                  pixel("fx_11b", fx + 14, fy, cPink, front)]
            be = [pixel("bx_11a", bx + 13, by - 1, cPink, back),
                  pixel("bx_11b", bx + 14, by, cPink, back)]
        }
        return MascotFrame(t, 9, "dance", fx, fy, e, bx, by, e, fe, be)
    }

    static func aChase(_ t: Double) -> MascotFrame {
        let fx: Int, bx: Int, e: Eyes
        if t < 0.5 {
            fx = iround(lerp(2, 13, min(1, 2 * t)))
            bx = iround(lerp(60, 126, min(1, 2 * t)))
            e = .right
        } else {
            fx = iround(lerp(13, 2, min(1, 2 * (t - 0.5))))
            bx = iround(lerp(126, 60, min(1, 2 * (t - 0.5))))
            e = .fwd
        }
        return MascotFrame(t, 8, "chase", fx, 4, e, bx, 40, e)
    }

    /// London Clawd: stands under a storm, pale-blue streaks falling around.
    static func aRain(_ t: Double) -> MascotFrame {
        let (fx, fy, bx, by) = (2, 4, 76, 40)
        let e: Eyes = t.truncatingRemainder(dividingBy: 0.5) < 0.08 ? .down : .fwd
        var fe: [[String: Any]] = [], be: [[String: Any]] = []
        for i in 0..<3 {
            let rr = Int((t + Double(i) / 3).truncatingRemainder(dividingBy: 1) * 5)
            fe.append(pixel("fx_12_\(i)", fx + 2 + i * 4, fy - 2 + rr, cRain, front))
            be.append(pixel("bx_12_\(i)", bx + 2 + i * 4, by - 2 + rr, cRain, back))
        }
        return MascotFrame(t, 8, "rain", fx, fy, e, bx, by, e, fe, be)
    }

    /// Clawd Surfing: rides a wave side to side with a white spray pixel.
    static func aSurf(_ t: Double) -> MascotFrame {
        let s = sin(2 * .pi * t)
        let fx = iround(lerp(3, 8, ping(t))), fy = 4 + trip(2 * t)
        let bx = iround(lerp(70, 110, ping(t))), by = 40 + trip(2 * t)
        let fe = s > 0 ? [pixel("fx_13", fx + 14, fy, white, front)] : []
        let be = s > 0 ? [pixel("bx_13", bx + 14, by, white, back)] : []
        return MascotFrame(t, 6, "surf", fx, fy, .fwd, bx, by, .fwd, fe, be)
    }

    /// Clawd Love: a pink heart rises off his head, then bursts into pixels.
    static func aLove(_ t: Double) -> MascotFrame {
        let (fx, fy, bx, by) = (2, 4, 76, 40)
        var fe: [[String: Any]] = [], be: [[String: Any]] = []
        if t < 0.55 {
            let h = Int(t / 0.55 * 3)
            fe = [pixel("fx_14a", fx + 5, fy - 1 - h, cPink, front),
                  pixel("fx_14b", fx + 7, fy - 1 - h, cPink, front),
                  pixel("fx_14c", fx + 6, fy - h, cPink, front)]
            be = [pixel("bx_14a", bx + 5, by - 1 - h, cPink, back),
                  pixel("bx_14b", bx + 7, by - 1 - h, cPink, back),
                  pixel("bx_14c", bx + 6, by - h, cPink, back)]
        } else {
            let p = (t - 0.55) / 0.45
            for i in 0..<4 {
                let ang = Double(i) * .pi / 2
                fe.append(pixel("fx_14d\(i)", fx + 6 + iround(2 * cos(ang) * p),
                                fy - 2 + iround(2 * sin(ang) * p), cPink, front))
                be.append(pixel("bx_14d\(i)", bx + 6 + iround(2 * cos(ang) * p),
                                by - 2 + iround(2 * sin(ang) * p), cPink, back))
            }
        }
        return MascotFrame(t, 8, "love", fx, fy, .fwd, bx, by, .fwd, fe, be)
    }

    /// Mad Clawd: trembling with crimson heat-vision beams streaking sideways.
    static func aMad(_ t: Double) -> MascotFrame {
        let shake = trip(10 * t)
        let (fx, fy, bx, by) = (2 + shake, 4, 76 + 2 * shake, 40)
        let e: Eyes = t.truncatingRemainder(dividingBy: 0.6) < 0.15 ? .blink : .down
        var fe: [[String: Any]] = [], be: [[String: Any]] = []
        if t > 0.15 {
            for i in 0..<3 {
                fe.append(pixel("fx_15_\(i)", fx + 12 + i, fy + 1, cHigh, front))
                be.append(pixel("bx_15_\(i)", bx + 12 + i, by + 1, cHigh, back))
            }
        }
        return MascotFrame(t, 6, "mad", fx, fy, e, bx, by, e, fe, be)
    }

    /// Moonlit Clawd: dozed off low with a pale moon and a drifting z.
    static func aMoonlight(_ t: Double) -> MascotFrame {
        let (fx, fy, bx, by) = (2, 6, 76, 42)
        let e: Eyes = t > 0.3 ? .blink : .fwd
        var fe = gated(t, 0.4, 1.0) ? [pixel("fx_16", fx + 13, fy - 3, cMoon, front)] : []
        var be = gated(t, 0.4, 1.0) ? [pixel("bx_16", bx + 14, by - 3, cMoon, back)] : []
        if gated(t, 0.5, 0.8) {
            fe += [char("fx_16b", fx + 15, fy - 4, "z", front)]
            be += [char("bx_16b", bx + 16, by - 4, "z", back)]
        }
        return MascotFrame(t, 8, "moonlight", fx, fy, e, bx, by, e, fe, be)
    }

    /// Clawd Life: a cool, slow nod (GTA-style shade drop).
    static func aDealWithIt(_ t: Double) -> MascotFrame {
        let tilt = iround(sin(2 * .pi * t) * 0.6)
        let (fx, fy, bx, by) = (2, 4 + tilt, 76, 40 + tilt)
        let e: Eyes = t.truncatingRemainder(dividingBy: 1.5) < 0.12 ? .blink : .fwd
        return MascotFrame(t, 7, "dealwithit", fx, fy, e, bx, by, e)
    }

    /// This-is-fine Clawd: calm while little flames lick up around him.
    static func aFire(_ t: Double) -> MascotFrame {
        let (fx, fy, bx, by) = (2, 4, 76, 40)
        var fe: [[String: Any]] = [], be: [[String: Any]] = []
        for i in 0..<4 {
            let p = Int((t + Double(i) / 4).truncatingRemainder(dividingBy: 1) * 2)
            let c = i % 2 != 0 ? cOk : cHigh
            fe.append(pixel("fx_18_\(i)", fx + 1 + i * 3, fy + 3 + p, c, front))
            be.append(pixel("bx_18_\(i)", bx + 1 + i * 3, by + 3 + p, c, back))
        }
        return MascotFrame(t, 7, "fire", fx, fy, .fwd, bx, by, .fwd, fe, be)
    }

    /// Mariachlawd: side-step dance while shaking pink maracas.
    static func aMariachi(_ t: Double) -> MascotFrame {
        let s = sin(4 * .pi * t)
        let fx = 4 + iround(s) * 2, fy = 4 + trip(4 * t)
        let bx = 76 + iround(s) * 4, by = 40 + trip(4 * t)
        var fe: [[String: Any]] = [], be: [[String: Any]] = []
        if s > 0 {
            fe = [pixel("fx_19", fx + 13, fy - 1, cPink, front),
                  pixel("fx_19b", fx + 14, fy, cPink, front)]
            be = [pixel("bx_19", bx + 13, by - 1, cPink, back),
                  pixel("bx_19b", bx + 14, by, cPink, back)]
        }
        return MascotFrame(t, 7, "mariachi", fx, fy, .fwd, bx, by, .fwd, fe, be)
    }

    /// Clawd on the Barbie: a pink sausage flips overhead on a small arc.
    static func aBarbie(_ t: Double) -> MascotFrame {
        let (fx, fy, bx, by) = (2, 4, 76, 40)
        var fe: [[String: Any]] = [], be: [[String: Any]] = []
        if t < 0.7 {
            let a = t / 0.7 * .pi
            let dy = iround(sin(a) * 2), dx = iround(cos(a) * 2)
            fe = [pixel("fx_20a", fx + 5 + dx, fy - 2 - dy, cPink, front),
                  pixel("fx_20b", fx + 7 + dx, fy - 2 - dy, cPink, front)]
            be = [pixel("bx_20a", bx + 5 + dx, by - 2 - dy, cPink, back),
                  pixel("bx_20b", bx + 7 + dx, by - 2 - dy, cPink, back)]
        }
        return MascotFrame(t, 8, "barbie", fx, fy, .right, bx, by, .right, fe, be)
    }

    static let anims: [(Double) -> MascotFrame] = [
        aBreath, aWalk, aJump, aWaveR, aWaveL, aLook,
        aSparkle, aSleep, aPanic, aWorry, aDance, aChase,
        aRain, aSurf, aLove, aMad, aMoonlight, aDealWithIt,
        aFire, aMariachi, aBarbie]

    /// Pick the animation active at epoch `now` (stateless rotation). Each animation is
    /// held for `hold` seconds, looping its internal motion, before the next takes over.
    static func animationAt(_ now: TimeInterval, hold: Double) -> MascotFrame {
        let a = anims[Int(now / hold) % anims.count]
        let dur = a(0).dur
        let local = now.truncatingRemainder(dividingBy: hold)
        return a(local.truncatingRemainder(dividingBy: dur) / dur)
    }

    /// Derive the Clawd mood from the snapshot: auth > stale > high > ok.
    static func moodFor(_ snap: UsageSnapshot?, now: TimeInterval) -> Mood {
        guard let snap else { return .auth }
        if now - snap.fetchedAt > staleSeconds { return .stale }
        if max(snap.fivePct, snap.weekPct) > highLimit { return .high }
        return .ok
    }

    static func animationFor(_ snap: UsageSnapshot?, now: TimeInterval,
                             hold: Double) -> MascotFrame {
        var f = animationAt(now, hold: hold)
        f.mood = moodFor(snap, now: now)
        return f
    }

    // MARK: - Mascot

    /// The 9 rectangle elements of one Clawd starting at (ox, oy), scaling a 14x8 cell
    /// grid by `ss`. Eye fill swaps to `eyeHidden` on a blink so ids stay stable/sent.
    static func clawd(_ ox: Int, _ oy: Int, ss: Int, eyes: Eyes, body: String,
                      eyeHidden: String, prefix: String, display: String,
                      timeout: Int) -> [[String: Any]] {
        let (ex, ey) = eyeOffset[eyes] ?? (0, 0)
        let eyeFill = eyes == .blink ? eyeHidden : cEye
        var els = [
            solid("\(prefix)body_top", ox + 3 * ss, oy, 8 * ss, 2 * ss, body, display, timeout),
            solid("\(prefix)body_mid", ox + ss, oy + 2 * ss, 12 * ss, 2 * ss, body, display, timeout),
            solid("\(prefix)body_bot", ox + 3 * ss, oy + 4 * ss, 8 * ss, 2 * ss, body, display, timeout),
        ]
        for (i, cx) in [3, 5, 8, 10].enumerated() {
            els.append(solid("\(prefix)leg_\(i)", ox + cx * ss, oy + 6 * ss, ss, 2 * ss,
                             body, display, timeout))
        }
        for (i, cx) in [4, 9].enumerated() {
            els.append(solid("\(prefix)eye_\(i)", ox + (cx + ex) * ss, oy + (1 + ey) * ss,
                             ss, ss, eyeFill, display, timeout))
        }
        return els
    }

    /// The animated mask: 9 `fc_*` rects (front), 9 `bc_*` rects (back), plus the
    /// per-animation extras, all on the animTimeout window.
    ///
    /// Eyes resolve per-anim base -> blink override -> worried 'down' for non-ok moods.
    /// high/stale/auth moods also sprout a sweat pixel (panic/worry carry their own).
    /// `working` only doubles the blink rate — it is deliberately kept out of the mood
    /// ladder so a live turn can never mask the >85% warning, which is exactly when you
    /// most need to see it.
    static func frameElements(_ frame: MascotFrame) -> [[String: Any]] {
        var feyes = frame.feyes, beyes = frame.beyes
        let busy = frame.working ? blink(frame.t, period: 0.5, frac: 0.25) : blink(frame.t)
        if busy {
            feyes = .blink; beyes = .blink
        } else if frame.mood != .ok {
            feyes = .down; beyes = .down
        }

        var els = clawd(frame.fx, frame.fy, ss: 1, eyes: feyes, body: cClawd,
                        eyeHidden: cTrans, prefix: "fc_", display: front, timeout: animTimeout)
        els += clawd(frame.bx, frame.by, ss: 1, eyes: beyes, body: cClawd,
                     eyeHidden: cTrans, prefix: "bc_", display: back, timeout: animTimeout)
        els += frame.fextras
        els += frame.bextras
        if frame.mood != .ok && frame.anim != "panic" && frame.anim != "worry" {
            els.append(pixel("fx_swm", frame.fx + 13, frame.fy + 1, white, front))
            els.append(pixel("bx_swm", frame.bx + 13, frame.by + 1, white, back))
        }
        return els
    }

    // MARK: - Layout
    //
    // Three frame kinds are derived from the inputs (no state parameter):
    //   * no snapshot            -> auth-degraded frame (AUTH EXPIRED);
    //   * snapshot over 15 min   -> stale frame (STALE 21m);
    //   * otherwise              -> normal frame.

    /// Front right-side panel: gray background with the day (top) and week (bottom)
    /// progress bars. `fresh` = a normal (non-auth/non-stale) frame; the time-to-reset
    /// texts only appear then, and only above 75%.
    static func frontBars(_ snap: UsageSnapshot?, now: TimeInterval,
                          fresh: Bool) -> [[String: Any]] {
        let timeout = elementTimeout
        let five = snap?.fivePct ?? 0, week = snap?.weekPct ?? 0
        var els = [
            rect("fpanel", 28, 0, 44, 16, fill: "solid", fillColors: [cPanel],
                 borderWidth: 1, borderColor: cPanelEdge, display: front, timeout: timeout),
            rect("fday_track", 31, 1, 38, 6, fill: "none", fillColors: [],
                 borderWidth: 1, borderColor: cBarEdge, display: front, timeout: timeout),
            barFill("fday_fill", 32, 2, five, display: front, timeout: timeout,
                    color: limitColor(five), w: 36, h: 4),
            rect("fweek_track", 31, 9, 38, 6, fill: "none", fillColors: [],
                 borderWidth: 1, borderColor: cBarEdge, display: front, timeout: timeout),
            barFill("fweek_fill", 32, 10, week, display: front, timeout: timeout,
                    color: limitColor(week), w: 36, h: 4),
        ]
        var fiveColor = white, fiveText = " "
        if fresh, let snap, five > 75 {
            fiveColor = five > highLimit ? cOnHigh : cOnOk
            fiveText = fmtRelShort(snap.fiveResets.timeIntervalSince1970 - now)
        }
        els.append(text("fsess", fiveText, 33, 1, align: "top_left", font: "tiny",
                        color: fiveColor, display: front, timeout: timeout))
        var weekColor = white, weekText = " "
        if fresh, let snap, week > 75 {
            weekColor = week > highLimit ? cOnHigh : cOnOk
            weekText = fmtRelWeek(snap.weekResets.timeIntervalSince1970 - now)
        }
        els.append(text("fweek", weekText, 33, 9, align: "top_left", font: "tiny",
                        color: weekColor, display: front, timeout: timeout))
        // Reserved slot, deliberately blank: x=70 top_right sits inside the x 28..71
        // panel and any text here collides with `fday_track`. On the 72x16 front,
        // session activity is expressed by the mascot alone.
        els.append(text("fagents", " ", 70, 0, align: "top_right", font: "small",
                        color: white, display: front, timeout: timeout))
        return els
    }

    /// One row of the back dashboard: percentage, bar fill and reset line.
    struct BackRow {
        var pct = " "
        var pctColor = white
        var reset = " "
        var fill = 0.0
        var fillColor = white
    }

    /// Back status line: `2 SESSIONS` / `1 SESSION - WORKING`.
    static func sessionsLine(_ act: Activity) -> String {
        let line = "\(act.sessions) SESSION" + (act.sessions == 1 ? "" : "S")
        return act.working ? line + " - WORKING" : line
    }

    /// The 12 static back dashboard elements (ids/types are the firmware contract;
    /// `bagents` and `bsess_r`/`bweek_r` stay WHITE).
    static func backPanel(_ act: Activity, sess: BackRow, week: BackRow) -> [[String: Any]] {
        let timeout = elementTimeout
        return [
            text("btitle", "CLAUDE LIMITS", 80, 1, align: "top_mid", font: "large",
                 color: white, display: back, timeout: timeout),
            text("bsess_l", "SESSION", 2, 13, align: "top_left", font: "normal",
                 color: white, display: back, timeout: timeout),
            text("bsess_p", sess.pct, 158, 13, align: "top_right", font: "normal",
                 color: sess.pctColor, display: back, timeout: timeout),
            barOutline("bsess_bar", 2, 22, display: back, timeout: timeout),
            barFill("bsess_fill", 3, 23, sess.fill, display: back, timeout: timeout,
                    color: sess.fillColor),
            text("bsess_r", sess.reset, 2, 32, align: "top_left", font: "normal",
                 color: white, display: back, timeout: timeout),
            text("bweek_l", "WEEKLY", 2, 43, align: "top_left", font: "normal",
                 color: white, display: back, timeout: timeout),
            text("bweek_p", week.pct, 158, 43, align: "top_right", font: "normal",
                 color: week.pctColor, display: back, timeout: timeout),
            barOutline("bweek_bar", 2, 52, display: back, timeout: timeout),
            barFill("bweek_fill", 3, 53, week.fill, display: back, timeout: timeout,
                    color: week.fillColor),
            text("bweek_r", week.reset, 2, 62, align: "top_left", font: "normal",
                 color: white, display: back, timeout: timeout),
            text("bagents", sessionsLine(act), 2, 72, align: "top_left", font: "normal",
                 color: white, display: back, timeout: timeout),
        ]
    }

    static func buildElements(snap: UsageSnapshot?, act: Activity, now: TimeInterval,
                              frame: MascotFrame) -> [[String: Any]] {
        let mascot = frameElements(frame)

        // ---- auth-degraded frame (no snapshot at all) ----
        guard let snap else {
            return frontBars(nil, now: now, fresh: false)
                + backPanel(act, sess: BackRow(reset: "AUTH EXPIRED - RUN claude"),
                            week: BackRow())
                + mascot
        }

        let five = snap.fivePct, week = snap.weekPct

        // ---- stale frame (last good snapshot older than 15 min) ----
        if now - snap.fetchedAt > staleSeconds {
            let stale = "STALE \(Int((now - snap.fetchedAt) / 60))m"
            return frontBars(snap, now: now, fresh: false)
                + backPanel(act,
                            sess: BackRow(pct: pct(five), pctColor: limitColor(five),
                                          reset: stale, fill: five, fillColor: limitColor(five)),
                            week: BackRow(pct: pct(week), pctColor: limitColor(week),
                                          reset: stale, fill: week, fillColor: limitColor(week)))
                + mascot
        }

        // ---- normal frame ----
        var sessReset = "resets \(fmtAbs(snap.fiveResets, weekly: false))"
        if five > 75 {
            sessReset += " " + fmtRelLong(snap.fiveResets.timeIntervalSince1970 - now)
        }
        var weekReset = "resets \(fmtAbs(snap.weekResets, weekly: true))"
        if week > 75 {
            weekReset += " " + fmtRelWeekLong(snap.weekResets.timeIntervalSince1970 - now)
        }
        return frontBars(snap, now: now, fresh: true)
            + backPanel(act,
                        sess: BackRow(pct: pct(five), pctColor: limitColor(five),
                                      reset: sessReset, fill: five, fillColor: limitColor(five)),
                        week: BackRow(pct: pct(week), pctColor: limitColor(week),
                                      reset: weekReset, fill: week, fillColor: limitColor(week)))
            + mascot
    }
}

struct ClaudeSettingsView: View {
    @AppStorage("claude.poll") private var poll = 180.0
    @AppStorage("claude.priority") private var priority = 20
    @AppStorage("claude.mock") private var mock = false
    @AppStorage("claude.mockUsage") private var mockUsage = "60,70"
    @AppStorage(ClaudeApp.bookmarkKey) private var bookmark = Data()

    var body: some View {
        Form {
            TextField("Refresh every (s)", value: $poll, format: .number)
            TextField("Priority (1-100)", value: $priority, format: .number)
            Toggle("Mock usage (no credentials)", isOn: $mock)
            TextField("Mock five,week", text: $mockUsage)
                .disabled(!mock)
            VStack(alignment: .leading, spacing: 2) {
                Button("Grant access to ~/.claude", action: grantAccess)
                if bookmark.isEmpty {
                    Text("needed to read usage credentials and live sessions")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("access granted").font(.caption).foregroundStyle(.green)
                }
            }
        }
        .frame(width: 220)
    }

    /// The sandbox only reaches ~/.claude through a folder the user picks themselves;
    /// the security-scoped bookmark is what survives a relaunch.
    private func grantAccess() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.message = "Select your ~/.claude folder so Claude Limits can read the usage credentials and session activity."
        panel.prompt = "Grant Access"
        // NSHomeDirectory() is the sandbox container, so ask the password database for
        // the real home. This only seeds the panel — the grant is the user's click.
        if let pw = getpwuid(getuid()) {
            panel.directoryURL = URL(fileURLWithPath: String(cString: pw.pointee.pw_dir))
                .appendingPathComponent(".claude")
        }
        guard panel.runModal() == .OK, let url = panel.url,
              let data = try? url.bookmarkData(options: .withSecurityScope,
                                               includingResourceValuesForKeys: nil,
                                               relativeTo: nil)
        else { return }
        bookmark = data
    }
}
