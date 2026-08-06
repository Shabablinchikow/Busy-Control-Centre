import SwiftUI
import CoreAudio

/// Watches the microphone and puts the bar into its built-in focus session while
/// any app records, so the device renders its own themed banner (ON CALL, ON AIR,
/// MEETING …) at session priority — above every widget. Releasing the mic ends
/// the session and whatever widget was running reappears on its own.
final class OnCallApp: MiniApp {
    let app = "on-call"

    func run(client: BarClient, status: @escaping @Sendable (String) -> Void) async {
        let d = UserDefaults.standard
        let theme = d.string(forKey: "oncall.theme") ?? "on_call"
        let smartHome = d.object(forKey: "oncall.smartHome") as? Bool ?? false
        let title = Banner.title(theme)

        var started = false            // true only for a session this app began
        var interrupted: [String: Any]?  // a timer/pomodoro we displaced, to put back
        status("watching the microphone")

        while !Task.isCancelled {
            let live = Self.micInUse()
            if live, !started {
                // The mic outranks a running timer: remember it, then take over.
                // Restoring the captured snapshot verbatim lets the device account
                // for the time that passed during the call.
                let full = try? await client.busySnapshot()
                let type = (full?["snapshot"] as? [String: Any])?["type"] as? String
                interrupted = (type != nil && type != "NOT_STARTED") ? full : nil
                if (try? await client.setBusySession(theme: theme, running: true,
                                                     triggerSmartHome: smartHome)) != nil {
                    started = true
                    status(interrupted == nil ? "\(title) — mic in use"
                                              : "\(title) — mic in use (timer paused)")
                }
            } else if !live, started {
                await Self.release(client, theme: theme, smartHome: smartHome,
                                   restore: interrupted)
                started = false
                status(interrupted == nil ? "mic free — watching" : "mic free — timer resumed")
                interrupted = nil
            }
            if !(await barSleep(1.0)) { break }
        }
        if started {
            await Self.release(client, theme: theme, smartHome: smartHome, restore: interrupted)
        }
    }

    private static func release(_ client: BarClient, theme: String, smartHome: Bool,
                                restore: [String: Any]?) async {
        if let restore {
            _ = try? await client.restoreBusySnapshot(restore)
        } else {
            _ = try? await client.setBusySession(theme: theme, running: false,
                                                 triggerSmartHome: smartHome)
        }
    }

    /// True when any input-capable audio device is running somewhere system-wide.
    /// Reads CoreAudio state only — no capture, so no microphone permission needed.
    static func micInUse() -> Bool {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        let system = AudioObjectID(kAudioObjectSystemObject)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &addr, 0, nil, &size) == noErr, size > 0 else { return false }
        var devices = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &devices) == noErr else { return false }

        for device in devices {
            var streamsAddr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyStreams,
                mScope: kAudioDevicePropertyScopeInput,
                mElement: kAudioObjectPropertyElementMain)
            var streamsSize: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(device, &streamsAddr, 0, nil, &streamsSize) == noErr,
                  streamsSize > 0 else { continue }  // not an input device

            var runningAddr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
                mScope: kAudioObjectPropertyScopeWildcard,
                mElement: kAudioObjectPropertyElementMain)
            var running: UInt32 = 0
            var runningSize = UInt32(MemoryLayout<UInt32>.size)
            if AudioObjectGetPropertyData(device, &runningAddr, 0, nil, &runningSize, &running) == noErr,
               running != 0 {
                // ponytail: an input+output combo device (some USB interfaces)
                // reads "running" during pure playback too; per-scope process
                // inspection if that ever false-positives
                return true
            }
        }
        return false
    }
}

struct OnCallSettingsView: View {
    @AppStorage("oncall.theme") private var theme = "on_call"
    @AppStorage("oncall.smartHome") private var smartHome = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            BannerPicker(selection: $theme, label: "Banner shown while the mic is in use")
            Toggle("Trigger smart home scene", isOn: $smartHome)
                .font(.callout)
        }
        .frame(width: 340)
    }
}
