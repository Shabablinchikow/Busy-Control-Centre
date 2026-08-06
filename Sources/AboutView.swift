import SwiftUI

/// Plain AppKit window: the About panel should float free of the main scene.
@MainActor
enum AboutWindow {
    private static var window: NSWindow?

    static func show() {
        if let window { window.makeKeyAndOrderFront(nil); return }
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 400),
                         styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = "About"
        w.contentView = NSHostingView(rootView: AboutView())
        w.isReleasedWhenClosed = false
        w.center()
        w.makeKeyAndOrderFront(nil)
        window = w
    }
}

struct AboutView: View {
    private var version: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "Version \(v) (\(b))"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable().frame(width: 56, height: 56)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Busy Control Centre").font(.title3.weight(.semibold))
                    Text(version).font(.caption).foregroundStyle(.secondary)
                    Text("Widgets, focus sessions and a display mirror for the BUSY Bar.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            Divider()

            Group {
                credit("This app", "MIT License · © 2026 Aleksei Shabalin",
                       link: "https://github.com/Shabablinchikow/Busy-Control-Centre")
                credit("Banner artwork", """
                    Frames from the BUSY Bar firmware animations \
                    (assets/shared/animations), © 2024–2026 Flipper FZCO, \
                    licensed CC-BY-SA-4.0.
                    """, link: "https://github.com/busy-app/busybar-firmware")
                credit("pISS Stream", "Inspired by pISSStream by Jaennaet. ISS telemetry courtesy of NASA.",
                       link: "https://github.com/Jaennaet/pISSStream")
                credit("Data sources", "wheretheiss.at · adsb.fi · adsbdb.com",
                       link: nil)
            }

            Divider()
            Text("Not affiliated with or endorsed by BUSY.")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(width: 420)
    }

    @ViewBuilder
    private func credit(_ title: String, _ body: String, link: String?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.callout.weight(.medium))
            Text(body).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let link, let url = URL(string: link) {
                Link(link.replacingOccurrences(of: "https://", with: ""), destination: url)
                    .font(.caption)
            }
        }
    }
}
