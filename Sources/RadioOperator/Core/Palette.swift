import SwiftUI
import AppKit

/// Tokens for the recording pill — the one surface that stays dark in the
/// otherwise-light Violet "Enclosed" identity. Near-black capsule, violet mark
/// and meter (brightened for contrast on the dark field), white-alpha labels.
/// Values are the `--ro-pill-*` / `--ro-primary-bright` tokens from
/// `design_handoff_ro_identity/README.md`.
enum Palette {
    /// Pill background: near-black, warm-neutral (--ro-pill-bg #17181B).
    static let pillBG = Color(red: 0x17 / 255, green: 0x18 / 255, blue: 0x1B / 255)
    /// Pill border while recording (--ro-pill-border, violet at 0.40).
    static let pillBorder = Color(red: 143 / 255, green: 127 / 255, blue: 255 / 255).opacity(0.40)
    /// Pill border at rest (subtle white hairline).
    static let pillBorderIdle = Color.white.opacity(0.08)
    /// Pill labels — Ready / Transcribing / Saved (--ro-pill-text).
    static let pillText = Color.white.opacity(0.82)
    /// Pill timer, mono (--ro-pill-meta).
    static let pillMeta = Color.white.opacity(0.55)

    /// Mark + live meter on the pill: violet, brighter for contrast on the
    /// near-black field (--ro-primary-bright #8F7FFF).
    static let mark = Color(red: 143 / 255, green: 127 / 255, blue: 255 / 255)
    /// Same violet as an NSColor, for the vector `MenuBarIcon.emblem`.
    static let markNS = NSColor(srgbRed: 143 / 255, green: 127 / 255, blue: 255 / 255, alpha: 1)
    /// Idle meter bars (faint, flat).
    static let meterIdle = Color.white.opacity(0.22)

    /// Live microphone / errors on the pill — the load-bearing "red = live".
    static let alert = Color(red: 0xF0 / 255, green: 0x67 / 255, blue: 0x4F / 255)
}
