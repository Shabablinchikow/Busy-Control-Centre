import SwiftUI

/// Which widgets the main window lists. Hidden ids are persisted rather than
/// shown ones, so a widget added in a later version appears by default instead
/// of being silently invisible after an upgrade.
///
/// An ObservableObject, not a bare UserDefaults read, because the main window
/// has to redraw its list when the Widgets window ticks a box.
@MainActor
final class WidgetVisibility: ObservableObject {
    private static let key = "widgets.hidden"

    @Published private(set) var hidden: Set<String>

    init() {
        hidden = Set(UserDefaults.standard.stringArray(forKey: Self.key) ?? [])
    }

    var visible: [AppEntry] { registry.filter { !hidden.contains($0.id) } }

    func isVisible(_ id: String) -> Bool { !hidden.contains(id) }

    func setVisible(_ id: String, _ show: Bool) {
        if show { hidden.remove(id) } else { hidden.insert(id) }
        UserDefaults.standard.set(Array(hidden), forKey: Self.key)
    }
}

struct WidgetsView: View {
    @EnvironmentObject var visibility: WidgetVisibility
    @EnvironmentObject var runner: Runner

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Widgets on the main screen").font(.headline)
            Text("Unticked widgets are removed from the list. Switching one off stops it if it is running. The carousel keeps its own separate selection.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Divider()
            ForEach(registry) { entry in
                Toggle(isOn: Binding(
                    get: { visibility.isVisible(entry.id) },
                    set: { show in
                        visibility.setVisible(entry.id, show)
                        // A hidden widget has no row left to switch it off, so
                        // it would otherwise keep drawing to the bar forever.
                        if !show, runner.isRunning(entry.id) { runner.stop(entry.id) }
                    })) {
                    Label(entry.name, systemImage: entry.symbol)
                }
                .toggleStyle(.checkbox)
            }
        }
        .padding(16)
        .frame(width: 320)
    }
}
