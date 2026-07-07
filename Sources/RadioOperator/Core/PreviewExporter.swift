import AppKit
import SwiftUI

/// Renders brand-surface previews to PNGs for design review WITHOUT launching
/// the app or touching the installed build:
///
///     RadioOperator --export-previews <out-dir>
///
/// Drops the menu-bar glyph (rest + capturing, on light and dark bars) and a
/// snapshot of the recording pill in each state. Menu-bar strips are pure
/// AppKit (always reliable); the pill snapshots use SwiftUI's ImageRenderer and
/// are best-effort.
@MainActor
enum PreviewExporter {
    static func handleIfRequested() -> Bool {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--export-previews"), i + 1 < args.count else { return false }
        ThemeFonts.register()
        let dir = args[i + 1]
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        menubarStrip(to: dir)
        pillStates(to: dir)
        return true
    }

    private static func write(_ rep: NSBitmapImageRep, _ name: String, _ dir: String) {
        guard let data = rep.representation(using: .png, properties: [:]) else { return }
        try? data.write(to: URL(fileURLWithPath: dir).appendingPathComponent(name))
        FileHandle.standardError.write("[preview] wrote \(name)\n".data(using: .utf8)!)
    }

    // MARK: Menu-bar glyph strip (pure AppKit)

    private static func menubarStrip(to dir: String) {
        let cell: CGFloat = 120       // swatch size (2x-ish, comfortable)
        let glyph: CGFloat = 40
        let cols = 2, rows = 2
        let w = CGFloat(cols) * cell, h = CGFloat(rows) * cell
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(w), pixelsHigh: Int(h),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ctx

        // Four swatches: rest/capturing × light-bar/dark-bar.
        let swatches: [(col: Int, row: Int, bar: NSColor, glyphColor: NSColor)] = [
            (0, 0, NSColor(white: 0.96, alpha: 1), .black),       // rest, light bar
            (1, 0, NSColor(white: 0.12, alpha: 1), .white),       // rest, dark bar
            (0, 1, NSColor(white: 0.96, alpha: 1), .systemRed),   // capturing, light bar
            (1, 1, NSColor(white: 0.12, alpha: 1), .systemRed),   // capturing, dark bar
        ]
        for sw in swatches {
            let x = CGFloat(sw.col) * cell
            let y = CGFloat(rows - 1 - sw.row) * cell     // top-down layout
            sw.bar.setFill()
            NSBezierPath(rect: NSRect(x: x, y: y, width: cell, height: cell)).fill()
            let gRect = NSRect(x: x + (cell - glyph) / 2, y: y + (cell - glyph) / 2,
                               width: glyph, height: glyph)
            // Render each glyph in its OWN NSImage — the real menu-bar path
            // (one draw per fresh context), so it matches what ships.
            let g = NSImage(size: NSSize(width: glyph, height: glyph), flipped: false) { r in
                MenuBarIcon.draw(in: r, color: sw.glyphColor, variant: .menubar)
                return true
            }
            g.draw(in: gRect)
        }
        NSGraphicsContext.restoreGraphicsState()
        write(rep, "menubar-glyph.png", dir)
    }

    // MARK: Pill snapshots (SwiftUI ImageRenderer, best-effort)

    private static func pillStates(to dir: String) {
        let state = AppState.shared
        let cases: [(name: String, apply: () -> Void)] = [
            ("pill-ready", { state.dictationPhase = .idle; state.commandPhase = .idle; state.commandNotice = nil }),
            ("pill-recording", { state.dictationPhase = .recording; state.micLevel = 0.7; state.commandNotice = nil }),
            ("pill-transcribing", { state.dictationPhase = .finalizing; state.commandNotice = nil }),
            ("pill-saved", { state.dictationPhase = .pasting; state.commandNotice = nil }),
            ("pill-error", { state.dictationPhase = .error("Couldn’t paste — copied to clipboard"); state.commandNotice = nil }),
        ]
        for c in cases {
            c.apply()
            // The pill floats bottom-center in a transparent panel; frame it over
            // a neutral desktop backdrop so the dark capsule is visible.
            let content = ZStack {
                Color(white: 0.82)
                PillView().environmentObject(state)
            }
            .frame(width: 520, height: 140)

            let renderer = ImageRenderer(content: content)
            renderer.scale = 2
            guard let img = renderer.nsImage,
                  let tiff = img.tiffRepresentation,
                  let rep = NSBitmapImageRep(data: tiff) else {
                FileHandle.standardError.write("[preview] pill render failed: \(c.name)\n".data(using: .utf8)!)
                continue
            }
            write(rep, "\(c.name).png", dir)
        }
        // Leave state clean.
        state.dictationPhase = .idle
        state.commandPhase = .idle
    }
}
