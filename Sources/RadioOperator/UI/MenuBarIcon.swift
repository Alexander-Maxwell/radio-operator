import AppKit

/// The Radio Operator brand mark: **"R over O" in Morse code** — two clean rows
/// of dots and dashes (R = ·−· on top, O = −−− below). Reads as a tidy abstract
/// soundwave to everyone, an insider callsign to those who know, and bakes the
/// "signal" story into the letters themselves.
///
/// Pure geometry — dots are circles, dashes are capsules — so there's no font
/// dependency and it stays crisp from the 1024px app icon down to an 18pt
/// menu-bar template. Single source of truth for the icon, the menu-bar glyph,
/// and (optionally) the pill.
enum MenuBarIcon {

    /// `standard` (icon / in-app) leaves generous padding; `menubar` fills more
    /// of the frame so the little mark survives at 18pt.
    enum Variant { case standard, menubar }

    // MARK: - Image builders

    /// The menu-bar glyph. Template (system-tinted) at rest, solid red while
    /// capturing — keeping the load-bearing "red = live microphone" rule.
    static func image(capturing: Bool) -> NSImage {
        let out = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
            drawDish(in: rect, color: capturing ? .systemRed : .black)
            return true
        }
        out.isTemplate = !capturing   // system tints it for the bar
        return out
    }

    /// A SATCOM dish aimed at the sky: filled parabolic reflector on a pedestal,
    /// feed horn on an arm, three uplink waves. Reads at the 36px Retina menu-bar
    /// size. Drawn on a 200×200 grid (y-down) mapped to `rect`.
    static func drawDish(in rect: NSRect, color: NSColor) {
        color.set()
        let s = min(rect.width, rect.height) / 200
        func P(_ x: CGFloat, _ y: CGFloat) -> NSPoint {
            NSPoint(x: rect.minX + x * s, y: rect.maxY - y * s)
        }
        func stroke(_ a: NSPoint, _ b: NSPoint, _ w: CGFloat) {
            let p = NSBezierPath(); p.move(to: a); p.line(to: b)
            p.lineWidth = w * s; p.lineCapStyle = .round; p.stroke()
        }
        // Reflector (filled bowl, opening up).
        let dish = NSBezierPath()
        dish.appendArc(withCenter: P(90, 66), radius: 80 * s, startAngle: 200, endAngle: 340, clockwise: false)
        dish.appendArc(withCenter: P(90, 66), radius: 58 * s, startAngle: 340, endAngle: 200, clockwise: true)
        dish.close(); dish.fill()
        stroke(P(90, 126), P(90, 172), 14)   // pedestal
        stroke(P(66, 176), P(114, 176), 14)  // foot
        let fc = P(126, 46)
        stroke(P(120, 96), fc, 8)            // feed arm
        let fh = 10.0 * s
        NSBezierPath(ovalIn: NSRect(x: fc.x - fh, y: fc.y - fh, width: 2 * fh, height: 2 * fh)).fill()  // horn
        for rad in [26.0, 42.0, 58.0] {      // uplink waves
            let w = NSBezierPath()
            w.appendArc(withCenter: fc, radius: rad * s, startAngle: -8, endAngle: 58, clockwise: false)
            w.lineWidth = 7 * s; w.lineCapStyle = .round; w.stroke()
        }
    }

    /// The mark tinted for in-app use (e.g. cream on the violet tile, or the
    /// pill). Not a template.
    static func emblem(color: NSColor, size: CGFloat) -> NSImage {
        NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            draw(in: rect, color: color, variant: .standard)
            return true
        }
    }

    // MARK: - Vector drawing

    /// Morse rows, top to bottom. `true` = dash, `false` = dot. R (·−·) over O (−−−).
    private static let rows: [[Bool]] = [[false, true, false], [true, true, true]]

    static func draw(in rect: NSRect, color: NSColor, variant: Variant) {
        color.set()
        let side = min(rect.width, rect.height)

        // Proportions (in units of the bar thickness `t`).
        let widthFrac: CGFloat = (variant == .menubar) ? 0.92 : 0.60   // widest row / frame
        let dashRatio: CGFloat = 2.4      // dash length / thickness
        let gapXRatio: CGFloat = 0.85     // gap between cells in a row
        let gapYRatio: CGFloat = 1.2      // gap between the two rows

        func rowUnits(_ row: [Bool]) -> CGFloat {
            row.reduce(0) { $0 + ($1 ? dashRatio : 1) } + gapXRatio * CGFloat(row.count - 1)
        }
        let widest = rows.map(rowUnits).max() ?? 1
        let t = widthFrac * side / widest
        let dashW = dashRatio * t
        let gapX = gapXRatio * t
        let gapY = gapYRatio * t
        let markH = CGFloat(rows.count) * t + gapY * CGFloat(rows.count - 1)

        // Centered in the frame; y is up, so start at the top row and step down.
        var yCenter = rect.midY + markH / 2 - t / 2
        for row in rows {
            let rowW = rowUnits(row) * t
            var x = rect.midX - rowW / 2
            for isDash in row {
                let w = isDash ? dashW : t
                let cell = NSRect(x: x, y: yCenter - t / 2, width: w, height: t)
                NSBezierPath(roundedRect: cell, xRadius: t / 2, yRadius: t / 2).fill()
                x += w + gapX
            }
            yCenter -= (t + gapY)
        }
    }
}
