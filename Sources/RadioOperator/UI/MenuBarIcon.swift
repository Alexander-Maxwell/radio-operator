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
        let size = NSSize(width: 18, height: 18)
        guard let art = antenna else { return NSImage(size: size) }
        let out = NSImage(size: size, flipped: false) { rect in
            let s = art.size
            let scale = min(rect.width / s.width, rect.height / s.height)
            let w = s.width * scale, h = s.height * scale
            let r = NSRect(x: (rect.width - w) / 2, y: (rect.height - h) / 2, width: w, height: h)
            (capturing ? NSColor.systemRed : NSColor.black).setFill()
            NSBezierPath(rect: rect).fill()
            art.draw(in: r, from: .zero, operation: .destinationIn, fraction: 1)
            return true
        }
        out.isTemplate = !capturing   // system tints it for the bar
        return out
    }

    /// The SATCOM antenna art (black on transparent), from the app bundle or the
    /// repo checkout for debug builds.
    private static let antenna: NSImage? = {
        if let url = Bundle.main.url(forResource: "operator-silhouette", withExtension: "png"),
           let img = NSImage(contentsOf: url) { return img }
        let exe = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        let repo = exe.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return NSImage(contentsOf: repo.appendingPathComponent("resources/operator-silhouette.png"))
    }()

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
