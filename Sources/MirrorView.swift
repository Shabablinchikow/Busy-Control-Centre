import SwiftUI

/// Live mirror of the bar's screen, polled from /api/screen and drawn as an LED
/// matrix — discrete dots on black with a soft bloom, the way the panel reads in
/// person — rather than a smoothly scaled bitmap.
struct MirrorView: View {
    @AppStorage("mirror.display") private var display = 0
    @AppStorage("host") private var host = "10.0.4.20"
    @AppStorage("accessKey") private var accessKey = ""
    @State private var frame: Frame?
    @State private var error: String?

    /// ~3 fps. The bar serves one request at a time, so mirror frames compete
    /// with whatever the running widget is drawing; this leaves it room to work.
    private let period = 0.33

    struct Frame {
        let w: Int, h: Int
        /// 3 bytes per pixel, row-major, in **BGR** order — the panel's yellow
        /// #FFD60A arrives as 05 66 7a, so blue leads.
        let rgb: [UInt8]
    }

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 8).fill(.black)
                if let frame {
                    LEDMatrix(frame: frame)
                        .padding(6)
                        .opacity(error == nil ? 1 : 0.35)   // dim the stale frame
                }
                if let error {
                    Text(error)
                        .font(.caption)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(.black.opacity(0.7), in: Capsule())
                        .foregroundStyle(.secondary)
                } else if frame == nil {
                    Text("connecting…").font(.caption).foregroundStyle(.secondary)
                }
            }
            .aspectRatio(display == 0 ? 72.0 / 16 : 160.0 / 80, contentMode: .fit)
            .frame(maxWidth: .infinity, minHeight: 130)
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(.white.opacity(0.08)))
            Picker("", selection: $display) {
                Text("Front").tag(0)
                Text("Back").tag(1)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 160)
        }
        .task(id: "\(display)-\(host)-\(accessKey)") { await poll() }
    }

    /// /api/screen advertises image/bmp but actually returns base64-encoded
    /// RGB888 with no header, so the payload length identifies the panel.
    static func decode(_ data: Data) -> Frame? {
        guard let rgb = Data(base64Encoded: data, options: .ignoreUnknownCharacters) else { return nil }
        switch rgb.count {
        case 72 * 16 * 3: return Frame(w: 72, h: 16, rgb: [UInt8](rgb))
        case 160 * 80 * 3: return Frame(w: 160, h: 80, rgb: [UInt8](rgb))
        default: return nil
        }
    }

    private func poll() async {
        let client = BarClient(host: host, token: accessKey.isEmpty ? nil : accessKey)
        var misses = 0
        while !Task.isCancelled {
            do {
                let data = try await client.screen(display: display)
                if let f = Self.decode(data) {
                    frame = f
                    error = nil
                    misses = 0
                } else {
                    error = "frame not decodable (\(data.count) bytes)"
                }
            } catch {
                // Keep showing the last frame, dimmed — the bar drops requests
                // while it is busy drawing, and those recover on the next tick.
                misses += 1
                self.error = misses < 3 ? "reconnecting…" : "cannot reach \(host)"
            }
            // Back off while it is down so a disconnected bar isn't hammered.
            let wait = misses == 0 ? period : min(5, period * pow(2, Double(misses)))
            if !(await barSleep(wait)) { break }
        }
    }
}

/// Each device pixel becomes a rounded dot with a gap around it; lit dots get a
/// wider, dimmer halo underneath so bright areas bloom like the real panel.
private struct LEDMatrix: View {
    let frame: MirrorView.Frame

    var body: some View {
        Canvas(rendersAsynchronously: true) { ctx, size in
            let cell = min(size.width / Double(frame.w), size.height / Double(frame.h))
            let dot = cell * 0.82
            let ox = (size.width - cell * Double(frame.w)) / 2
            let oy = (size.height - cell * Double(frame.h)) / 2
            let radius = dot * 0.28

            for y in 0..<frame.h {
                for x in 0..<frame.w {
                    let i = (y * frame.w + x) * 3
                    let b = Double(frame.rgb[i]) / 255
                    let g = Double(frame.rgb[i + 1]) / 255
                    let r = Double(frame.rgb[i + 2]) / 255
                    let lit = r + g + b > 0.04
                    let px = ox + Double(x) * cell + (cell - dot) / 2
                    let py = oy + Double(y) * cell + (cell - dot) / 2
                    let rect = CGRect(x: px, y: py, width: dot, height: dot)

                    if lit {
                        // halo first, then the dot on top
                        ctx.fill(Path(roundedRect: rect.insetBy(dx: -dot * 0.45, dy: -dot * 0.45),
                                      cornerRadius: radius * 2),
                                 with: .color(Color(red: r, green: g, blue: b).opacity(0.18)))
                        ctx.fill(Path(roundedRect: rect, cornerRadius: radius),
                                 with: .color(Color(red: r, green: g, blue: b)))
                    } else {
                        // unlit dots stay faintly visible, like the real matrix
                        ctx.fill(Path(roundedRect: rect, cornerRadius: radius),
                                 with: .color(.white.opacity(0.035)))
                    }
                }
            }
        }
    }
}
