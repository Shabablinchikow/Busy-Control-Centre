import SwiftUI
import AppKit

/// Unread count of Apple Mail's unified inbox, over AppleScript.
///
/// There is no read-only API for this. The Envelope Index SQLite file holds the
/// same number, but it is ~230 MB in WAL mode and outside the sandbox, so
/// AppleScript is both cheaper and the only route that reports live state.
final class MailApp: MiniApp {
    let app = "mail"

    static let mailBundleID = "com.apple.mail"
    static let script = "tell application \"Mail\" to get unread count of inbox"

    static let ink = "#FFFFFFFF"
    static let dim = "#8A8A8AFF"
    static let alert = "#4FA8FFFF"

    static let yLine1 = 0
    static let yLine2 = 8
    static let xRight = 73
    static let iconX = 0
    static let iconY = 4
    static let xText = 12

    /// 8x8, a closed envelope.
    static let envelope = ["########",
                           "##    ##",
                           "# #  # #",
                           "#  ##  #",
                           "#      #",
                           "#      #",
                           "#      #",
                           "########"]

    enum MailError: Error { case notRunning, refused(String) }

    // MARK: - Main loop

    func run(client: BarClient, status: @escaping @Sendable (String) -> Void) async {
        let interval = max(5, UserDefaults.standard.object(forKey: "mail.interval") as? Double ?? 30)

        while !Task.isCancelled {
            do {
                let count = try await Self.unreadCount()
                let code = try await client.draw(app: app, elements: Self.frame(count),
                                                 priority: 60)
                status(code == 409 ? "display busy" : Self.statusLine(count))
            } catch MailError.notRunning {
                // Never start Mail to read it: an Apple event to a quit app
                // launches it, which is not something a status widget should do.
                status("Mail is not running")
            } catch {
                status("Mail: \(error.localizedDescription)")
            }
            if !(await barSleep(interval)) { break }
        }
        await client.clear(app: app)
    }

    // MARK: - Data

    /// NSAppleScript is not Sendable and wants a main-thread run loop, so the
    /// query hops to the MainActor rather than executing on the widget's task.
    @MainActor
    static func unreadCount() throws -> Int {
        guard isMailRunning() else { throw MailError.notRunning }
        var err: NSDictionary?
        let result = NSAppleScript(source: script)?.executeAndReturnError(&err)
        if let err {
            // -1743 is the Automation denial; anything else is Mail complaining.
            throw MailError.refused(err[NSAppleScript.errorMessage] as? String
                                    ?? "AppleScript error \(err[NSAppleScript.errorNumber] ?? "?")")
        }
        return Int(result?.int32Value ?? 0)
    }

    /// Same check MusicApp uses before assuming its target app exists.
    @MainActor
    static func isMailRunning() -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: mailBundleID).isEmpty
    }

    // MARK: - Pure helpers

    /// Zero inbox earns a message rather than a bare "0", and rather than the
    /// widget going dark and looking broken.
    static func isZero(_ count: Int) -> Bool { count <= 0 }

    static func statusLine(_ count: Int) -> String {
        isZero(count) ? "zero inbox" : "\(count) unread"
    }

    // MARK: - Frame

    static func frame(_ count: Int) -> [[String: Any]] {
        // 13 characters at ~4px is ~52px, inside the 72px display.
        if isZero(count) {
            return Glyph.els("env", envelope, x: iconX, y: iconY,
                             color: "#000000FF", slots: Glyph.iconSlots)
                + [textEl("count", "", x: xText, y: yLine1, font: "small",
                          color: ink, align: "top_left"),
                   textEl("zero", "ZERO INBOX =)", x: 0, y: yLine2, font: "small",
                          color: dim, align: "top_left")]
        }
        return Glyph.els("env", envelope, x: iconX, y: iconY,
                         color: alert, slots: Glyph.iconSlots)
            + [textEl("count", "\(count)", x: xText, y: yLine1, font: "small",
                      color: ink, align: "top_left"),
               textEl("zero", "unread", x: xRight, y: yLine2, font: "small",
                      color: dim, align: "top_right")]
    }

    #if DEBUG
    static func selfCheck() {
        assert(isZero(0) && isZero(-1), "nothing unread, however it is reported")
        assert(!isZero(1), "one unread is not zero")
        assert(statusLine(0) == "zero inbox" && statusLine(3) == "3 unread", "status text")

        // Both branches must emit the same element ids, or switching between them
        // leaves the other branch's elements on the bar for good.
        let ids = { (els: [[String: Any]]) in Set(els.compactMap { $0["id"] as? String }) }
        assert(ids(frame(0)) == ids(frame(5)),
               "zero and non-zero frames cover the same element ids")
        assert(Glyph.runs(envelope).count <= Glyph.iconSlots, "the envelope fits its slots")
    }
    #endif
}

struct MailSettingsView: View {
    @AppStorage("mail.interval") private var interval = 30.0

    var body: some View {
        Form {
            TextField("Check every (s)", value: $interval, format: .number)
            Text("Reads the unified inbox from Apple Mail, which macOS asks you to allow the first time. Mail has to be running already — this never launches it.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(width: 280)
    }
}
