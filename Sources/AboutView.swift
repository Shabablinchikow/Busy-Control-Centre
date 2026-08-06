import SwiftUI

/// Plain AppKit window: the About panel should float free of the main scene.
@MainActor
enum AboutWindow {
    private static var window: NSWindow?

    static func show() {
        if let window { window.makeKeyAndOrderFront(nil); return }
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 560),
                         styleMask: [.titled, .closable, .resizable],
                         backing: .buffered, defer: false)
        w.title = "About"
        w.contentView = NSHostingView(rootView: AboutView().scrollable)
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
                portedWidgets
                credit("pISS Stream", "Inspired by pISSStream by Jaennaet. ISS telemetry courtesy of NASA.",
                       link: "https://github.com/Jaennaet/pISSStream")
                credit("Weather data", "Open-Meteo, licensed CC-BY-4.0.",
                       link: "https://open-meteo.com/")
                credit("Data sources",
                       "wheretheiss.at · adsb.fi · adsbdb.com · Yahoo Finance · YouTube Data API",
                       link: nil)
            }

            Divider()
            Text("Not affiliated with or endorsed by BUSY.")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(width: 420)
    }

    /// Scrolls, so adding a credit can never silently clip the bottom of a
    /// fixed-size window.
    var scrollable: some View {
        ScrollView { body.frame(maxWidth: .infinity, alignment: .leading) }
    }

    /// Each ported widget credited to its own author, rather than one blanket
    /// line: five happen to share an author, but that is a fact about the gallery,
    /// not something the credits should assume. Kept as a list because the credit
    /// Group is limited to ten children.
    private static let ported: [(widget: String, author: String, source: String)] = [
        ("Clock", "Max Swinkels (@maxswinkels)",
         "https://github.com/maxswinkels/busybar-apps/tree/main/apps/clock"),
        ("Nyan Cat", "Max Swinkels (@maxswinkels)",
         "https://github.com/maxswinkels/busybar-apps/tree/main/apps/nyan-cat"),
        ("ISS Alert", "Max Swinkels (@maxswinkels)",
         "https://github.com/maxswinkels/busybar-apps/tree/main/apps/iss-alert"),
        ("Music", "Max Swinkels (@maxswinkels)",
         "https://github.com/maxswinkels/busybar-apps/tree/main/apps/audio-visualizer"),
        ("Flightradar", "Max Swinkels (@maxswinkels)",
         "https://github.com/maxswinkels/busybar-apps/tree/main/apps/flightradar"),
        ("Claude Limits", "Kiryl (@rbhbokka)",
         "https://github.com/rbhbokka/busybar-limits"),
    ]

    @ViewBuilder
    private var portedWidgets: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Ported widgets").font(.callout.weight(.medium))
            Text("Swift ports of MIT-licensed apps from the BUSY Bar Apps gallery. Full notices in THIRD-PARTY.md.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(Self.ported, id: \.widget) { p in
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(p.widget).font(.caption.weight(.medium))
                    if let url = URL(string: p.source) {
                        Link(p.author, destination: url).font(.caption)
                    } else {
                        Text(p.author).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Link("maxswinkels.github.io/busybar-apps",
                 destination: URL(string: "https://maxswinkels.github.io/busybar-apps/")!)
                .font(.caption)
        }
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
