import SwiftUI

/// Pins a banner on the bar until switched off.
///
/// The banner is one of the device's own theme animations, drawn straight from
/// its shared assets — not a focus session. A session would run the bar's busy
/// timer and flip the device into its busy state, which is not what pinning a
/// picture should do.
final class StatusApp: MiniApp {
    let app = "status"

    /// How often to try again while the bar is refusing us. Once the banner is
    /// up it is left alone: re-sending an animation element restarts it, which
    /// reads as a flicker.
    static let retry = 5.0

    func run(client: BarClient, status: @escaping @Sendable (String) -> Void) async {
        let d = UserDefaults.standard
        let theme = d.string(forKey: "status.theme") ?? Banner.fallback
        let smartHome = d.object(forKey: "status.smartHome") as? Bool ?? false
        let title = Banner.title(theme)

        guard let stock = Banner.stock(theme) else {
            status("\(title) has no animation on the bar — pick another banner")
            _ = await barSleep(3600)
            return
        }
        if smartHome { await client.setSmartHomeSwitch(on: true) }

        // Drawn, not started as a session: a session would run the bar's busy
        // timer and put the device into its busy state, which a pinned banner has
        // no business doing. It goes in at the ordinary widget priority, so the
        // switch still outranks it.
        var drawnAt = -1
        while !Task.isCancelled {
            // The bar throws our elements away when it puts up a screen of its
            // own, so the banner goes back up whenever the switch has moved. A
            // draw made while its screen is still up is refused anyway.
            let generation = await BarState.shared.generation
            if drawnAt != generation {
                let code = (try? await client.draw(
                    app: app, elements: [animationEl("banner", stock: stock)])) ?? 0
                if code == 200 { drawnAt = generation }
                switch code {
                case 200: status("showing \(title)")
                case 409: status("paused — bar in use")
                default: status("the bar refused the banner (HTTP \(code))")
                }
            }
            if !(await barSleep(Self.retry)) { break }
        }
        if smartHome { await client.setSmartHomeSwitch(on: false) }
        await client.clear(app: app)
    }
}

struct StatusSettingsView: View {
    @AppStorage("status.theme") private var theme = Banner.fallback
    @AppStorage("status.smartHome") private var smartHome = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            BannerPicker(selection: $theme, label: "Banner to display until switched off")
            Toggle("Trigger smart home scene", isOn: $smartHome)
                .font(.callout)
        }
        .frame(width: 340)
    }
}
