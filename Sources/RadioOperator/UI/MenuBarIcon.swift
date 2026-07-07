import AppKit

/// The Radio Operator brand mark: a bold **R** enclosed in an **O** ring — the
/// ring reads as both the letter O and a record button, so the whole thing is
/// one confident "Enclosed" monogram. Authored on a 200×200 grid (see
/// `design_handoff_ro_identity/assets/ro-mark.svg`) and drawn as a vector so it
/// stays crisp from the 1024px app icon down to an 18pt menu-bar template.
///
/// This is the single geometry source of truth: the menu-bar glyph, the
/// recording-pill mark, and the exported app icon all stroke the same path.
enum MenuBarIcon {

    /// The mark comes in two weights. `standard` matches `ro-mark.svg` /
    /// `app-icon.svg` (ring r66 / stroke 15, R stroke 20). `menubar` is the
    /// bolder `menubar-template.svg` variant (ring r78 / stroke 16, R stroke 24)
    /// that fills more of the frame so it survives at 18pt.
    enum Variant { case standard, menubar }

    // MARK: - Image builders

    /// The menu-bar glyph. A template image (the system tints it for the light
    /// or dark bar and highlight state) at rest, and solid red while capturing —
    /// keeping the load-bearing "red = live microphone" rule.
    static func image(capturing: Bool) -> NSImage {
        let img = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
            draw(in: rect, color: capturing ? .systemRed : .black, variant: .menubar)
            return true
        }
        img.isTemplate = !capturing
        return img
    }

    /// The mark tinted to a fixed color, for in-app surfaces like the recording
    /// pill (violet on the near-black capsule). Not a template — it keeps its
    /// own color.
    static func emblem(color: NSColor, size: CGFloat) -> NSImage {
        NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            draw(in: rect, color: color, variant: .standard)
            return true
        }
    }

    // MARK: - Vector drawing

    /// Strokes the R-in-O mark to fit `rect`, mapping the 200×200 authoring grid
    /// onto it. `color` paints the ring and the R at matched visual weight.
    static func draw(in rect: NSRect, color: NSColor, variant: Variant) {
        color.set()
        let s = min(rect.width, rect.height) / 200.0

        // Map a grid point (0…200, y-DOWN like SVG) to the y-UP image rect.
        func P(_ x: CGFloat, _ y: CGFloat) -> NSPoint {
            NSPoint(x: rect.minX + x * s, y: rect.maxY - y * s)
        }

        // Per-variant geometry (grid units).
        let ringR: CGFloat, ringW: CGFloat, rW: CGFloat
        let stemX: CGFloat, stemTop: CGFloat, stemBot: CGFloat
        let leftX: CGFloat, arcX: CGFloat, topY: CGFloat, botY: CGFloat, cy: CGFloat, bowlR: CGFloat
        let legX0: CGFloat, legY0: CGFloat, legX1: CGFloat, legY1: CGFloat
        switch variant {
        case .standard:
            ringR = 66; ringW = 15; rW = 20
            stemX = 78; stemTop = 62; stemBot = 138
            leftX = 78; arcX = 100; topY = 66; botY = 110; cy = 88; bowlR = 22
            legX0 = 85; legY0 = 108; legX1 = 120; legY1 = 138
        case .menubar:
            ringR = 78; ringW = 16; rW = 24
            stemX = 80; stemTop = 60; stemBot = 140
            leftX = 80; arcX = 102; topY = 64; botY = 110; cy = 87; bowlR = 23
            legX0 = 87; legY0 = 108; legX1 = 122; legY1 = 140
        }

        // The O ring (also the record button).
        let c = P(100, 100)
        let rr = ringR * s
        let ring = NSBezierPath(ovalIn: NSRect(x: c.x - rr, y: c.y - rr, width: 2 * rr, height: 2 * rr))
        ring.lineWidth = ringW * s
        ring.stroke()

        // R stem.
        let stem = NSBezierPath()
        stem.move(to: P(stemX, stemTop))
        stem.line(to: P(stemX, stemBot))
        stem.lineCapStyle = .round
        stem.lineWidth = rW * s
        stem.stroke()

        // R bowl: flat left edge + a right-bulging semicircle, drawn as two
        // cubic quarter-arcs (k = kappa·r) so it matches the SVG elliptical arc.
        let k = 0.5522847498 * bowlR
        let bowl = NSBezierPath()
        bowl.move(to: P(leftX, topY))
        bowl.line(to: P(arcX, topY))
        bowl.curve(to: P(arcX + bowlR, cy),
                   controlPoint1: P(arcX + k, topY),
                   controlPoint2: P(arcX + bowlR, cy - k))
        bowl.curve(to: P(arcX, botY),
                   controlPoint1: P(arcX + bowlR, cy + k),
                   controlPoint2: P(arcX + k, botY))
        bowl.line(to: P(leftX, botY))
        bowl.lineCapStyle = .round
        bowl.lineJoinStyle = .round
        bowl.lineWidth = rW * s
        bowl.stroke()

        // R leg.
        let leg = NSBezierPath()
        leg.move(to: P(legX0, legY0))
        leg.line(to: P(legX1, legY1))
        leg.lineCapStyle = .round
        leg.lineWidth = rW * s
        leg.stroke()
    }
}
