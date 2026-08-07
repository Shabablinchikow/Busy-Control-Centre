import Foundation

/// Port of clock.py — big time, refreshed every second.
final class ClockApp: MiniApp {
    let app = "clock"

    func run(client: BarClient, status: @escaping @Sendable (String) -> Void) async {
        let fmt = DateFormatter()
        fmt.dateFormat = "HH:mm:ss"
        while !Task.isCancelled {
            let hhmm = fmt.string(from: Date())
            do {
                // align lets the device place the text without measuring width;
                // 409 means a higher-priority app owns the screen — keep ticking.
                let code = try await client.draw(app: app, elements: [
                    textEl("0", hhmm, x: 36, y: 15, font: "extra_large", align: "bottom_mid")
                ])
                status(code == 409 ? "paused — bar in use" : hhmm)
            } catch {
                status("cannot reach \(client.base.host ?? "?"): \(error.localizedDescription)")
            }
            if !(await barSleep(1.0)) { break }
        }
        await client.clear(app: app)
    }
}
