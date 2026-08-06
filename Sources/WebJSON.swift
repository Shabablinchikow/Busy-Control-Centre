import Foundation

enum WebError: Error { case http(Int), notFound, bad }

/// Answers kept briefly so a widget that comes back — the carousel stepping onto
/// it, or you toggling it — draws from what it already knows instead of sitting
/// blank through a fetch. Only successful GETs of the open web go in here; the
/// device's own traffic does not.
///
/// ponytail: dictionary keyed by URL, no eviction beyond the TTL check on read.
/// A handful of widgets poll a handful of endpoints; a real cache would be more
/// code than the thing it caches.
actor WebCache {
    static let shared = WebCache()
    /// Long enough to cover a carousel lap, short enough that nothing shown is
    /// meaningfully out of date. Weather advances every 900s, quotes every 60.
    static let ttl = 90.0

    private var entries: [URL: (at: Double, json: [String: Any])] = [:]

    func get(_ url: URL, now: Double) -> [String: Any]? {
        guard let e = entries[url], now - e.at < Self.ttl else { return nil }
        return e.json
    }

    func put(_ url: URL, _ json: [String: Any], now: Double) {
        entries[url] = (now, json)
    }
}

/// GET a JSON object from the open web. `FlightradarApp` and `ISSApp` predate
/// this and keep their own copies; three of the newer widgets share this one.
///
/// Deliberately not on `BarClient`: that talks to the device, over a session
/// pinned to one connection per host, which has nothing to do with these.
///
/// `fresh: true` skips the cache — for the poll loop, which wants the new
/// reading, not the one it already drew.
func fetchJSON(_ url: URL, userAgent: String, timeout: Double = 10,
               fresh: Bool = false) async throws -> [String: Any] {
    let now = Date().timeIntervalSince1970
    if !fresh, let hit = await WebCache.shared.get(url, now: now) { return hit }
    var req = URLRequest(url: url)
    req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
    req.timeoutInterval = timeout
    let (data, resp) = try await URLSession.shared.data(for: req)
    let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
    if code == 404 { throw WebError.notFound }
    if code >= 400 { throw WebError.http(code) }
    let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
    await WebCache.shared.put(url, json, now: now)
    return json
}
