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
    /// Targeted by bundle id, not by name. `tell application "Mail"` fails from
    /// inside the sandbox with -600 "Application isn't running" even while Mail
    /// is running and visible to NSRunningApplication: it is the name lookup that
    /// is blocked, not the process. `application id` skips that lookup.
    static let script = "tell application id \"com.apple.mail\" to get unread count of inbox"

    static let ink = "#FFFFFFFF"
    static let dim = "#8A8A8AFF"
    static let alert = "#4FA8FFFF"

    static let iconX = 0
    static let iconY = 4
    /// Clear of the 8px icon, with a 4px gap.
    static let xText = 12
    /// One centred line rather than the usual two: there is only ever one thing
    /// to say here, so it sits on the icon's centreline instead of hanging off
    /// the top or bottom edge. Ink lands on rows 6-10 of the 16.
    static let yText = 4
    static let charW = 4

    /// 8x8, a closed envelope.
    static let envelope = ["########",
                           "##    ##",
                           "# #  # #",
                           "#  ##  #",
                           "#      #",
                           "#      #",
                           "#      #",
                           "########"]

    /// LocalizedError, not a bare Error: without it `localizedDescription` prints
    /// "MailError error 0" and throws away the reason Mail actually gave.
    enum MailError: LocalizedError {
        case notRunning
        case refused(code: Int, message: String)

        var errorDescription: String? {
            switch self {
            case .notRunning: return "Mail is not running"
            // -1743 is the Automation denial; the rest come from Mail itself.
            case .refused(let code, let message):
                switch code {
                case -1743:
                    return "not allowed to control Mail — approve it in Privacy & Security → Automation"
                // Seen when the sandbox blocks the target lookup rather than the
                // send; the entitlement in project.yml is what fixes it.
                case -600:
                    return "cannot reach Mail (-600) — check the app's Apple Events entitlement"
                default:
                    return "\(message) (\(code))"
                }
            }
        }
    }

    // MARK: - Main loop

    func run(client: BarClient, status: @escaping @Sendable (String) -> Void) async {
        let interval = max(5, UserDefaults.standard.object(forKey: "mail.interval") as? Double ?? 30)

        while !Task.isCancelled {
            do {
                let count = try await Self.unreadCount()
                let code = try await client.draw(app: app, elements: Self.frame(count),
                                                 priority: 60)
                status(code == 409 ? "display busy" : Self.statusLine(count))
            } catch {
                // Never start Mail to read it: an Apple event to a quit app
                // launches it, which is not something a status widget should do.
                // MailError describes itself, so no case-by-case handling here.
                status(error.localizedDescription)
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
            throw MailError.refused(
                code: (err[NSAppleScript.errorNumber] as? NSNumber)?.intValue ?? 0,
                message: err[NSAppleScript.errorMessage] as? String ?? "AppleScript failed")
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

    /// "ZERO INBOX =)" is 13 characters, ~52px, so from x=12 it ends at 64 —
    /// inside the 72px display.
    static func text(_ count: Int) -> String {
        isZero(count) ? "ZERO INBOX =)" : "\(count) unread"
    }

    /// Both states share one shape and one set of element ids: icon at the left,
    /// a single centred line beside it. Elements persist by id, so branches that
    /// emitted different ids would leave each other's leftovers on the bar.
    static func frame(_ count: Int) -> [[String: Any]] {
        Glyph.els("env", envelope, x: iconX, y: iconY,
                  color: isZero(count) ? dim : alert, slots: Glyph.iconSlots)
            + [textEl("line", text(count), x: xText, y: yText, font: "small",
                      color: isZero(count) ? dim : ink, align: "top_left")]
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
        assert(frame(0).count == frame(99999).count,
               "and the same element count, whatever the number")
        assert(Glyph.runs(envelope).count <= Glyph.iconSlots, "the envelope fits its slots")

        // The text starts clear of the icon and stays inside the display.
        assert(xText >= 8, "text starts clear of the 8px icon")
        assert(text(0) == "ZERO INBOX =)" && text(1) == "1 unread", "both messages")
        assert(xText + text(0).count * charW <= 72, "the zero-inbox message fits")
        assert(xText + text(9999).count * charW <= 72, "a four-digit count still fits")
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
