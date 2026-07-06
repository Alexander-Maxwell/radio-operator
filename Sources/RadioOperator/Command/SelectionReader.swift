import AppKit
import ApplicationServices
import Carbon.HIToolbox

/// Captures the frontmost app's current text selection for Command Mode.
///
/// Order of attack:
///  1. Accessibility — the focused element's kAXSelectedText. No clipboard
///     touch, instant, works in native apps.
///  2. Fallback (Electron/web views that don't expose the AX attribute) — a
///     synthetic Cmd-C against a concealed sentinel pasteboard, with a full
///     snapshot/restore of the user's clipboard around it (reuses
///     `PasteService.snapshot` and the concealed marker).
///
/// Empty selection is not an error: it resolves to `.insert` (D6a) and the
/// transform result lands at the cursor instead of replacing.
enum SelectionReader {
    enum Mode: Equatable, Sendable { case replace, insert }

    struct Selection: Equatable, Sendable {
        let text: String?
        let mode: Mode
    }

    /// Pure resolution so the path decision is unit-testable: an AX answer
    /// (even "nothing selected") wins outright; the copy capture only decides
    /// when AX had no attribute to read. Empty everywhere → insert.
    nonisolated static func resolve(axText: String?, copiedText: String?) -> Selection {
        if let axText {
            return axText.isEmpty
                ? Selection(text: nil, mode: .insert)
                : Selection(text: axText, mode: .replace)
        }
        if let copiedText, !copiedText.isEmpty {
            return Selection(text: copiedText, mode: .replace)
        }
        return Selection(text: nil, mode: .insert)
    }

    @MainActor
    static func read(target: PasteService.Target) async -> Selection {
        if let ax = axSelectedText(target: target) {
            return resolve(axText: ax, copiedText: nil)
        }
        return resolve(axText: nil, copiedText: await copyCapture())
    }

    // MARK: - AX path

    /// Reads kAXSelectedText from the target app's focused element. Returns
    /// nil when the attribute is unavailable (the app doesn't vend it) —
    /// distinct from "" which means "focused element, nothing selected".
    @MainActor
    private static func axSelectedText(target: PasteService.Target) -> String? {
        guard let app = target.app else { return nil }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)

        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXFocusedUIElementAttribute as CFString,
                                            &focusedRef) == .success,
              let focusedAny = focusedRef,
              CFGetTypeID(focusedAny) == AXUIElementGetTypeID() else { return nil }
        let element = unsafeDowncast(focusedAny as AnyObject, to: AXUIElement.self)

        var selRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString,
                                            &selRef) == .success,
              let text = selRef as? String else { return nil }
        return text
    }

    // MARK: - Cmd-C fallback

    /// Synthetic Cmd-C capture. The pasteboard is pre-loaded with a concealed
    /// sentinel so (a) clipboard managers skip the transient state and (b) an
    /// app that copies nothing — no selection — is distinguishable from one
    /// that re-copies text identical to what the clipboard already held. The
    /// user's clipboard is snapshotted before and restored after, always.
    @MainActor
    private static func copyCapture() async -> String? {
        // Secure input swallows synthetic keystrokes — don't churn the clipboard.
        if IsSecureEventInputEnabled() { return nil }

        let pb = NSPasteboard.general
        let saved = PasteService.snapshot(pb)
        let sentinel = "radio-operator-selection-probe-\(UUID().uuidString)"
        pb.clearContents()
        pb.setString(sentinel, forType: .string)
        pb.setString("1", forType: PasteService.concealedType)
        let sentinelCount = pb.changeCount

        var captured: String?
        if postCmdC() {
            // Wait up to ~300ms for the app to service the copy.
            for _ in 0..<12 {
                try? await Task.sleep(nanoseconds: 25_000_000)
                if pb.changeCount != sentinelCount {
                    if let s = pb.string(forType: .string), s != sentinel {
                        captured = s
                    }
                    break
                }
            }
        }

        // Restore the user's clipboard whatever happened above.
        pb.clearContents()
        if !saved.isEmpty { pb.writeObjects(saved) }
        return captured
    }

    @MainActor
    private static func postCmdC() -> Bool {
        guard let source = CGEventSource(stateID: .combinedSessionState) else { return false }
        source.setLocalEventsFilterDuringSuppressionState(
            [.permitLocalKeyboardEvents, .permitLocalMouseEvents, .permitSystemDefinedEvents],
            state: .eventSuppressionStateSuppressionInterval)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0x08, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: 0x08, keyDown: false) else {
            return false
        }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cgSessionEventTap)
        usleep(8000)
        up.post(tap: .cgSessionEventTap)
        return true
    }
}
