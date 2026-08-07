import SwiftUI
import CoreAudio

/// Watches the microphone and plays the device's own themed banner (ON CALL, ON
/// AIR, MEETING …) while any app records — drawn from the bar's shared animations
/// rather than started as a focus session, so the bar's busy timer and busy state
/// are left alone. Releasing the mic clears it and whatever widget was running
/// reappears on its own.
final class OnCallApp: MiniApp {
    let app = "on-call"

    /// The one thing allowed over the bar's own screens: a call is happening
    /// whether or not the switch is on Apps or Settings. Below a running session
    /// (101) — deliberately, since that is someone deciding to be busy already.
    static let priority = 90
    /// Redraw cadence while the mic is live, so the banner survives anything else
    /// briefly taking the screen.
    static let refresh = 3.0

    func run(client: BarClient, status: @escaping @Sendable (String) -> Void) async {
        let d = UserDefaults.standard
        let theme = d.string(forKey: "oncall.theme") ?? "on_call"
        let smartHome = d.object(forKey: "oncall.smartHome") as? Bool ?? false
        let title = Banner.title(theme)
        let stock = Banner.stock(theme)

        var showing = false
        var lastDraw = Date.distantPast
        status(stock == nil ? "\(title) has no animation on the bar — pick another banner"
                            : "watching the microphone")

        while !Task.isCancelled, let stock {
            let live = Self.micInUse()
            if live {
                // Drawn, not a session: a session runs the bar's busy timer and
                // sets the device busy, and a call should do neither.
                if !showing || Date().timeIntervalSince(lastDraw) > Self.refresh {
                    let code = (try? await client.draw(
                        app: app, elements: [animationEl("banner", stock: stock)],
                        priority: Self.priority)) ?? 0
                    lastDraw = Date()
                    if !showing, code == 200, smartHome {
                        await client.setSmartHomeSwitch(on: true)
                    }
                    showing = true
                    status(code == 200 ? "\(title) — mic in use"
                                       : "\(title) — bar busy (HTTP \(code))")
                }
            } else if showing {
                await client.clear(app: app)
                if smartHome { await client.setSmartHomeSwitch(on: false) }
                showing = false
                status("mic free — watching")
            }
            if !(await barSleep(1.0)) { break }
        }
        if showing {
            if smartHome { await client.setSmartHomeSwitch(on: false) }
            await client.clear(app: app)
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
