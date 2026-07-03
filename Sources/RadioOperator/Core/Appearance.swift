import AppKit

/// Applies the user's appearance preference to the whole app. `system` clears
/// the override so windows follow macOS; light/dark force one look.
@MainActor
enum Appearance {
    static func apply(_ mode: AppearanceMode) {
        switch mode {
        case .system: NSApp.appearance = nil
        case .light:  NSApp.appearance = NSAppearance(named: .aqua)
        case .dark:   NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }
}
