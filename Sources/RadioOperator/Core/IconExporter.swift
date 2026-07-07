import AppKit

/// Renders the macOS app icon (violet tile + cream R-in-O mark) to a `.iconset`
/// folder, using the SAME vector path as the menu-bar glyph and pill mark so all
/// three surfaces can never drift. Invoked headlessly:
///
///     RadioOperator --export-iconset <out-dir>
///
/// `scripts/make-icon.sh` runs this, then `iconutil` folds the PNGs into
/// `resources/RadioOperator.icns`. No SVG rasterizer or Xcode asset catalog
/// needed. Tokens are the `--ro-primary` / `--ro-on-primary` values and the
/// 22.37% squircle radius from `design_handoff_ro_identity/README.md`.
enum IconExporter {

    /// The violet tile (--ro-primary #6C5CE7).
    static let tile = NSColor(srgbRed: 0x6C / 255, green: 0x5C / 255, blue: 0xE7 / 255, alpha: 1)
    /// The cream mark on the tile (--ro-on-primary #F3F1FF).
    static let markColor = NSColor(srgbRed: 0xF3 / 255, green: 0xF1 / 255, blue: 0xFF / 255, alpha: 1)

    /// Early-exit dispatch, mirroring TestRunner/ProbeRunner. Returns true when
    /// it consumed the launch (so `main()` should return without opening a GUI).
    static func handleIfRequested() -> Bool {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--export-iconset"), i + 1 < args.count else { return false }
        export(to: args[i + 1])
        return true
    }

    /// The 10 `.iconset` slots macOS expects (1x + 2x for 16…512).
    private static let slots: [(name: String, px: Int)] = [
        ("icon_16x16", 16), ("icon_16x16@2x", 32),
        ("icon_32x32", 32), ("icon_32x32@2x", 64),
        ("icon_128x128", 128), ("icon_128x128@2x", 256),
        ("icon_256x256", 256), ("icon_256x256@2x", 512),
        ("icon_512x512", 512), ("icon_512x512@2x", 1024),
    ]

    static func export(to dir: String) {
        let fm = FileManager.default
        try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        for (name, px) in slots {
            guard let data = png(size: px) else {
                warn("failed to render \(name)")
                continue
            }
            let url = URL(fileURLWithPath: dir).appendingPathComponent("\(name).png")
            do { try data.write(to: url); warn("wrote \(name).png (\(px)px)") }
            catch { warn("write failed \(name): \(error)") }
        }
    }

    /// A single square PNG: violet squircle tile + cream mark.
    static func png(size px: Int) -> Data? {
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { return nil }
        rep.size = NSSize(width: px, height: px)
        guard let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return nil }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ctx
        let n = CGFloat(px)
        let rect = NSRect(x: 0, y: 0, width: n, height: n)

        // Violet squircle tile (transparent corners so the Dock shows the shape).
        let radius = 0.2237 * n
        let tilePath = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
        tile.setFill()
        tilePath.fill()

        // The Morse "R over O" mark, cream on the tile.
        MenuBarIcon.draw(in: rect, color: markColor, variant: .standard)

        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }

    private static func warn(_ msg: String) {
        FileHandle.standardError.write(("[icon] " + msg + "\n").data(using: .utf8)!)
    }
}
