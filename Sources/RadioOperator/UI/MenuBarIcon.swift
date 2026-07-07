import AppKit
import CoreText

/// The Radio Operator brand mark: a heavy **R** enclosed in an **O** ring — the
/// ring reads as both the letter O and a record button, so the whole thing is
/// one confident "Enclosed" monogram. Authored on a 200×200 grid and drawn as a
/// vector so it stays crisp from the 1024px app icon down to an 18pt menu-bar
/// template.
///
/// The R is a real heavy typeface glyph (SF Pro Black), not a hand-built
/// geometric shape — its true terminals read as a serious wordmark rather than
/// a bubbly monogram. Baked to pixels at build time for the icon, and drawn
/// from the always-present system font at runtime for the menu bar / pill, so
/// there is no font dependency to ship.
///
/// This is the single source of truth: the menu-bar glyph, the recording-pill
/// mark, and the exported app icon all draw the same ring + glyph.
enum MenuBarIcon {

    /// The mark comes in two weights. `standard` (ring r66 / stroke 14) is the
    /// in-app + app-icon form; `menubar` (ring r78 / stroke 15) fills more of
    /// the frame so it survives at 18pt.
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

    /// Draws the R-in-O mark to fit `rect`, mapping the 200×200 authoring grid
    /// onto it. `color` paints the ring and the R at matched visual weight.
    static func draw(in rect: NSRect, color: NSColor, variant: Variant) {
        let s = min(rect.width, rect.height) / 200.0
        let center = NSPoint(x: rect.midX, y: rect.midY)

        // Per-variant geometry (grid units). `glyphPt` is the SF-Pro-Black point
        // size (in grid units) for the R; it's optically centered by ink bounds.
        let ringR: CGFloat, ringW: CGFloat, glyphPt: CGFloat
        switch variant {
        case .standard: ringR = 66; ringW = 14; glyphPt = 112
        case .menubar:  ringR = 78; ringW = 15; glyphPt = 122
        }

        color.set()

        // The O ring (also the record button).
        let rr = ringR * s
        let ring = NSBezierPath(ovalIn: NSRect(x: center.x - rr, y: center.y - rr,
                                               width: 2 * rr, height: 2 * rr))
        ring.lineWidth = ringW * s
        ring.stroke()

        // The R — a real heavy glyph, optically centered in the ring.
        drawR(center: center, pointSize: glyphPt * s, color: color)
    }

    /// Draws a capital "R" in SF Pro Black, centered on `center` by its ink
    /// bounds (not the em box) so it sits dead-center inside the ring. The glyph
    /// color is taken from the context fill (set explicitly here) so it renders
    /// reliably regardless of prior drawing state.
    private static func drawR(center: NSPoint, pointSize: CGFloat, color: NSColor) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let font = NSFont.systemFont(ofSize: pointSize, weight: .black)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true,
        ]
        let line = CTLineCreateWithAttributedString(
            NSAttributedString(string: "R", attributes: attrs))
        let ink = CTLineGetImageBounds(line, ctx)   // tight glyph bounds (y-up)

        ctx.saveGState()
        ctx.setFillColor((color.usingColorSpace(.sRGB) ?? color).cgColor)
        ctx.textPosition = CGPoint(x: center.x - ink.midX, y: center.y - ink.midY)
        CTLineDraw(line, ctx)
        ctx.restoreGState()
    }
}
