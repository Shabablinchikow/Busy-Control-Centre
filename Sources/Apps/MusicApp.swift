import AppKit
import SwiftUI

/// Spectrum visualiser driven by the Music app's playback state — the render
/// half of music.py (five styles, five themes, peak-hold caps) fed by its
/// synthetic band generator instead of a microphone. Nothing here listens to
/// audio, so the app never asks for mic access.
/// Each frame is one 72x16 PNG pushed as a single image element (see Frame):
/// a busy style can reach 100+ rects at ~3.6 ms each, while a full-frame image
/// is a flat ~50 ms regardless of what is on it.
final class MusicApp: MiniApp {
    let app = "audio-visualizer"

    typealias RGB = (UInt8, UInt8, UInt8)

    static let numBands = 24
    /// How often the Music app is asked what it is doing. Short enough that
    /// hitting pause visibly stops the bars.
    static let pollInterval = 2.0
    /// A paused track stays on screen this long, then the display is released.
    static let pausedHold = 6.0
    static let pausedColor = "#606060FF"
    /// The device's small font is ~4 px per character, so this many fit across
    /// the 72 px display. Anything longer is scrolled rather than clipped.
    static let textCols = 18
    static let marqueeCharsPerSec = 4.0

    // Colour themes as vertical gradient stops: (position 0..1, (r, g, b) in 0..1).
    // Position 0 is the bottom row of the display, 1 is the top. A bar samples the
    // palette from its base up to its current peak, so quiet bands stay in the cool
    // low colours and loud bands climb into the hot top colours.
    typealias Stop = (p: Double, c: (Double, Double, Double))
    static let themes: [String: [Stop]] = [
        "classic": [(0.0, (0.00, 0.78, 0.00)), (0.5, (1.00, 0.78, 0.00)), (1.0, (1.00, 0.12, 0.00))],
        "fire":    [(0.0, (0.45, 0.00, 0.00)), (0.35, (1.00, 0.25, 0.00)), (0.7, (1.00, 0.65, 0.00)), (1.0, (1.00, 1.00, 0.75))],
        "ocean":   [(0.0, (0.00, 0.10, 0.55)), (0.45, (0.00, 0.50, 0.95)), (0.8, (0.00, 0.90, 0.95)), (1.0, (0.80, 1.00, 1.00))],
        "aurora":  [(0.0, (0.00, 0.35, 0.20)), (0.4, (0.00, 0.85, 0.50)), (0.7, (0.20, 0.95, 0.75)), (1.0, (0.65, 0.30, 0.95))],
    ]
    static let themeNames = ["classic", "fire", "ocean", "aurora", "rainbow"]
    static let styleNames = ["bars", "mirror", "segments", "dots", "wave"]

    /// Bright cap that floats on top of each bar at its recent peak.
    static let peakColor: RGB = (255, 255, 255)
    /// Peak caps fall this many pixels per second, then are scaled to the frame rate.
    static let peakFallPerSec = 9.0

    // The device briefly locks an asset while a draw reads it; re-uploading the
    // same name too soon returns HTTP 508, so rotate through a few filenames.
    let ring = 4
    var frameNo = 0

    // MARK: - Run loop

    func run(client: BarClient, status: @escaping @Sendable (String) -> Void) async {
        let d = UserDefaults.standard
        let style = d.string(forKey: "music.style") ?? "bars"
        let theme = d.string(forKey: "music.theme") ?? "classic"
        let fps = max(1, d.object(forKey: "music.fps") as? Int ?? 15)
        let showTrack = d.object(forKey: "music.showTrack") as? Bool ?? true

        let interval = 1.0 / Double(fps)
        let peakFall = max(0.3, Self.peakFallPerSec / Double(fps))
        let n = Self.numBands

        var smooth = [Int](repeating: 0, count: n)
        var peaks = [Double](repeating: 0.0, count: n)
        var animT = 0.0            // advances only while playing, so a pause doesn't jump
        var state = Playback()
        var lastPoll = Date.distantPast
        // Music broadcasts play/pause/track changes as distributed notifications,
        // which need no TCC approval — the fallback while Automation prompts are
        // broken on this OS. No snapshot on start; syncs on the first change.
        let listener = await MainActor.run { let l = MusicNotifications(); l.start(); return l }
        var quietSince: Date?
        var quietLabel: String?    // what the paused card currently shows, nil once cleared
        var lastStatus = ""

        while !Task.isCancelled {
            let tick = Date()
            if tick.timeIntervalSince(lastPoll) >= Self.pollInterval {
                lastPoll = tick
                state = await MainActor.run {
                    guard !NSRunningApplication.runningApplications(
                        withBundleIdentifier: "com.apple.Music").isEmpty
                    else { listener.clear(); return Playback() }
                    return listener.latest ?? Playback(running: true)
                }
            }
            var line: String

            if state.playing {
                quietSince = nil
                quietLabel = nil
                animT += interval
                smooth = Self.smoothHeights(Self.synthHeights(animT), smooth)
                for i in 0..<n { peaks[i] = max(Double(smooth[i]), peaks[i] - peakFall) }

                var f = Frame()
                raster(&f, heights: smooth, peaks: peaks, theme: theme, style: style)
                let fn = "frame\(frameNo % ring).png"
                frameNo += 1
                var els: [[String: Any]] = [imageEl("frame", path: fn)]
                if showTrack, let track = state.track {
                    // A scrolling window is emitted left-aligned at full width;
                    // centring it would jitter as the device trims edge spaces.
                    if track.count > Self.textCols {
                        els.append(textEl("track", Self.marquee(track, animT), x: 0, y: 0, font: "small"))
                    } else {
                        els.append(textEl("track", track, x: 36, y: 0, font: "small", align: "top_mid"))
                    }
                }
                line = "\(style)/\(theme)" + (state.track.map { " — \($0)" } ?? "")
                do {
                    try await client.uploadAsset(app: app, file: fn, data: f.png())
                    let code = try await client.draw(app: app, elements: els)
                    if code == 409 { line = "paused — bar in use" }
                } catch {
                    line = "draw error: \(error.localizedDescription)"
                }
            } else {
                // Reset the bars so playback restarts from silence rather than
                // resuming mid-animation.
                smooth = [Int](repeating: 0, count: n)
                peaks = [Double](repeating: 0.0, count: n)
                let since = quietSince ?? tick
                quietSince = since

                let holding = state.running && state.synced && tick.timeIntervalSince(since) < Self.pausedHold
                // The card is static, so it is truncated rather than scrolled.
                let label = holding ? Self.fit("|| " + (state.track ?? "PAUSED")) : nil
                if label != quietLabel {
                    quietLabel = label
                    if let label {
                        _ = try? await client.draw(app: app, elements: [
                            textEl("paused", label, x: 36, y: 5, font: "small",
                                   color: Self.pausedColor, align: "top_mid")])
                    } else {
                        await client.clear(app: app)
                    }
                }
                if state.running, !state.synced {
                    line = "press play/pause once in Music to sync"
                } else if state.running {
                    line = state.track.map { "paused — \($0)" } ?? "paused"
                } else {
                    line = "waiting for the Music app"
                }
            }

            if line != lastStatus { lastStatus = line; status(line) }

            // Idle at the poll rate; there is nothing to animate until playback resumes.
            let target = state.playing ? interval : Self.pollInterval
            let dt = Date().timeIntervalSince(tick)
            if dt < target { if !(await barSleep(target - dt)) { break } }
        }
        await MainActor.run { listener.stop() }
        await client.clear(app: app)
    }

    // MARK: - Fitting text to 72 px

    static func fit(_ text: String) -> String { String(text.prefix(textCols)) }

    /// A `textCols`-wide window into `text`, advanced over time so a long title
    /// tickers past instead of being clipped. Text that already fits is returned
    /// unchanged. `t` is the animation clock, so the ticker freezes with the bars.
    static func marquee(_ text: String, _ t: Double) -> String {
        let chars = Array(text)
        guard chars.count > textCols else { return text }
        let padded = chars + Array("    ")  // gap so the wrap reads as a loop
        let step = Int(t * marqueeCharsPerSec) % padded.count
        return String((0..<textCols).map { padded[(step + $0) % padded.count] })
    }

    // MARK: - Music app state

    /// TCC-free playback source: Music posts playerInfo distributed notifications
    /// on every play/pause/track change; receiving them requires no permission.
    @MainActor
    final class MusicNotifications {
        private(set) var latest: Playback?
        private var observers: [NSObjectProtocol] = []

        func start() {
            let dnc = DistributedNotificationCenter.default()
            for name in ["com.apple.Music.playerInfo", "com.apple.iTunes.playerInfo"] {
                observers.append(dnc.addObserver(forName: Notification.Name(name), object: nil,
                                                 queue: .main) { [weak self] note in
                    let info = note.userInfo ?? [:]
                    var pb = Playback(running: true, synced: true)
                    pb.playing = (info["Player State"] as? String) == "Playing"
                    if let title = info["Name"] as? String, !title.isEmpty {
                        let artist = info["Artist"] as? String ?? ""
                        pb.track = String((artist.isEmpty ? title : "\(title) - \(artist)").prefix(48))
                    }
                    self?.latest = pb
                })
            }
        }

        func clear() { latest = nil }

        func stop() {
            observers.forEach { DistributedNotificationCenter.default().removeObserver($0) }
            observers = []
        }
    }

    struct Playback {
        var running = false
        var playing = false
        var track: String?
        var synced = false   // false until the first playerInfo notification lands
    }

    // MARK: - Synthetic spectrum

    /// ~100 BPM groove.
    static let beatHz = 100.0 / 60.0

    /// Music-like spectrum for band 0..23 at time t seconds.
    static func synthHeights(_ t: Double) -> [Int] {
        let H = Double(Frame.H)
        let phase = (t * beatHz).truncatingRemainder(dividingBy: 1.0)
        let kick = exp(-6.0 * phase)
        let off = (phase + 0.5).truncatingRemainder(dividingBy: 1.0)
        let snare = exp(-9.0 * off)
        let swell = 0.85 + 0.15 * sin(t * 0.5)
        let melCenter = 6.0 + 8.0 * (0.5 + 0.5 * sin(t * 0.8))

        return (0..<numBands).map { i in
            var val: Double
            if i <= 5 {
                let wob = 0.5 + 0.5 * sin(t * 2.0 + Double(i) * 0.7)
                val = (0.55 + 0.45 * wob) * (0.30 + 0.80 * kick)
            } else if i <= 14 {
                let mel = exp(-pow(Double(i) - melCenter, 2) / 6.0)
                let groove = 0.5 + 0.5 * sin(t * 3.3 + Double(i) * 0.5)
                val = 0.20 + 0.75 * mel * (0.4 + 0.6 * groove) + 0.20 * snare
            } else {
                let shimmer = 0.5 + 0.5 * sin(t * 11.0 + Double(i) * 1.7)
                let hat = exp(-12.0 * off)
                val = (0.10 + 0.35 * shimmer) * (0.5 + 0.9 * hat)
            }
            val *= swell
            return max(0, min(Frame.H, Int((val * H).rounded(.toNearestOrEven))))
        }
    }

    /// Attack/decay smoothing: bars fall at `decay` rate per frame.
    static func smoothHeights(_ new: [Int], _ old: [Int], decay: Double = 0.75) -> [Int] {
        zip(new, old).map { max($0, Int(Double($1) * decay)) }
    }

    // MARK: - Colour / palette

    /// HSV (all 0..1) -> (r, g, b) in 0..1.
    static func hsv(_ h: Double, _ s: Double, _ v: Double) -> (Double, Double, Double) {
        let i = Int(h * 6.0) % 6
        let f = h * 6.0 - Double(Int(h * 6.0))
        let p = v * (1 - s), q = v * (1 - f * s), t = v * (1 - (1 - f) * s)
        switch i {
        case 0: return (v, t, p)
        case 1: return (q, v, p)
        case 2: return (p, v, t)
        case 3: return (p, q, v)
        case 4: return (t, p, v)
        default: return (v, p, q)
        }
    }

    /// Linearly interpolate gradient stops at t in 0..1.
    static func sample(_ stops: [Stop], _ t0: Double) -> (Double, Double, Double) {
        let t = max(0.0, min(1.0, t0))
        var prev = stops[0]
        for stop in stops {
            if t <= stop.p {
                let span = (stop.p - prev.p) == 0 ? 1.0 : (stop.p - prev.p)
                let k = (t - prev.p) / span
                return (prev.c.0 + (stop.c.0 - prev.c.0) * k,
                        prev.c.1 + (stop.c.1 - prev.c.1) * k,
                        prev.c.2 + (stop.c.2 - prev.c.2) * k)
            }
            prev = stop
        }
        return stops[stops.count - 1].c
    }

    /// Theme colour for a band at absolute height fraction t, as 0..255.
    static func c(_ band: Int, _ t0: Double, _ theme: String, _ n: Int) -> RGB {
        let t = max(0.0, min(1.0, t0))
        let rgb: (Double, Double, Double)
        if theme == "rainbow" {
            rgb = hsv(Double(band) / Double(max(1, n)), 1.0, 0.35 + 0.65 * t)
        } else {
            rgb = sample(themes[theme] ?? themes["classic"]!, t)
        }
        func q(_ v: Double) -> UInt8 { UInt8(max(0, min(255, Int(v * 255 + 0.5)))) }
        return (q(rgb.0), q(rgb.1), q(rgb.2))
    }

    // MARK: - Rasterisers (write pixels, not rect elements)

    private func px(_ f: inout Frame, _ x: Int, _ y: Int, _ c: RGB) { f.rect(x, y, 1, 1, c) }
    private func col2(_ f: inout Frame, _ x: Int, _ y: Int, _ c: RGB) { f.rect(x, y, 2, 1, c) }

    func raster(_ f: inout Frame, heights: [Int], peaks: [Double], theme: String, style: String) {
        switch style {
        case "mirror": rasterMirror(&f, heights, peaks, theme)
        case "segments": rasterSegments(&f, heights, peaks, theme)
        case "dots": rasterDots(&f, heights, peaks, theme)
        case "wave": rasterWave(&f, heights, peaks, theme)
        default: rasterBars(&f, heights, peaks, theme)
        }
    }

    /// Vertical gradient bars anchored at the bottom, floating peak-hold caps.
    func rasterBars(_ f: inout Frame, _ heights: [Int], _ peaks: [Double], _ theme: String) {
        let n = heights.count, H = Frame.H
        for (i, h) in heights.enumerated() {
            let x = i * 3
            for y in (H - h)..<H {
                col2(&f, x, y, Self.c(i, Double(H - 1 - y) / Double(H - 1), theme, n))
            }
            let ph = Int(peaks[i])
            if ph > h && ph > 0 { col2(&f, x, H - ph, Self.peakColor) }
        }
    }

    /// Bars grow symmetrically from the horizontal centre, up and down.
    func rasterMirror(_ f: inout Frame, _ heights: [Int], _ peaks: [Double], _ theme: String) {
        let n = heights.count, H = Frame.H
        let mid = H / 2
        for (i, h) in heights.enumerated() {
            let x = i * 3
            let half = h / 2
            for y in (mid - half)..<mid {
                let t = Double(mid - y) / Double(max(1, half)) * (Double(h) / Double(H))
                col2(&f, x, y, Self.c(i, t, theme, n))
            }
            for y in mid..<(mid + half) {
                let t = Double(y - mid + 1) / Double(max(1, half)) * (Double(h) / Double(H))
                col2(&f, x, y, Self.c(i, t, theme, n))
            }
            let phalf = Int(peaks[i]) / 2
            if phalf > half && phalf > 0 {
                col2(&f, x, mid - phalf, Self.peakColor)
                col2(&f, x, mid + phalf - 1, Self.peakColor)
            }
        }
    }

    // LED-block geometry for the segmented style: 2 px lit block, 1 px dark gap.
    static let segBlock = 2, segGap = 1
    static let segPitch = segBlock + segGap
    static let segSlots = 6

    /// (y, height) of block slot k (0 = bottom), clamped into the display.
    static func segBlockRect(_ k: Int) -> (y: Int, h: Int) {
        var y = Frame.H - segBlock - k * segPitch
        var bh = segBlock
        if y < 0 { bh += y; y = 0 }
        return (y, bh)
    }

    /// Discrete stacked LED blocks per band (classic hardware VU meter).
    func rasterSegments(_ f: inout Frame, _ heights: [Int], _ peaks: [Double], _ theme: String) {
        let n = heights.count, H = Frame.H
        for (i, h) in heights.enumerated() {
            let x = i * 3
            // .toNearestOrEven matches python's round() on exact .5 slot boundaries.
            let lit = Int((Double(h) / Double(H) * Double(Self.segSlots)).rounded(.toNearestOrEven))
            for k in 0..<max(0, lit) {
                let (y, bh) = Self.segBlockRect(k)
                if bh <= 0 { continue }
                let t = 1.0 - (Double(y) + Double(bh) / 2.0) / Double(H)
                let col = Self.c(i, t, theme, n)
                for yy in y..<(y + bh) { col2(&f, x, yy, col) }
            }
            let peakSlot = Int((peaks[i] / Double(H) * Double(Self.segSlots)).rounded(.toNearestOrEven))
            if peakSlot > lit && peakSlot > 0 {
                let (y, bh) = Self.segBlockRect(peakSlot - 1)
                for yy in y..<(y + bh) { col2(&f, x, yy, Self.peakColor) }
            }
        }
    }

    /// Only a bouncing dot at each band top, with a falling peak-hold dot.
    func rasterDots(_ f: inout Frame, _ heights: [Int], _ peaks: [Double], _ theme: String) {
        let n = heights.count, H = Frame.H
        for (i, h) in heights.enumerated() {
            let x = i * 3
            if h > 0 {
                let dh = 2
                let y0 = min(H - dh, H - h)
                let col = Self.c(i, Double(h) / Double(H), theme, n)
                for yy in y0..<(y0 + dh) { col2(&f, x, yy, col) }
            }
            let ph = Int(peaks[i])
            if ph > h && ph > 0 { col2(&f, x, H - ph, Self.peakColor) }
        }
    }

    /// A continuous contour line connecting the band tops (oscilloscope-style).
    func rasterWave(_ f: inout Frame, _ heights: [Int], _ peaks: [Double], _ theme: String) {
        let n = heights.count, H = Frame.H
        let tops = heights.map { H - max(1, $0) }
        for (i, h) in heights.enumerated() {
            let x = i * 3
            let col = Self.c(i, Double(max(1, h)) / Double(H), theme, n)
            col2(&f, x, tops[i], col)
            if i < n - 1 {
                let lo = min(tops[i], tops[i + 1]), hi = max(tops[i], tops[i + 1])
                for yy in lo...hi { px(&f, x + 2, yy, col) }
            }
        }
    }
}

// MARK: - Settings

struct MusicSettingsView: View {
    @AppStorage("music.style") private var style = "bars"
    @AppStorage("music.theme") private var theme = "classic"
    @AppStorage("music.fps") private var fps = 15
    @AppStorage("music.showTrack") private var showTrack = true

    var body: some View {
        Form {
            Picker("Style", selection: $style) {
                ForEach(MusicApp.styleNames, id: \.self) { Text($0) }
            }
            Picker("Theme", selection: $theme) {
                ForEach(MusicApp.themeNames, id: \.self) { Text($0) }
            }
            TextField("Frames per second", value: $fps, format: .number)
            Toggle("Show current track", isOn: $showTrack)
        }
        .frame(width: 240)
    }
}
