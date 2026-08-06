import Foundation

/// Odometer animation for numbers that change while a widget is on screen.
///
/// It animates the device's own font: each character that changed is covered
/// with a black rect and redrawn as its own text element, which can then be told
/// to sit at a negative `y` — coordinates go down to -4096 — so it slides. The
/// rest of the number is left alone, still drawn by the widget's own text
/// element underneath.
///
/// Nothing clips on the device, so the overflow is hidden by painting the rows
/// on either side black. That is what limits the throw: the gutter between the
/// two text lines is 3 rows, and painting more than that would eat the other
/// line.
///
/// Element ids are budgeted: the bar rejects a draw of more than 100 elements
/// (measured), and a widget's own frame needs most of that. Hence `maxCells`,
/// and hence covering the changed characters rather than re-drawing the whole
/// number as one element per character.
enum Roll {
    /// The only font that is rolled. Everything below is in its metrics.
    static let font = DeviceFont.small
    static let inkH = 5
    /// Rows of gutter above and below a line of text, and so how far a character
    /// can travel before the mask runs out of room.
    static let travel = 3
    static let steps = [1, 2, 3]
    /// Cells start one frame apart, rightmost first.
    static let stagger = 1
    /// At most this many characters animate — each costs three element ids, and
    /// a change bigger than this is not a tick of an odometer anyway. The rest of
    /// the reading snaps to its new value.
    static let maxCells = 4
    static let mask = "#000000FF"
    static let clear = "#00000000"
    static let secondsPerFrame = 0.05

    /// Where a number sits: the x of its leftmost ink column, or of the column
    /// one past the last (what `textEl(align: "top_right")` is anchored to).
    enum Anchor {
        case left(Int)
        case right(Int)
    }

    /// One number on screen. `from`/`to` are what the text element showed and
    /// what it is about to show.
    struct Field {
        let id: String
        let from: String, to: String
        let anchor: Anchor
        /// Row of the top line of ink — `textEl(y:)` + 2 in the small font.
        let y: Int
        let color: String
    }

    // MARK: - Playing

    /// Rolls every field, then draws `then` — the widget's own new frame, which
    /// puts the real value in the real text element — in the same request that
    /// retires the animation, so nothing flashes and nothing is left behind.
    /// `over` is anything of the widget's own that lives in the rows the masks
    /// paint over — Flightradar's progress bar sits in the gutter at row 8, which
    /// is exactly where a roll on either line hides its overflow. Those elements
    /// are re-drawn under new ids *after* the masks, since the bar paints in the
    /// order it first saw an element and the widget's originals were created
    /// long before.
    static func play(client: BarClient, app: String, fields: [Field],
                     priority: Int? = nil, over: [[String: Any]] = [],
                     then final: [[String: Any]]) async {
        let plans = fields.map(plan(for:)).filter { !$0.cells.isEmpty }
        guard !plans.isEmpty else {
            _ = try? await client.draw(app: app, elements: final, priority: priority)
            return
        }
        let last = plans.map(lastFrame).max() ?? 0
        for t in 0...last {
            var els = plans.flatMap { frame($0, t: t) }
            if t == 0 { els += overlay(over) }
            _ = try? await client.draw(app: app, elements: els, priority: priority)
            if Task.isCancelled {
                // Cancelled mid-roll: put the frame back from a live task, since
                // URLSession will not send from a cancelled one, or the bar keeps
                // half an animation. Same reason `Runner.stop` clears detached.
                let els = final + plans.flatMap(retire) + retireOverlay(over)
                Task.detached { _ = try? await client.draw(app: app, elements: els,
                                                           priority: priority) }
                return
            }
            _ = await barSleep(secondsPerFrame)
        }
        _ = try? await client.draw(app: app,
                                   elements: final + plans.flatMap(retire) + retireOverlay(over),
                                   priority: priority)
    }

    /// The same elements under `-ov` ids, so they can be created after the masks
    /// and so retiring them cannot touch the widget's own.
    static func overlay(_ els: [[String: Any]]) -> [[String: Any]] {
        els.map { el in
            var copy = el
            copy["id"] = "\(el["id"] as? String ?? "x")-ov"
            return copy
        }
    }

    static func retireOverlay(_ els: [[String: Any]]) -> [[String: Any]] {
        overlay(els).map { el in
            var copy = el
            if (el["type"] as? String) == "text" {
                copy["text"] = ""
            } else {
                copy["fill_colors"] = [clear]
                copy["width"] = 1
                copy["height"] = 1
            }
            return copy
        }
    }

    // MARK: - Pure layout

    /// One character position that is going to move.
    struct Cell {
        let index: Int
        let old: Character, new: Character
        let x: Int
        /// The character's own advance, so the cover erases all of it — the font
        /// is proportional.
        let width: Int
        /// Frame this cell starts moving on.
        let start: Int
    }

    struct Plan {
        let field: Field
        let cells: [Cell]
        /// Value went up, so the old characters fall away and the new ones drop
        /// in from above.
        let up: Bool
    }

    static func lastFrame(_ p: Plan) -> Int {
        (p.cells.map(\.start).max() ?? 0) + steps.count
    }

    /// The characters that move, laid out with the real advances of the device
    /// font — a "." is 2px wide, an "M" is 6.
    ///
    /// A character can only roll *in place*, so one is animated when it changed
    /// and the reading did not shift under it. The font is proportional: a "1" is
    /// 3px and every other digit 4, so "1.410m" → "1.372m" moves everything left
    /// of the "7" sideways — those characters snap, while the ones that held
    /// still roll. Bailing on the whole field the moment anything shifted is what
    /// left altitude jumping while speed rolled.
    static func plan(for f: Field) -> Plan {
        let up = value(f.to) >= value(f.from)
        let old = Array(f.from), new = Array(f.to)
        guard old.count == new.count else { return Plan(field: f, cells: [], up: up) }
        let oldX = positions(old, f.anchor), newX = positions(new, f.anchor)

        let movable = (0..<old.count).filter {
            old[$0] != new[$0] && oldX[$0] == newX[$0]
                && font.advance(old[$0]) == font.advance(new[$0])
        }
        // The rightmost few, because that is where a reading actually ticks, and
        // because every cell costs three element ids.
        let kept = Array(movable.suffix(maxCells))
        guard !kept.isEmpty else { return Plan(field: f, cells: [], up: up) }
        // Rightmost first: the character nearest the end starts on frame 0.
        let cells = kept.enumerated().map { rank, i in
            Cell(index: i, old: old[i], new: new[i], x: oldX[i],
                 width: font.advance(new[i]),
                 start: (kept.count - 1 - rank) * stagger)
        }
        return Plan(field: f, cells: cells, up: up)
    }

    /// The x the device draws each character at, walking the string.
    static func positions(_ chars: [Character], _ anchor: Anchor) -> [Int] {
        var x: Int
        switch anchor {
        case .left(let l):  x = l
        case .right(let r): x = r - chars.reduce(0) { $0 + font.advance($1) }
        }
        var out: [Int] = []
        for ch in chars {
            out.append(x)
            x += font.advance(ch)
        }
        return out
    }

    /// One frame.
    ///
    /// Frame 0 creates every element the roll will ever touch — cover, both
    /// characters, then the masks — because the bar paints elements in the order
    /// it first saw them: a character created later would sit on top of the mask
    /// meant to hide it, and a cover created later would sit on top of the
    /// character it is meant to be behind. Later frames only move what changed,
    /// since resending an unchanged element makes the bar replay its settle
    /// animation.
    static func frame(_ p: Plan, t: Int) -> [[String: Any]] {
        let f = p.field
        let top = f.y - DeviceFont.smallInkOffset   // what textEl's y means
        var els: [[String: Any]] = []

        if t == 0 {
            for c in p.cells {
                els.append(rectEl(bid(f, c), x: c.x, y: f.y, w: c.width, h: inkH, color: mask))
            }
        }
        for c in p.cells {
            let k = t - c.start
            if k <= 0 {
                if t == 0 {
                    els.append(char(f, c.old, id: oid(f, c), x: c.x, y: top))
                    els.append(hidden(nid(f, c), x: c.x, y: top))
                }
                continue
            }
            // Landed: the new character at rest, until `then` hands the number
            // back to its own element. Sent once, then left alone.
            if k > steps.count {
                if k == steps.count + 1 {
                    els.append(hidden(oid(f, c), x: c.x, y: top))
                    els.append(char(f, c.new, id: nid(f, c), x: c.x, y: top))
                }
                continue
            }
            let d = steps[k - 1] * (p.up ? 1 : -1)
            els.append(char(f, c.old, id: oid(f, c), x: c.x, y: top + d))
            // The incoming character appears only once it is inside the masked
            // rows; a frame earlier and its top would show above the line.
            if k == steps.count {
                els.append(char(f, c.new, id: nid(f, c), x: c.x,
                                y: top + d - (p.up ? travel * 2 : -travel * 2)))
            }
        }
        if t == 0 { els += masks(p) }
        return els
    }

    static func bid(_ f: Field, _ c: Cell) -> String { "\(f.id)-b\(c.index)" }
    static func oid(_ f: Field, _ c: Cell) -> String { "\(f.id)-o\(c.index)" }
    static func nid(_ f: Field, _ c: Cell) -> String { "\(f.id)-n\(c.index)" }

    /// Two rects, black, over the gutter row either side of the whole animated
    /// span — one pair per field rather than per character, because element ids
    /// are the budget.
    static func masks(_ p: Plan) -> [[String: Any]] {
        let f = p.field
        let x = p.cells.map(\.x).min() ?? 0
        let w = (p.cells.map { $0.x + $0.width }.max() ?? 0) - x
        return [
            rectEl("\(f.id)-ma", x: x, y: f.y - travel, w: w, h: travel, color: mask),
            rectEl("\(f.id)-mb", x: x, y: f.y + inkH, w: w, h: travel, color: mask),
        ]
    }

    /// Everything the animation drew, emptied out. Text goes to an empty string
    /// and rects to transparent — the device keeps an element until something
    /// overwrites it, and an opaque rect left behind is a number that never
    /// comes back.
    static func retire(_ p: Plan) -> [[String: Any]] {
        let top = p.field.y - DeviceFont.smallInkOffset
        var els: [[String: Any]] = []
        for c in p.cells {
            els.append(rectEl(bid(p.field, c), x: c.x, y: p.field.y, w: 1, h: 1, color: clear))
            els.append(hidden(oid(p.field, c), x: c.x, y: top))
            els.append(hidden(nid(p.field, c), x: c.x, y: top))
        }
        els.append(rectEl("\(p.field.id)-ma", x: 0, y: p.field.y - travel, w: 1, h: 1,
                          color: clear))
        els.append(rectEl("\(p.field.id)-mb", x: 0, y: p.field.y + inkH, w: 1, h: 1,
                          color: clear))
        return els
    }

    /// How many element ids a roll of these fields will occupy, so a widget can
    /// be checked against the device's budget.
    static func idCount(_ fields: [Field]) -> Int {
        fields.map(plan(for:)).reduce(0) { $0 + ($1.cells.isEmpty ? 0 : $1.cells.count * 3 + 2) }
    }

    // MARK: - Elements

    static func char(_ f: Field, _ ch: Character, id: String, x: Int, y: Int) -> [String: Any] {
        textEl(id, String(ch), x: x, y: y, font: font.api, color: f.color, align: "top_left")
    }

    /// An empty text element: the only way to make text go away, since elements
    /// persist by id until something overwrites them.
    static func hidden(_ id: String, x: Int, y: Int) -> [String: Any] {
        textEl(id, "", x: x, y: y, font: font.api, color: "#FFFFFFFF", align: "top_left")
    }

    /// Digits only, so "12.3%" and "$12.30" both compare as numbers and the roll
    /// goes the way the value went. Unparseable strings roll upward.
    static func value(_ s: String) -> Double {
        Double(s.filter { $0.isNumber || $0 == "." || $0 == "-" }) ?? 0
    }

    #if DEBUG
    /// ponytail: assert-based check instead of a test target, next to Carousel's.
    static func selfCheck() {
        // Only the changed position moves, and it costs three ids plus the pair
        // of masks — the whole point of the rewrite.
        let f = Field(id: "p", from: "12.34", to: "12.35", anchor: .right(73), y: 2,
                      color: "#FFFFFFFF")
        let p = plan(for: f)
        assert(p.cells.count == 1, "one digit changed, one cell")
        assert(p.up, "35 is more than 34")
        assert(idCount([f]) == 5, "three ids for the character, two for the masks")
        // Laid out by measured advance: "12.34" is 17px, not 5 cells of 4 — a "1"
        // is 3px and a full stop 2.
        assert(font.width("12.34") == 17, "measured, not counted")
        assert(p.cells[0].x + font.advance("4") == 73, "the last cell ends at the anchor")

        // Rightmost first, one frame apart. Every digit here is 4px, so the
        // layout holds still and all three can roll.
        let many = plan(for: Field(id: "p", from: "223", to: "334", anchor: .right(73), y: 2,
                                   color: "#FFFFFFFF"))
        assert(many.cells.map(\.start) == [2, 1, 0], "the right-hand digit leads")
        assert(many.up, "223 to 334 rolls upward")
        // A "1" is 3px and every other digit 4, so gaining or losing one shifts
        // the whole reading and it is redrawn rather than rolled.
        assert(plan(for: Field(id: "p", from: "191", to: "202", anchor: .right(73), y: 2,
                               color: "#FFFFFFFF")).cells.isEmpty,
               "same character count, different width")
        assert(!plan(for: Field(id: "p", from: "5", to: "4", anchor: .right(73), y: 2,
                                color: "#FFFFFFFF")).up, "4 after 5 rolls down")

        // A reading of a different length is redrawn, not rolled.
        assert(plan(for: Field(id: "s", from: "999", to: "1000", anchor: .right(73), y: 2,
                               color: "#FFFFFFFF")).cells.isEmpty, "a digit gained is a redraw")
        // When the reading shifts under some characters, the ones that held
        // still still roll — this is Flightradar's altitude, which used to jump.
        let alt = plan(for: Field(id: "l2right", from: "1.410m", to: "1.372m",
                                  anchor: .right(73), y: 10, color: "#FFFFFFFF"))
        assert(alt.cells.count == 1 && alt.cells[0].old == "0" && alt.cells[0].new == "2",
               "the last digit holds its place, so it rolls")
        assert(!alt.up, "1.372 is less than 1.410")
        let stable = plan(for: Field(id: "s", from: "1.11", to: "11.1", anchor: .right(73), y: 2,
                                     color: "#FFFFFFFF"))
        assert(stable.cells.allSatisfy { $0.x == positions(Array("11.1"), .right(73))[$0.index] },
               "a rolled cell is always at the x the new reading puts it")
        assert(plan(for: Field(id: "s", from: "2222", to: "8888", anchor: .right(73), y: 2,
                               color: "#FFFFFFFF")).cells.count == 4, "four is the most that rolls")
        // More than four changed: the rightmost four roll and the rest snap,
        // rather than nothing moving at all.
        let five = plan(for: Field(id: "s", from: "22222", to: "88888", anchor: .right(73), y: 2,
                                   color: "#FFFFFFFF"))
        assert(five.cells.count == maxCells, "capped at four")
        assert(five.cells.map(\.index) == [1, 2, 3, 4], "and they are the rightmost four")
        assert(idCount([f, f]) == 10, "two fields, ten ids — a budget a widget can afford")

        // Anything of the widget's own that lives under the masks is re-drawn on
        // top of them, under its own ids, and retired with them.
        let bar = [rectEl("prog_done", x: 0, y: 8, w: 40, h: 1, color: "#FFA028FF")]
        assert((overlay(bar)[0]["id"] as? String) == "prog_done-ov",
               "the copy has its own id, so retiring it cannot blank the original")
        assert((retireOverlay(bar)[0]["fill_colors"] as? [String]) == [clear],
               "and it retires transparent")

        // Left-anchored numbers grow rightward, by advance.
        let left = plan(for: Field(id: "s", from: "1.2K", to: "1.3K", anchor: .left(0), y: 10,
                                   color: "#FFFFFFFF"))
        assert(left.cells.count == 1 && left.cells[0].new == "3", "prefix and suffix stay put")
        assert(left.cells[0].x == 5, "1 is 3px and a full stop 2, so the third cell is at 5")

        // The number's own element is never touched: the changed characters are
        // covered instead, so a draw that goes missing cannot leave a blank.
        let first = frame(p, t: 0)
        assert(!first.contains { $0["id"] as? String == "p" }, "the real element is left alone")
        assert((first[0]["id"] as? String) == bid(f, p.cells[0])
                 && (first[0]["type"] as? String) == "rectangle",
               "the cover is created first, so it sits behind the character")
        assert((first.last?["id"] as? String) == "p-mb", "and the masks last, on top of everything")

        // Nothing is drawn outside the line's rows plus the gutter the mask
        // covers — that is what stops a roll eating the other line.
        for t in 0...lastFrame(p) {
            for el in frame(p, t: t) where (el["type"] as? String) == "text" {
                let ink = (el["y"] as? Int ?? 0) + DeviceFont.smallInkOffset
                let text = el["text"] as? String ?? ""
                assert(text.isEmpty || (ink >= f.y - travel && ink + inkH <= f.y + inkH + travel),
                       "character at ink row \(ink) is outside the masked window")
            }
        }

        // Every id the animation draws has to be retired, or a cover is left
        // behind on top of the number.
        var drawn = Set<String>()
        for t in 0...lastFrame(p) { drawn.formUnion(frame(p, t: t).map { $0["id"] as! String }) }
        let cleared = Set(retire(p).map { $0["id"] as! String })
        assert(drawn == cleared, "left behind: \(drawn.symmetricDifference(cleared))")
        assert(retire(p).filter { ($0["type"] as? String) == "rectangle" }
                        .allSatisfy { ($0["fill_colors"] as? [String]) == [clear] },
               "covers and masks retire transparent")

        assert(value("12.3%") == 12.3 && value("1000") == 1000, "digits drive the direction")
    }
    #endif
}
