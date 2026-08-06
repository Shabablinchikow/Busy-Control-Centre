import SwiftUI
import ServiceManagement

@main
struct BusyBarApp: App {
    @StateObject private var runner = Runner()
    @AppStorage("host") private var host = "10.0.4.20"

    var body: some Scene {
        Window("Busy Control Centre", id: "main") {
            ContentView()
                .environmentObject(runner)
                .onAppear {
                    LocalNetworkPermission.trigger()
                    runner.restore()
                }
        }
        // resizable: drag the window wider and the LED matrix grows with it
        .windowResizability(.contentMinSize)
    }
}

/// All mini-apps. `id` is the application_name the device sees.
let registry: [AppEntry] = [
    AppEntry(id: "clock", name: "Clock", blurb: "Big time, refreshed every second.",
             symbol: "clock", make: { ClockApp() }),
    AppEntry(id: "nyan-cat", name: "Nyan Cat", blurb: "Pop-tart cat, rainbow trail, twinkling stars.",
             symbol: "cat", make: { NyanApp() }),
    AppEntry(id: "iss-alert", name: "ISS Alert", blurb: "Quiet until the space station passes near you.",
             symbol: "sparkles", make: { ISSApp() }, settings: { AnyView(ISSSettingsView()) }),
    AppEntry(id: "audio-visualizer", name: "Music", blurb: "Spectrum bars that follow the Music app, with track title.",
             symbol: "waveform", make: { MusicApp() }, settings: { AnyView(MusicSettingsView()) }),
    AppEntry(id: "flightradar", name: "Flightradar", blurb: "Tracks one flight by number: route, altitude, speed.",
             symbol: "airplane", make: { FlightradarApp() }, settings: { AnyView(FlightradarSettingsView()) }),
    AppEntry(id: "claude-limits", name: "Claude Limits", blurb: "Live Claude Code usage bars with Clawd.",
             symbol: "gauge.with.needle", make: { ClaudeApp() }, settings: { AnyView(ClaudeSettingsView()) }),
    AppEntry(id: "piss-stream", name: "pISS Stream", blurb: "Live ISS urine tank level, straight from NASA telemetry.",
             symbol: "toilet", make: { PissStreamApp() }),
    AppEntry(id: "focus-timer", name: "Timer", blurb: "Countdown session on the bar, with your choice of banner.",
             symbol: "timer", make: { TimerApp() },
             settings: { AnyView(TimerSettingsView()) }, exclusive: false),
    AppEntry(id: "pomodoro", name: "Pomodoro", blurb: "Work/rest cycles run by the bar itself.",
             symbol: "repeat.circle", make: { PomodoroApp() },
             settings: { AnyView(PomodoroSettingsView()) }, exclusive: false),
    AppEntry(id: "on-call", name: "On Call", blurb: "Mic in use overrides everything with your ON CALL banner.",
             symbol: "mic.badge.plus", make: { OnCallApp() },
             settings: { AnyView(OnCallSettingsView()) }, exclusive: false),
]

struct ContentView: View {
    @EnvironmentObject var runner: Runner
    @AppStorage("host") private var host = "10.0.4.20"
    @AppStorage("accessKey") private var accessKey = ""
    @AppStorage("mirror.show") private var showMirror = true

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Device").font(.headline)
                TextField("10.0.4.20", text: $host)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 150)
                SecureField("access key", text: $accessKey)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 110)
            }
            Text("USB is always 10.0.4.20 (no key needed). For Wi-Fi, enter the bar's IP and its HTTP access key (Settings → HTTP Access on the bar).")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                LaunchAtLoginToggle()
                Spacer()
                Toggle("Mirror display", isOn: $showMirror)
                    .toggleStyle(.checkbox)
                    .font(.callout)
            }
            if showMirror {
                MirrorView()
                    .transition(.opacity)
            }
            Divider()
            ForEach(registry) { entry in
                AppRow(entry: entry)
            }
        }
        .padding(16)
        .frame(minWidth: 620, idealWidth: 820)
    }
}

/// SMAppService reports the real state, so the toggle reflects what the system
/// thinks — including a "requires approval" state after the user denies it.
struct LaunchAtLoginToggle: View {
    @State private var on = SMAppService.mainApp.status == .enabled
    @State private var note: String?

    var body: some View {
        HStack(spacing: 8) {
            Toggle("Start at login", isOn: $on)
                .toggleStyle(.checkbox)
                .onChange(of: on) { _, want in
                    do {
                        if want { try SMAppService.mainApp.register() }
                        else { try SMAppService.mainApp.unregister() }
                        note = SMAppService.mainApp.status == .requiresApproval
                            ? "enable it in System Settings → General → Login Items" : nil
                    } catch {
                        note = error.localizedDescription
                        on = SMAppService.mainApp.status == .enabled
                    }
                }
            if let note {
                Text(note).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .font(.callout)
    }
}

struct AppRow: View {
    let entry: AppEntry
    @EnvironmentObject var runner: Runner
    @State private var showSettings = false

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: entry.symbol)
                .font(.title3)
                .foregroundStyle(runner.isRunning(entry.id) ? Color.accentColor : .secondary)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(entry.name).font(.body.weight(.medium))
                    if runner.isRunning(entry.id) {
                        Circle().fill(.green).frame(width: 7, height: 7)
                    }
                }
                Text(runner.isRunning(entry.id) ? (runner.status[entry.id] ?? "") : entry.blurb)
                    .font(.caption)
                    .foregroundStyle(runner.isRunning(entry.id) ? .primary : .secondary)
                    .lineLimit(1)
                    .help(runner.status[entry.id] ?? entry.blurb)
            }
            Spacer()
            if let settings = entry.settings {
                Button { showSettings.toggle() } label: { Image(systemName: "gearshape") }
                    .buttonStyle(.borderless)
                    // sheet, not popover: NSPopover + remote views throws deep in
                    // AppKit on the macOS 27 beta and _crashOnException kills the app
                    .sheet(isPresented: $showSettings) {
                        VStack(spacing: 12) {
                            Text(entry.name).font(.headline)
                            settings()
                            Button("Done") { showSettings = false }
                                .keyboardShortcut(.defaultAction)
                        }
                        .padding(16)
                    }
            }
            Toggle("", isOn: Binding(
                get: { runner.isRunning(entry.id) },
                set: { _ in runner.toggle(entry) }))
                .toggleStyle(.switch)
                .labelsHidden()
        }
    }
}
