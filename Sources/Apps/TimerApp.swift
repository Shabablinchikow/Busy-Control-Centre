import SwiftUI

// MARK: - Shared focus-session plumbing (also used by PomodoroApp)

/// The "busy" profile slot. Clients render a session through the profile its
/// card_id names, so the snapshot type should match that profile's timer
/// settings: this slot is INTERVAL, which suits the pomodoro exactly.
///
/// A plain SIMPLE countdown has no matching profile — no slot ships with SIMPLE
/// settings — so the phone app may describe it oddly. The bar itself counts down
/// correctly either way, and rewriting a user's profile to fix a cosmetic label
/// elsewhere isn't worth it.
let busyCardID = "00000000-0000-0000-0000-000000000000"

func busyBarSettings(theme: String, smartHome: Bool) -> [String: Any] {
    ["theme": theme, "show_work_phase_only": false, "trigger_smart_home": smartHome]
}

/// PUT /api/busy/snapshot with an arbitrary snapshot. BarClient.setBusySession
/// only knows the INFINITE shape; the timers need SIMPLE and INTERVAL.
@discardableResult
func putBusySnapshot(_ client: BarClient, _ snapshot: [String: Any]) async throws -> Int {
    var req = URLRequest(url: client.base.appendingPathComponent("api/busy/snapshot"))
    req.httpMethod = "PUT"
    req.timeoutInterval = 8
    if let token = client.token { req.setValue(token, forHTTPHeaderField: "X-API-Token") }
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    req.httpBody = try JSONSerialization.data(withJSONObject: [
        "snapshot": snapshot,
        "snapshot_timestamp_ms": Int(Date().timeIntervalSince1970 * 1000),
    ])
    let (_, resp) = try await BarClient.session.data(for: req)
    return (resp as? HTTPURLResponse)?.statusCode ?? 0
}

/// Ends the session only when the live snapshot is still of type `ours` — the On
/// Call app (or the user) may own the session by now, and clobbering that would
/// blank their banner.
///
/// Runs detached on purpose: by the time `run` unwinds, the Runner has already
/// cancelled our task and URLSession refuses to send anything from a cancelled
/// one, so the stop would never reach the device.
func stopBusySession(_ client: BarClient, ifType ours: String, theme: String, smartHome: Bool) async {
    await Task.detached {
        let snap = (try? await client.busySnapshot())?["snapshot"] as? [String: Any]
        guard (snap?["type"] as? String) == ours else { return }
        _ = try? await putBusySnapshot(client, ["type": "NOT_STARTED",
                                                "busy_bar_settings": busyBarSettings(theme: theme,
                                                                                     smartHome: smartHome)])
    }.value
}

/// mm:ss, growing to h:mm:ss past an hour.
func focusClock(_ ms: Int) -> String {
    let s = max(0, ms) / 1000
    return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
                     : String(format: "%d:%02d", s / 60, s % 60)
}

// MARK: - Timer

/// Plain countdown driven by the bar's built-in focus session: we PUT a SIMPLE
/// snapshot and then just watch it. The device renders the themed banner and
/// counts down itself at session priority 90, above every widget, so there is no
/// drawing to do here.
final class TimerApp: MiniApp {
    let app = "focus-timer"

    func run(client: BarClient, status: @escaping @Sendable (String) -> Void) async {
        let d = UserDefaults.standard
        let minutes = max(1, d.object(forKey: "timer.minutes") as? Int ?? 25)
        let theme = d.string(forKey: "timer.theme") ?? "busy"
        let smartHome = d.object(forKey: "timer.smartHome") as? Bool ?? false
        let totalMs = minutes * 60_000

        // Adopt a countdown that is already running (the app was restarted, or the
        // user started it on the bar) instead of resetting it to a fresh duration.
        let live = (try? await client.busySnapshot())?["snapshot"] as? [String: Any]
        var leftMs = totalMs
        if (live?["type"] as? String) == "SIMPLE" {
            leftMs = live?["time_left_ms"] as? Int ?? totalMs
            status("adopted running timer — \(focusClock(leftMs)) left")
        } else {
            do {
                let code = try await putBusySnapshot(client, [
                    "type": "SIMPLE",
                    "card_id": busyCardID,
                    "time_left_ms": totalMs,
                    "is_paused": false,
                    "busy_bar_settings": busyBarSettings(theme: theme, smartHome: smartHome),
                ])
                guard (200..<300).contains(code) else {
                    status("the bar refused the timer (HTTP \(code))")
                    return
                }
            } catch {
                status("cannot reach \(client.base.host ?? "?"): \(error.localizedDescription)")
                return
            }
            status("\(focusClock(totalMs)) left — \(Banner.title(theme))")
        }

        let deadline = Date().addingTimeInterval(Double(leftMs) / 1000)

        while !Task.isCancelled {
            if !(await barSleep(5)) { break }
            let snap = (try? await client.busySnapshot())?["snapshot"] as? [String: Any]
            switch snap?["type"] as? String {
            case "SIMPLE":
                let left = snap?["time_left_ms"] as? Int ?? 0
                let paused = (snap?["is_paused"] as? Bool) ?? false
                status("\(focusClock(left)) left\(paused ? " (paused)" : "") — \(Banner.title(theme))")
            case "NOT_STARTED":
                status(Date() >= deadline ? "timer finished" : "timer stopped on the bar")
                return   // the toggle flips off once run() returns
            case nil:
                status("cannot reach \(client.base.host ?? "?")")
            default:
                // Someone else owns the session now — the On Call app takes over
                // while the mic is live and hands it back after. Not an error.
                status("session taken over — waiting")
            }
        }
        await stopBusySession(client, ifType: "SIMPLE", theme: theme, smartHome: smartHome)
    }
}

struct TimerSettingsView: View {
    @AppStorage("timer.minutes") private var minutes = 25
    @AppStorage("timer.theme") private var theme = "busy"
    @AppStorage("timer.smartHome") private var smartHome = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Stepper(value: $minutes, in: 1...480) {
                HStack {
                    Text("Duration")
                    Spacer()
                    Text("\(minutes) min").monospacedDigit().foregroundStyle(.secondary)
                }
            }
            BannerPicker(selection: $theme)
            Toggle("Trigger smart home scene", isOn: $smartHome)
                .font(.callout)
            Text("The bar counts down itself; stopping it there ends the widget too.")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .frame(width: 300)
    }
}
