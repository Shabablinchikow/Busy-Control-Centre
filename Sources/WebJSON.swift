import Foundation

enum WebError: Error { case http(Int), notFound, bad }

/// GET a JSON object from the open web. `FlightradarApp` and `ISSApp` predate
/// this and keep their own copies; three of the newer widgets share this one.
///
/// Deliberately not on `BarClient`: that talks to the device, over a session
/// pinned to one connection per host, which has nothing to do with these.
func fetchJSON(_ url: URL, userAgent: String, timeout: Double = 10) async throws -> [String: Any] {
    var req = URLRequest(url: url)
    req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
    req.timeoutInterval = timeout
    let (data, resp) = try await URLSession.shared.data(for: req)
    let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
    if code == 404 { throw WebError.notFound }
    if code >= 400 { throw WebError.http(code) }
    return try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
}
