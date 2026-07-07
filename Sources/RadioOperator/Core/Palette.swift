import SwiftUI
import AppKit

/// Tokens for the recording pill — a translucent "liquid glass" capsule (frosted
/// vibrancy over the desktop) carrying a flowing, multi-hued waveform. Violet
/// stays the lead brand hue; teal + a warm gold sparkle give it depth. Text and
/// the mark are dark/violet so they read on the light frosted glass.
enum Palette {
    /// A faint white wash over the vibrancy so the pill keeps a light body over
    /// dark desktops (keeps dark text legible on any backdrop).
    static let glassTint = Color.white.opacity(0.30)
    /// Glass rim: bright top highlight → faint bottom shade, sells the bevel.
    static let glassRimTop = Color.white.opacity(0.70)
    static let glassRimBottom = Color.black.opacity(0.06)

    /// Labels on glass — Ready / Transcribing / Saved (dark ink).
    static let pillText = Color(red: 0.14, green: 0.11, blue: 0.24).opacity(0.82)
    /// Timer, mono (muted violet-ink).
    static let pillMeta = Color(red: 0.34, green: 0.30, blue: 0.50).opacity(0.90)

    /// The R mark on glass — violet primary (#6C5CE7).
    static let mark = Color(red: 0x6C / 255, green: 0x5C / 255, blue: 0xE7 / 255)
    /// Same violet as an NSColor for the vector `MenuBarIcon.emblem`.
    static let markNS = NSColor(srgbRed: 0x6C / 255, green: 0x5C / 255, blue: 0xE7 / 255, alpha: 1)

    /// Live microphone / errors — the load-bearing "red = live".
    static let alert = Color(red: 0xCF / 255, green: 0x3A / 255, blue: 0x28 / 255)

    /// Idle flow line tint (Ready resting state).
    static let idleFlow = Color(red: 0.55, green: 0.50, blue: 0.64).opacity(0.55)
}
