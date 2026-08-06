import SwiftUI

/// Pomodoro on top of the bar's built-in INTERVAL session: we PUT the work/rest
/// plan once and then only report what the device says. Autostart is on, so the
/// bar walks the cycles itself at session priority 90 — no drawing here either.
final class PomodoroApp: MiniApp {
    let app = "pomodoro"

    func run(client: BarClient, status: @escaping @Sendable (String) -> Void) async {
        let d = UserDefaults.standard
        let workMin = max(1, d.object(forKey: "pomo.work") as? Int ?? 25)
        let restMin = max(1, d.object(forKey: "pomo.rest") as? Int ?? 5)
        let cycles = max(1, d.object(forKey: "pomo.cycles") as? Int ?? 4)
        let theme = d.string(forKey: "pomo.theme") ?? "coding"
        let smartHome = d.object(forKey: "pomo.smartHome") as? Bool ?? false
        let workMs = workMin * 60_000, restMs = restMin * 60_000

        // Adopt cycles that are already running rather than restarting at cycle 1.
        let live = (try? await client.busySnapshot())?["snapshot"] as? [String: Any]
        if (live?["type"] as? String) == "INTERVAL" {
            status("adopted — " + Self.phaseText(live ?? [:], fallbackCycles: cycles))
            await watch(client: client, cycles: cycles, theme: theme,
                        smartHome: smartHome, status: status)
            return
        }

        do {
            let code = try await putBusySnapshot(client, [
                "type": "INTERVAL",
                "card_id": busyCardID,
                "current_interval": 1,
                "current_interval_time_total_ms": workMs,
                "current_interval_time_left_ms": workMs,
                "is_paused": false,
                "interval_settings": [
                    "type": "INTERVAL",
                    "interval_work_ms": workMs,
                    "interval_rest_ms": restMs,
                    "interval_work_cycles_count": cycles,
                    "is_autostart_enabled": true,
                ],
                "busy_bar_settings": busyBarSettings(theme: theme, smartHome: smartHome),
            ])
            guard (200..<300).contains(code) else {
                status("the bar refused the pomodoro (HTTP \(code))")
                return
            }
        } catch {
            status("cannot reach \(client.base.host ?? "?"): \(error.localizedDescription)")
            return
        }
        status("work \(focusClock(workMs)) — cycle 1/\(cycles)")
        await watch(client: client, cycles: cycles, theme: theme,
                    smartHome: smartHome, status: status)
    }

    /// Follows the session until it ends or the toggle is switched off.
    private func watch(client: BarClient, cycles: Int, theme: String, smartHome: Bool,
                       status: @escaping @Sendable (String) -> Void) async {
        while !Task.isCancelled {
            if !(await barSleep(5)) { break }
            let snap = (try? await client.busySnapshot())?["snapshot"] as? [String: Any]
            switch snap?["type"] as? String {
            case "INTERVAL":
                status(Self.phaseText(snap ?? [:], fallbackCycles: cycles))
            case "NOT_STARTED":
                status("pomodoro finished")
                return   // the toggle flips off once run() returns
            case nil:
                status("cannot reach \(client.base.host ?? "?")")
            default:
                // The On Call app takes the session over while the mic is live
                // and restores it afterwards — keep watching rather than bailing.
                status("session taken over — waiting")
            }
        }
        await stopBusySession(client, ifType: "INTERVAL", theme: theme, smartHome: smartHome)
    }

    /// "work 24:31 — cycle 1/4".
    ///
    /// The schema doesn't spell out what `current_interval` counts, so the
    /// assumption is: a 1-based index over alternating phases — 1 = work of
    /// cycle 1, 2 = its rest, 3 = work of cycle 2 … hence odd = work and
    /// cycle = (n + 1) / 2. When work and rest lengths differ,
    /// `current_interval_time_total_ms` identifies the phase outright, so that
    /// wins and the parity rule is only the tiebreak for equal-length phases.
    static func phaseText(_ snap: [String: Any], fallbackCycles: Int) -> String {
        let n = max(1, snap["current_interval"] as? Int ?? 1)
        let total = snap["current_interval_time_total_ms"] as? Int ?? 0
        let left = snap["current_interval_time_left_ms"] as? Int ?? 0
        let iv = snap["interval_settings"] as? [String: Any]
        let workMs = iv?["interval_work_ms"] as? Int ?? 0
        let restMs = iv?["interval_rest_ms"] as? Int ?? 0
        let cycles = iv?["interval_work_cycles_count"] as? Int ?? fallbackCycles

        let isWork = workMs == restMs ? (n % 2 == 1) : (total == workMs)
        let paused = (snap["is_paused"] as? Bool) ?? false
        return "\(isWork ? "work" : "rest") \(focusClock(left))\(paused ? " (paused)" : "")"
            + " — cycle \((n + 1) / 2)/\(cycles)"
    }
}

struct PomodoroSettingsView: View {
    @AppStorage("pomo.work") private var work = 25
    @AppStorage("pomo.rest") private var rest = 5
    @AppStorage("pomo.cycles") private var cycles = 4
    @AppStorage("pomo.theme") private var theme = "coding"
    @AppStorage("pomo.smartHome") private var smartHome = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            row("Work", value: $work, range: 1...180, unit: "min")
            row("Rest", value: $rest, range: 1...60, unit: "min")
            row("Cycles", value: $cycles, range: 1...12, unit: "×")
            BannerPicker(selection: $theme)
            Toggle("Trigger smart home scene", isOn: $smartHome)
                .font(.callout)
            Text("The bar runs the cycles itself and autostarts each phase.")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .frame(width: 300)
    }

    private func row(_ label: String, value: Binding<Int>, range: ClosedRange<Int>, unit: String) -> some View {
        Stepper(value: value, in: range) {
            HStack {
                Text(label)
                Spacer()
                Text("\(value.wrappedValue) \(unit)").monospacedDigit().foregroundStyle(.secondary)
            }
        }
    }
}
