import AppKit
import SwiftUI

/// Creates and reuses NSWindows hosting SwiftUI content. Pure AppKit window
/// management so the accessory-app lifecycle stays predictable without Xcode
/// scene plumbing.
@MainActor
final class WindowRouter: NSObject, NSWindowDelegate {
    static let shared = WindowRouter()

    private var windows: [String: NSWindow] = [:]

    func show<Content: View>(id: String, title: String, size: NSSize,
                             resizable: Bool = true,
                             brandChrome: Bool = false,
                             @ViewBuilder content: () -> Content) {
        if let existing = windows[id] {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        var style: NSWindow.StyleMask = [.titled, .closable, .miniaturizable]
        if resizable { style.insert(.resizable) }
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: style,
            backing: .buffered,
            defer: false
        )
        window.title = title
        if brandChrome {
            // Brand surfaces are light-committed (Violet "Enclosed" identity):
            // the title bar blends into the light app background regardless of
            // the system appearance.
            window.titlebarAppearsTransparent = true
            window.appearance = NSAppearance(named: .aqua)
            window.backgroundColor = NSColor(srgbRed: 0xF5 / 255, green: 0xF3 / 255,
                                             blue: 0xFB / 255, alpha: 1)
        }
        window.isReleasedWhenClosed = false
        window.center()
        window.contentViewController = NSHostingController(rootView: content())
        window.delegate = self
        window.identifier = NSUserInterfaceItemIdentifier(id)
        windows[id] = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func close(id: String) {
        windows[id]?.close()
    }

    func isOpen(id: String) -> Bool {
        windows[id]?.isVisible ?? false
    }

    nonisolated func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              let id = window.identifier?.rawValue else { return }
        Task { @MainActor in
            self.windows.removeValue(forKey: id)
        }
    }
}
