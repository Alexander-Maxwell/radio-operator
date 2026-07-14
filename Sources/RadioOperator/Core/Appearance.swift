import AppKit

/// Commits the whole app to the light Violet "Enclosed" identity. The redesign
/// is light-only (no dark variant is specified), so every mode resolves to
/// light — system menus and controls stay consistent with the light windows.
/// `mode` is ignored but kept in the signature for the persisted setting.
@MainActor
enum Appearance {
    static func apply(_ mode: AppearanceMode) {
        NSApp.appearance = NSAppearance(named: .darkAqua)
    }
}
