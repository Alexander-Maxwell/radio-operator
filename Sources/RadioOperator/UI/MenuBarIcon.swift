import AppKit

/// The menu-bar glyph: a spade with a broadcast-signal motif, drawn as a vector
/// so it stays crisp at any menu-bar scale. Rendered as a template image (macOS
/// tints it to the menu bar) at rest, and solid red while capturing — keeping
/// the load-bearing "red = live microphone" rule.
enum MenuBarIcon {
    static func image(capturing: Bool) -> NSImage {
        let img = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
            (capturing ? NSColor.systemRed : NSColor.black).setFill()
            path(in: rect.insetBy(dx: rect.width * 0.06, dy: rect.height * 0.06)).fill()
            return true
        }
        img.isTemplate = !capturing
        return img
    }

    static func path(in rect: NSRect) -> NSBezierPath {
        func P(_ x: CGFloat, _ y: CGFloat) -> NSPoint {
            NSPoint(x: rect.minX + x * rect.width, y: rect.minY + (1 - y) * rect.height)
        }
        let p = NSBezierPath()
        p.move(to: P(0.50, 0.07))
        p.curve(to: P(0.92, 0.54), controlPoint1: P(0.66, 0.17), controlPoint2: P(0.94, 0.35))
        p.curve(to: P(0.70, 0.70), controlPoint1: P(0.915, 0.66), controlPoint2: P(0.82, 0.735))
        p.curve(to: P(0.54, 0.62), controlPoint1: P(0.63, 0.685), controlPoint2: P(0.57, 0.66))
        p.curve(to: P(0.63, 0.91), controlPoint1: P(0.55, 0.71), controlPoint2: P(0.575, 0.81))
        p.line(to: P(0.37, 0.91))
        p.curve(to: P(0.46, 0.62), controlPoint1: P(0.425, 0.81), controlPoint2: P(0.45, 0.71))
        p.curve(to: P(0.30, 0.70), controlPoint1: P(0.43, 0.66), controlPoint2: P(0.37, 0.685))
        p.curve(to: P(0.08, 0.54), controlPoint1: P(0.18, 0.735), controlPoint2: P(0.085, 0.66))
        p.curve(to: P(0.50, 0.07), controlPoint1: P(0.06, 0.35), controlPoint2: P(0.34, 0.17))
        p.close()

        let c = P(0.50, 0.50)
        let dot = 0.058 * rect.width
        p.appendOval(in: NSRect(x: c.x - dot, y: c.y - dot, width: 2 * dot, height: 2 * dot))

        func arc(_ rIn: CGFloat, _ rOut: CGFloat, _ a0: CGFloat, _ a1: CGFloat) {
            let seg = NSBezierPath()
            seg.appendArc(withCenter: c, radius: rOut * rect.width, startAngle: a0, endAngle: a1, clockwise: false)
            seg.appendArc(withCenter: c, radius: rIn * rect.width, startAngle: a1, endAngle: a0, clockwise: true)
            seg.close()
            p.append(seg)
        }
        arc(0.115, 0.155, -52, 52)
        arc(0.195, 0.235, -48, 48)
        arc(0.115, 0.155, 128, 232)
        arc(0.195, 0.235, 132, 228)

        p.windingRule = .evenOdd
        return p
    }
}
