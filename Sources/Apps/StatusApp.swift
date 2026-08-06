import SwiftUI

/// Pins a banner on the bar until switched off — an untimed focus session, so
/// it sits at session priority above every widget and above a running timer.
/// On Call still wins while the mic is live and puts this back afterwards.
final class StatusApp: MiniApp {
    let app = "status"

    func run(client: BarClient, status: @escaping @Sendable (String) -> Void) async {
        let d = UserDefaults.standard
        let theme = d.string(forKey: "status.theme") ?? "busy"
        let smartHome = d.object(forKey: "status.smartHome") as? Bool ?? false
        let title = Banner.title(theme)

        do {
            let code = try await client.setBusySession(theme: theme, running: true,
                                                       triggerSmartHome: smartHome)
            guard (200..<300).contains(code) else {
                status("the bar refused the banner (HTTP \(code))")
                return
            }
        } catch {
            status("cannot reach \(client.base.host ?? "?"): \(error.localizedDescription)")
            return
        }
        status("showing \(title)")

        // Watch rather than fire-and-forget, so the row reflects the mic taking
        // over and the user ending the session on the device itself.
        while !Task.isCancelled {
            if !(await barSleep(5)) { break }
            let snap = (try? await client.busySnapshot())?["snapshot"] as? [String: Any]
            switch snap?["type"] as? String {
            case "INFINITE":
                let live = (snap?["busy_bar_settings"] as? [String: Any])?["theme"] as? String
                status(live == theme ? "showing \(title)" : "\(Banner.title(live ?? "")) — taken over")
            case "NOT_STARTED":
                status("cleared on the bar")
                return   // the toggle flips off once run() returns
            case nil:
                status("cannot reach \(client.base.host ?? "?")")
            default:
                status("a timer owns the bar — waiting")
            }
        }
        await Self.clear(client, theme: theme, smartHome: smartHome)
    }

    /// Ends the session only if it is still ours: same INFINITE type *and* the
    /// theme we set, so switching off never blanks an On Call banner or a timer.
    ///
    /// Detached because the Runner has already cancelled our task by now and
    /// URLSession will not send from a cancelled one.
    private static func clear(_ client: BarClient, theme: String, smartHome: Bool) async {
        await Task.detached {
            let snap = (try? await client.busySnapshot())?["snapshot"] as? [String: Any]
            guard (snap?["type"] as? String) == "INFINITE",
                  (snap?["busy_bar_settings"] as? [String: Any])?["theme"] as? String == theme
            else { return }
            _ = try? await client.setBusySession(theme: theme, running: false,
                                                 triggerSmartHome: smartHome)
        }.value
    }
}

struct StatusSettingsView: View {
    @AppStorage("status.theme") private var theme = "busy"
    @AppStorage("status.smartHome") private var smartHome = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            BannerPicker(selection: $theme, label: "Banner to display until switched off")
            Toggle("Trigger smart home scene", isOn: $smartHome)
                .font(.callout)
        }
        .frame(width: 340)
    }
}
