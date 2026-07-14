import SwiftUI
import AppKit

/// Tokens for the recording pill — a near-black tactical capsule carrying a
/// brass Morse-code meter that rides the mic level. Burnished-brass mark/meter
/// on rich black, light labels. Tactical Night Operations palette.
enum Palette {
    /// Pill background — near Rich Black.
    static let pillBG = Color(red: 0x0E / 255, green: 0x11 / 255, blue: 0x14 / 255)
    /// Pill border while recording (brass at 0.40).
    static let pillBorder = Color(red: 191 / 255, green: 160 / 255, blue: 106 / 255).opacity(0.40)
    /// Pill border at rest (subtle white hairline).
    static let pillBorderIdle = Color.white.opacity(0.08)
    /// Pill labels — Ready / Transcribing / Saved.
    static let pillText = Color.white.opacity(0.88)
    /// Pill timer, mono.
    static let pillMeta = Color.white.opacity(0.55)

    /// The Morse meter + mark on the pill — Burnished Brass, brightened for
    /// contrast on the near-black field.
    static let mark = Color(red: 0xD6 / 255, green: 0xC0 / 255, blue: 0x8E / 255)
    static let markNS = NSColor(srgbRed: 0xD6 / 255, green: 0xC0 / 255, blue: 0x8E / 255, alpha: 1)

    /// Live microphone / errors on the pill — Operational Red.
    static let alert = Color(red: 0xC6 / 255, green: 0x45 / 255, blue: 0x45 / 255)
}
