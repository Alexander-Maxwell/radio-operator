import AppKit
import ApplicationServices

/// Implements the "Smart leading space" setting: when the insertion point in
/// the target app sits directly after a non-whitespace character, the pasted
/// dictation gets a single leading space so it doesn't fuse with prior text.
enum SmartSpace {

    /// Pure merge rule: prepend one space unless the text already leads with
    /// whitespace or with punctuation that binds to the previous word.
    nonisolated static func merged(_ text: String, needsSpace: Bool) -> String {
        guard needsSpace, let first = text.first else { return text }
        if first.isWhitespace || first.isNewline { return text }
        if ",.!?;:)]}".contains(first) { return text }
        return " " + text
    }

    /// AX read of the target app's focused element: true when the character
    /// before the insertion point exists and is not whitespace. Conservative —
    /// any failure to read means false (no space added).
    @MainActor
    static func needsLeadingSpace(target: PasteService.Target) -> Bool {
        guard let app = target.app else { return false }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)

        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXFocusedUIElementAttribute as CFString,
                                            &focusedRef) == .success,
              let focusedAny = focusedRef,
              CFGetTypeID(focusedAny) == AXUIElementGetTypeID() else { return false }
        let element = unsafeDowncast(focusedAny as AnyObject, to: AXUIElement.self)

        var rangeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString,
                                            &rangeRef) == .success,
              let rangeAny = rangeRef,
              CFGetTypeID(rangeAny) == AXValueGetTypeID() else { return false }
        let rangeValue = unsafeDowncast(rangeAny as AnyObject, to: AXValue.self)
        var caret = CFRange()
        guard AXValueGetValue(rangeValue, .cfRange, &caret), caret.location > 0 else { return false }

        // Preferred: ask for exactly the character before the caret.
        var probe = CFRange(location: caret.location - 1, length: 1)
        if let probeValue = AXValueCreate(.cfRange, &probe) {
            var charRef: CFTypeRef?
            if AXUIElementCopyParameterizedAttributeValue(
                element, kAXStringForRangeParameterizedAttribute as CFString,
                probeValue, &charRef) == .success,
               let prev = charRef as? String, let ch = prev.unicodeScalars.last {
                return !CharacterSet.whitespacesAndNewlines.contains(ch)
            }
        }

        // Fallback: read the whole value and index it (bounded to sane sizes).
        var valueRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString,
                                            &valueRef) == .success,
              let s = valueRef as? String, !s.isEmpty else { return false }
        let utf16 = Array(s.utf16)
        let index = caret.location - 1
        guard index >= 0, index < utf16.count,
              let scalar = Unicode.Scalar(utf16[index]) else { return false }
        return !CharacterSet.whitespacesAndNewlines.contains(scalar)
    }
}
