import SwiftUI

/// The device's built-in session themes. `id` is the string the bar expects in
/// busy_bar_settings.theme; the artwork in Resources/Themes is keyed by the same id.
struct Banner: Identifiable, Hashable {
    let id: String
    let title: String

    /// The twelve the firmware ships, each with a `theme.json` and a matching
    /// animation in its shared assets. There is no "busy" theme on the device —
    /// it was in this list for years and has neither artwork nor an animation.
    static let all: [Banner] = [
        Banner(id: "on_call", title: "On Call"),
        Banner(id: "meeting", title: "Meeting"),
        Banner(id: "dnd", title: "Do Not Disturb"),
        Banner(id: "keep_out", title: "Keep Out"),
        Banner(id: "on_air", title: "On Air"),
        Banner(id: "flow", title: "Flow"),
        Banner(id: "coding", title: "Coding"),
        Banner(id: "booked", title: "Booked"),
        Banner(id: "back_soon", title: "Back Soon"),
        Banner(id: "lunch", title: "Lunch"),
        Banner(id: "chill_time", title: "Chill Time"),
        Banner(id: "low_social_battery", title: "Low Social Battery"),
    ]

    static func title(_ id: String) -> String {
        all.first { $0.id == id }?.title ?? id
    }

    /// The device's own animation for this theme, as `stock_path` wants it.
    ///
    /// Every theme the firmware ships is a `theme.json` whose `bg_path` points at
    /// `shared/animations/<id>_72x16.anim`, and the draw API can play exactly
    /// those by name — so a banner needs no focus session, and no artwork of ours.
    static func stock(_ id: String) -> String? {
        all.contains { $0.id == id } ? "shared/\(id)_72x16.anim" : nil
    }

    /// What a widget falls back to when its saved theme is not one the device has
    /// — "busy" was the old default and never existed on the bar.
    static let fallback = "dnd"

    var image: NSImage? {
        Bundle.main.url(forResource: id, withExtension: "png", subdirectory: "Themes")
            .flatMap { NSImage(contentsOf: $0) }
    }
}

/// Two-column grid of banner artwork; tap to choose.
struct BannerPicker: View {
    @Binding var selection: String
    var label = "Banner"

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            ScrollView {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 8),
                                    GridItem(.flexible(), spacing: 8)], spacing: 8) {
                    ForEach(Banner.all) { banner in
                        BannerCell(banner: banner, selected: banner.id == selection)
                            .onTapGesture { selection = banner.id }
                    }
                }
                .padding(.trailing, 4)
            }
            .frame(height: 220)
        }
    }
}

private struct BannerCell: View {
    let banner: Banner
    let selected: Bool

    var body: some View {
        Group {
            if let img = banner.image {
                Image(nsImage: img).resizable().aspectRatio(contentMode: .fit)
            } else {
                // artwork missing: fall back to a plain label so the row still works
                Text(banner.title.uppercased())
                    .font(.system(size: 11, weight: .heavy, design: .monospaced))
                    .frame(maxWidth: .infinity).padding(.vertical, 10)
                    .background(.black).foregroundStyle(.white)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .overlay(RoundedRectangle(cornerRadius: 5)
            .stroke(selected ? Color.accentColor : .clear, lineWidth: 2.5))
        .help(banner.title)
        .contentShape(Rectangle())
    }
}
