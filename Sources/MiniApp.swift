import SwiftUI

/// One ported python script. `run` loops until its Task is cancelled and must
/// release the display (client.clear) on the way out. Config is read from
/// UserDefaults (@AppStorage keys) at the start of `run`.
protocol MiniApp {
    init()
    func run(client: BarClient, status: @escaping @Sendable (String) -> Void) async
}

struct AppEntry: Identifiable {
    let id: String        // application_name on the device
    let name: String
    let blurb: String
    let symbol: String    // SF Symbol for the row
    let make: () -> any MiniApp
    var settings: (() -> AnyView)?
    var exclusive = true  // false: a monitor that runs alongside the active widget
}

@MainActor
final class Runner: ObservableObject {
    @Published var running: Set<String> = []
    @Published var status: [String: String] = [:]
    private var tasks: [String: Task<Void, Never>] = [:]

    func isRunning(_ id: String) -> Bool { running.contains(id) }

    private static let savedKey = "runningApps"

    private func persist() {
        UserDefaults.standard.set(Array(running), forKey: Self.savedKey)
    }

    /// Restore the toggles that were on when the app last quit, then adopt any
    /// session already running on the bar (started before launch, or by the bar
    /// itself) so the UI matches reality instead of silently disagreeing with it.
    func restore() {
        // Release anything this app still owns on the bar from a previous run.
        // Quitting kills the widget tasks without a clear, and the canvas keeps
        // both the elements *and* the priority of whoever drew last — so a widget
        // left over from an older build, drawing at a higher priority than we use
        // now, would refuse every draw we make until something cleared it.
        Task {
            let client = Self.makeClient()
            for entry in registry { await client.clear(app: entry.id) }
            await MainActor.run { self.restoreSaved() }
        }
        Task { await adoptDeviceSession() }
    }

    private func restoreSaved() {
        for id in UserDefaults.standard.stringArray(forKey: Self.savedKey) ?? [] {
            if let entry = registry.first(where: { $0.id == id }), !isRunning(id) {
                start(entry)
            }
        }
    }

    private func adoptDeviceSession() async {
        let client = Self.makeClient()
        guard let snap = (try? await client.busySnapshot())?["snapshot"] as? [String: Any],
              let type = snap["type"] as? String else { return }
        let id: String? = switch type {
        case "SIMPLE": "focus-timer"
        case "INTERVAL": "pomodoro"
        default: nil  // INFINITE is On Call's own banner, nothing to adopt
        }
        if let id, !isRunning(id), let entry = registry.first(where: { $0.id == id }) {
            start(entry)
        }
    }

    func toggle(_ entry: AppEntry) {
        if isRunning(entry.id) { stop(entry.id) } else { start(entry) }
    }

    func start(_ entry: AppEntry) {
        if entry.exclusive {  // the bar shows one widget at a time; monitors coexist
            for id in Array(running)
            where registry.first(where: { $0.id == id })?.exclusive ?? true {
                stop(id)
            }
        }
        let client = Self.makeClient()
        let app = entry.make()
        let id = entry.id
        running.insert(id)
        persist()
        status[id] = "starting…"
        tasks[id] = Task.detached {
            // Always start from an empty display of our own. Elements persist on
            // the device by id until something overwrites them, and quitting the
            // app kills these tasks without a clear — so a widget that was
            // mid-animation leaves elements its ordinary frame has no id for and
            // can never overwrite.
            //
            // Nothing is drawn over the top of it either: the widget's own first
            // frame arrives immediately, because `WebCache` still holds the data
            // it fetched a moment ago.
            await client.clear(app: id)
            await app.run(client: client) { msg in
                barLog.info("\(id, privacy: .public): \(msg, privacy: .public)")
                Task { @MainActor in Self.shared?.status[id] = msg }
            }
            await MainActor.run {
                Self.shared?.running.remove(id)
                Self.shared?.tasks[id] = nil
                Self.shared?.persist()
            }
        }
    }

    func stop(_ id: String) {
        guard let task = tasks[id] else { return }
        task.cancel()
        status[id] = "stopping…"
        // The app's own clear() runs inside the cancelled task, where URLSession
        // throws immediately — so it never reaches the device. Wait for the loop
        // to exit, then clear from a live task or the bar stays busy (409).
        let client = Self.makeClient()
        Task {
            await task.value
            await client.clear(app: id)
        }
    }

    private static func makeClient() -> BarClient {
        let host = UserDefaults.standard.string(forKey: "host") ?? "10.0.4.20"
        let token = UserDefaults.standard.string(forKey: "accessKey")
        return BarClient(host: host, token: token)
    }

    func stopAll() { for id in Array(running) { stop(id) } }

    // ponytail: single shared instance instead of weak-self plumbing through Sendable closures
    static var shared: Runner?
    init() { Runner.shared = self }
}

/// Cancellation-aware sleep; returns false when the task was cancelled.
func barSleep(_ seconds: Double) async -> Bool {
    do { try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)); return true }
    catch { return false }
}
