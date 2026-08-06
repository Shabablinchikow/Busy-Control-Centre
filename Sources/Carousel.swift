import SwiftUI

/// Rotates the bar through a chosen set of widgets on a timer. Membership is
/// deliberately independent of what the main window lists — the two are separate
/// features — so the main window carries a status row naming the current member.
@MainActor
final class Carousel: ObservableObject {
    private static let membersKey = "carousel.members"
    private static let intervalKey = "carousel.interval"
    private static let enabledKey = "carousel.enabled"

    /// Below ~5s several widgets never finish their first fetch (Flightradar
    /// polls every 15s, Claude Limits reads files, Music only learns state on the
    /// next play/pause), so a shorter rotation just shows blanks.
    static let minInterval = 5.0
    static let defaultInterval = 30.0

    @Published private(set) var members: Set<String>
    @Published private(set) var running = false
    @Published private(set) var current: String?   // widget id on the bar now
    @Published private(set) var note: String?
    @Published var interval: Double {
        didSet { UserDefaults.standard.set(interval, forKey: Self.intervalKey) }
    }

    private var task: Task<Void, Never>?

    init() {
        let d = UserDefaults.standard
        members = Set(d.stringArray(forKey: Self.membersKey) ?? [])
        interval = d.object(forKey: Self.intervalKey) as? Double ?? Self.defaultInterval
    }

    // MARK: - Membership

    func isMember(_ id: String) -> Bool { members.contains(id) }

    func setMember(_ id: String, _ on: Bool) {
        if on { members.insert(id) } else { members.remove(id) }
        UserDefaults.standard.set(Array(members), forKey: Self.membersKey)
    }

    // MARK: - Rotation order (pure)

    /// Members as entries, in registry order, dropping ids no longer shipped.
    static func rotation(_ members: Set<String>) -> [AppEntry] {
        registry.filter { members.contains($0.id) }
    }

    /// The member after `previous`, wrapping. An unknown or nil `previous`
    /// (first step, or the current member was just unticked) starts at the top.
    static func next(after previous: String?, in list: [AppEntry]) -> AppEntry? {
        guard !list.isEmpty else { return nil }
        let i = previous.flatMap { p in list.firstIndex { $0.id == p } }
        return list[((i ?? -1) + 1) % list.count]
    }

    // MARK: - Run control

    func toggle() { running ? stop() : start() }

    func start() {
        guard !running else { return }
        guard !Self.rotation(members).isEmpty else {
            note = "tick at least one widget below"
            return
        }
        note = nil
        running = true
        UserDefaults.standard.set(true, forKey: Self.enabledKey)
        task = Task { await loop() }
    }

    /// Cancels the rotation only. The member currently on the bar keeps running,
    /// so switching the carousel off leaves you looking at whatever you liked.
    func stop() {
        task?.cancel()
        task = nil
        running = false
        current = nil
        UserDefaults.standard.set(false, forKey: Self.enabledKey)
    }

    func restore() {
        if UserDefaults.standard.bool(forKey: Self.enabledKey) { start() }
    }

    private func loop() async {
        var previous: String?
        while !Task.isCancelled {
            let list = Self.rotation(members)
            guard let entry = Self.next(after: previous, in: list) else {
                note = "tick at least one widget below"
                stop()
                return
            }
            // Stop the outgoing member explicitly: Status, Timer, Pomodoro and
            // On Call are exclusive:false so they coexist with the active widget,
            // which means Runner.start would never evict them and they would
            // pile up on the bar.
            if let previous, previous != entry.id { Runner.shared?.stop(previous) }
            Runner.shared?.start(entry)
            previous = entry.id
            current = entry.id
            if !(await barSleep(max(Self.minInterval, interval))) { break }
        }
    }

    #if DEBUG
    /// ponytail: assert-based check instead of a test target — the project ships
    /// no test bundle and "system frameworks only" rules out adding one.
    static func selfCheck() {
        let three = Array(registry.prefix(3)).map(\.id)
        let list = rotation(Set(three))
        assert(list.map(\.id) == three, "rotation follows registry order")
        assert(rotation(Set(three.reversed())).map(\.id) == three,
               "registry order, never Set iteration order")
        assert(next(after: nil, in: list)?.id == three[0], "starts at the first member")
        assert(next(after: three[0], in: list)?.id == three[1], "advances")
        assert(next(after: three[2], in: list)?.id == three[0], "wraps")
        assert(next(after: "unticked-mid-rotation", in: list)?.id == three[0],
               "an unknown previous restarts at the top")
        assert(next(after: nil, in: []) == nil, "an empty rotation has no next")
        assert(rotation(["not-a-widget"]).isEmpty, "unknown ids are dropped")
    }
    #endif
}

struct CarouselView: View {
    @EnvironmentObject var carousel: Carousel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Carousel").font(.headline)
            Text("Cycles the bar through the ticked widgets. Toggling a widget by hand on the main screen switches the carousel off.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Toggle("Run carousel", isOn: Binding(
                    get: { carousel.running }, set: { _ in carousel.toggle() }))
                    .toggleStyle(.switch)
                Spacer()
                Text("every")
                TextField("", value: $carousel.interval, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 50)
                Text("s")
            }
            if carousel.interval < Carousel.minInterval {
                Text("Minimum \(Int(Carousel.minInterval)) s — shorter and most widgets never finish their first fetch.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let note = carousel.note {
                Text(note).font(.caption).foregroundStyle(.orange)
            }
            Divider()
            ForEach(registry) { entry in
                Toggle(isOn: Binding(
                    get: { carousel.isMember(entry.id) },
                    set: { carousel.setMember(entry.id, $0) })) {
                    Label(entry.name, systemImage: entry.symbol)
                }
                .toggleStyle(.checkbox)
            }
        }
        .padding(16)
        .frame(width: 340)
    }
}

/// The main window's one-line carousel control: start/stop it and see what is up
/// without opening its window.
struct CarouselRow: View {
    @EnvironmentObject var carousel: Carousel

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.trianglehead.2.clockwise.rotate.90")
                .foregroundStyle(carousel.running ? Color.accentColor : .secondary)
            Text("Carousel").font(.callout)
            if carousel.running {
                Text(currentName).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("", isOn: Binding(
                get: { carousel.running }, set: { _ in carousel.toggle() }))
                .toggleStyle(.switch)
                .labelsHidden()
        }
    }

    private var currentName: String {
        guard let id = carousel.current,
              let entry = registry.first(where: { $0.id == id }) else { return "starting…" }
        return "showing \(entry.name), every \(Int(max(Carousel.minInterval, carousel.interval)))s"
    }
}
