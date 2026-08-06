import Foundation

/// Port of nyan.py — pop-tart cat with a rainbow trail and twinkling stars.
/// Each frame is one 72x16 PNG pushed as a single image element (see Frame).
final class NyanApp: MiniApp {
    let app = "nyan-cat"

    // Palette
    let crust: (UInt8, UInt8, UInt8) = (0xFF, 0xCC, 0x99)
    let frosting: (UInt8, UInt8, UInt8) = (0xFF, 0x99, 0xFF)
    let sprinkle: (UInt8, UInt8, UInt8) = (0xDD, 0x33, 0x88)
    let gray: (UInt8, UInt8, UInt8) = (0x99, 0x99, 0x99)
    let black: (UInt8, UInt8, UInt8) = (0x00, 0x00, 0x00)
    let cheek: (UInt8, UInt8, UInt8) = (0xFF, 0x99, 0x99)
    let star: (UInt8, UInt8, UInt8) = (0xFF, 0xFF, 0xFF)
    let rainbow: [(UInt8, UInt8, UInt8)] = [
        (0xFF, 0x00, 0x00), (0xFF, 0x99, 0x00), (0xFF, 0xFF, 0x00),
        (0x33, 0xFF, 0x00), (0x00, 0x99, 0xFF), (0x66, 0x33, 0xFF)]

    // Layout
    let cx = 44, by0 = 3          // pop-tart body top-left
    var hx: Int { cx + 9 }        // head overlaps the body's right side
    let hy0 = 5
    var trailEnd: Int { cx - 5 }  // rainbow stops before the tail

    struct Star { var x: Int; var y: Int; var p: Int }
    var stars = [Star(x: 8, y: 3, p: 0), Star(x: 26, y: 13, p: 2),
                 Star(x: 46, y: 1, p: 1), Star(x: 66, y: 11, p: 3)]

    // The device briefly locks an asset while a draw reads it; re-uploading the
    // same name too soon returns HTTP 508, so rotate through a few filenames.
    let ring = 4
    var frameNo = 0
    var t = 0
    let frameT = 0.08  // ~12.5 fps; the image push itself takes ~50 ms

    func run(client: BarClient, status: @escaping @Sendable (String) -> Void) async {
        status("nyaning at \(client.base.host ?? "?")")
        while !Task.isCancelled {
            let t0 = Date()
            t += 1
            let phase = (t / 3) % 2
            var f = Frame()
            tickStars(&f)
            drawRainbow(&f, phase: phase)
            drawCat(&f, phase: phase)
            let fn = "frame\(frameNo % ring).png"
            frameNo += 1
            do {
                try await client.uploadAsset(app: app, file: fn, data: f.png())
                let code = try await client.draw(app: app, elements: [imageEl("frame", path: fn)])
                if code == 409 { status("display busy (409)") }
            } catch {
                status("error: \(error.localizedDescription)")
                _ = await barSleep(1.0)
            }
            let dt = Date().timeIntervalSince(t0)
            if dt < frameT { if !(await barSleep(frameT - dt)) { break } }
        }
        await client.clear(app: app)
    }

    // Stars twinkle behind the rainbow and the cat.
    func tickStars(_ f: inout Frame) {
        for i in stars.indices {
            stars[i].x -= 3
            stars[i].p = (stars[i].p + 1) % 4
            if stars[i].x < -2 {
                stars[i].x = Frame.W + Int.random(in: 0...10)
                stars[i].y = Int.random(in: 1...(Frame.H - 2))
            }
            let (x, y, p) = (stars[i].x, stars[i].y, stars[i].p)
            switch p {
            case 0: f.rect(x, y, 1, 1, star)
            case 1: f.rect(x - 1, y, 3, 1, star); f.rect(x, y - 1, 1, 3, star)
            case 2: f.rect(x - 2, y, 5, 1, star); f.rect(x, y - 2, 1, 5, star)
            default:
                for (dx, dy) in [(-2, 0), (2, 0), (0, -2), (0, 2)] {
                    f.rect(x + dx, y + dy, 1, 1, star)
                }
            }
        }
    }

    // 6 bands of 2px, wiggling in 8px blocks that alternate offset.
    func drawRainbow(_ f: inout Frame, phase: Int) {
        for (band, color) in rainbow.enumerated() {
            let y = 2 + band * 2
            var x = 0
            while x < trailEnd {
                let w = min(8, trailEnd - x)
                let off = (x / 8 + phase) % 2
                f.rect(x, y + off, w, 2, color)
                x += w
            }
        }
    }

    // Layered rects; later writes draw on top of earlier ones.
    func drawCat(_ f: inout Frame, phase: Int) {
        let bob = phase                 // body bobs 1px down every other beat
        let by = by0 + bob, hy = hy0 + bob

        // tail (flips up/down against the bob)
        f.rect(cx - 2, by + 5, 2, 2, gray)
        if phase == 0 { f.rect(cx - 4, by + 3, 2, 2, gray) }
        else { f.rect(cx - 4, by + 7, 2, 2, gray) }

        // legs stay planted; a 1px x-shuffle suggests the gallop
        for lx in [cx + 1, cx + 5, cx + 10, cx + 14] {
            f.rect(lx + bob, 13, 2, 2, gray)
        }

        // pop-tart body (inset top/bottom rows fake the rounded corners)
        f.rect(cx + 1, by, 12, 1, crust)
        f.rect(cx, by + 1, 14, 8, crust)
        f.rect(cx + 1, by + 9, 12, 1, crust)
        f.rect(cx + 1, by + 1, 12, 8, frosting)
        for (sx, sy) in [(2, 2), (6, 3), (3, 5), (7, 6), (5, 7)] {
            f.rect(cx + sx, by + sy, 1, 1, sprinkle)
        }

        // head + ears
        f.rect(hx + 1, hy, 8, 1, gray)
        f.rect(hx, hy + 1, 10, 6, gray)
        f.rect(hx + 1, hy + 7, 8, 1, gray)
        f.rect(hx + 1, hy - 2, 1, 1, gray)
        f.rect(hx + 1, hy - 1, 2, 1, gray)
        f.rect(hx + 8, hy - 2, 1, 1, gray)
        f.rect(hx + 7, hy - 1, 2, 1, gray)

        // face: eyes, cheeks, smile
        f.rect(hx + 2, hy + 2, 1, 1, black)
        f.rect(hx + 7, hy + 2, 1, 1, black)
        f.rect(hx + 1, hy + 4, 1, 1, cheek)
        f.rect(hx + 8, hy + 4, 1, 1, cheek)
        f.rect(hx + 2, hy + 4, 1, 1, black)
        f.rect(hx + 6, hy + 4, 1, 1, black)
        f.rect(hx + 3, hy + 5, 3, 1, black)
    }
}
