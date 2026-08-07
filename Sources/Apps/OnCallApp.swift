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

    func run(client: BarClient, status: @escaping @Sendable (String) -> Void) async {
        let d = UserDefaults.standard
        let theme = d.string(forKey: "oncall.theme") ?? "on_call"
        let smartHome = d.object(forKey: "oncall.smartHome") as? Bool ?? false
        let title = Banner.title(theme)
        let stock = Banner.stock(theme)

        var showing = false
        var drawnAt = -1
        status(stock == nil ? "\(title) has no animation on the bar — pick another banner"
                            : "watching the microphone")

        while !Task.isCancelled, let stock {
            let live = Self.micInUse()
            if live {
                // Drawn once, not on a timer: re-sending an animation element
                // restarts it, which reads as a flicker every few seconds. The
                // element stays up on its own, so it is only worth sending again
                // while the bar is refusing us.
                //
                // Drawn at all, rather than started as a session: a session runs
                // the bar's busy timer and sets the device busy, and a call
                // should do neither.
                // Redrawn when the switch has moved as well as when the call
                // starts: the bar drops our elements when its own screens come
                // and go, and this one is otherwise drawn exactly once so its
                // animation does not restart and flicker.
                let generation = await BarState.shared.generation
                if !showing || drawnAt != generation {
                    let code = (try? await client.draw(
                        app: app, elements: [animationEl("banner", stock: stock)],
                        priority: Self.priority)) ?? 0
                    if code == 200 {
                        showing = true
                        drawnAt = generation
                        if smartHome { await client.setSmartHomeSwitch(on: true) }
                        status("\(title) — mic in use")
                    } else {
                        status("\(title) — bar busy (HTTP \(code)), retrying")
                    }
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
