import AppKit
import Carbon.HIToolbox

/// Inserts text at the cursor of the app that was frontmost when dictation
/// started: clipboard swap → synthetic Cmd+V → guarded restore.
///
/// Honesty rules (review-mandated): paste is only attempted when preconditions
/// pass (no secure input, target alive, target frontmost after activation);
/// otherwise the text STAYS on the clipboard and the outcome says so. The
/// clipboard is restored only after a successful post, only if nobody else
/// wrote to it meanwhile.
@MainActor
final class PasteService {
    struct Target {
        let app: NSRunningApplication?
        var bundleID: String? { app?.bundleIdentifier }
    }

    enum Outcome: Equatable {
        /// Cmd+V posted with all preconditions verified.
        case pasted
        /// Text left on clipboard; reason is user-facing.
        case clipboardOnly(reason: String)
    }

    private var pasteChain: Task<Outcome, Never>?

    func captureTarget() -> Target {
        Target(app: NSWorkspace.shared.frontmostApplication)
    }

    /// Serialized: concurrent calls run in order, never interleaving
    /// save→post→restore triples.
    func paste(_ text: String, target: Target) async -> Outcome {
        let previous = pasteChain
        let task = Task<Outcome, Never> { [weak self] in
            _ = await previous?.value
            guard let self else { return .clipboardOnly(reason: "Internal error") }
            return await self.performPaste(text, target: target)
        }
        pasteChain = task
        return await task.value
    }

    /// Clipboard managers honor this marker and skip the item — dictations
    /// shouldn't accumulate in third-party clipboard history. Also used by
    /// SelectionReader's transient copy-capture sentinel.
    nonisolated static let concealedType = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")

    /// Stages dictated text on a pasteboard: the string plus the concealed
    /// marker, in one write. Returns the resulting changeCount so the guarded
    /// restore can detect later writers. Static + nonisolated so the
    /// concealed-marker invariant is regression-testable on a scratch
    /// pasteboard (a missing marker silently leaks every dictation into
    /// third-party clipboard managers).
    nonisolated static func stage(_ text: String, on pb: NSPasteboard) -> Int {
        pb.clearContents()
        pb.setString(text, forType: .string)
        pb.setString("1", forType: PasteService.concealedType)
        return pb.changeCount
    }

    /// The paste/don't-paste call, decided purely from the observed
    /// preconditions so every branch is unit-testable. A wrong decision here
    /// silently loses dictated text (pastes into a password field, or claims
    /// success while the keystroke went nowhere) — highest-consequence logic
    /// in the paste path. Priority order matters: secure input beats a dead
    /// target beats a failed refocus.
    enum PasteDecision: Equatable {
        case paste
        case clipboardOnly(reason: String)
    }

    nonisolated static func pasteDecision(secureInput: Bool, targetTerminated: Bool,
                                          refocusNeeded: Bool, refocusSettled: Bool) -> PasteDecision {
        // Secure input (password fields, Terminal Secure Keyboard Entry)
        // silently swallows synthetic Cmd+V.
        if secureInput {
            return .clipboardOnly(reason: "Secure input active — press ⌘V to paste")
        }
        if targetTerminated {
            return .clipboardOnly(reason: "The app you were in closed — press ⌘V where you want the text")
        }
        if refocusNeeded && !refocusSettled {
            return .clipboardOnly(reason: "Couldn't refocus the app — press ⌘V where you want the text")
        }
        return .paste
    }

    private func performPaste(_ text: String, target: Target) async -> Outcome {
        let pb = NSPasteboard.general
        let saved = PasteService.snapshot(pb)
        let ourChangeCount = PasteService.stage(text, on: pb)

        let secureInput = IsSecureEventInputEnabled()
        let targetTerminated = target.app?.isTerminated ?? false

        // Activate the target only if it lost frontmost status (activating a
        // frontmost Chromium app can drop field focus). Skipped when a
        // precondition already failed — same as the old early returns.
        var refocusNeeded = false
        var refocusSettled = true
        if !secureInput, !targetTerminated, let app = target.app,
           NSWorkspace.shared.frontmostApplication?.processIdentifier != app.processIdentifier {
            refocusNeeded = true
            refocusSettled = false
            app.activate()
            for _ in 0..<8 {
                try? await Task.sleep(nanoseconds: 25_000_000)
                if NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier {
                    refocusSettled = true
                    break
                }
            }
            if refocusSettled {
                try? await Task.sleep(nanoseconds: 120_000_000)
            }
        }

        switch PasteService.pasteDecision(secureInput: secureInput,
                                          targetTerminated: targetTerminated,
                                          refocusNeeded: refocusNeeded,
                                          refocusSettled: refocusSettled) {
        case .clipboardOnly(let reason):
            return .clipboardOnly(reason: reason)
        case .paste:
            break
        }

        // Wait for physical modifiers (the just-released hotkey) to clear so
        // they can't contaminate the synthetic event.
        for _ in 0..<10 {
            let flags = CGEventSource.flagsState(.combinedSessionState)
            if flags.intersection([.maskCommand, .maskAlternate, .maskShift, .maskControl]).isEmpty {
                break
            }
            try? await Task.sleep(nanoseconds: 25_000_000)
        }

        guard postCmdV() else {
            return .clipboardOnly(reason: "Paste keystroke failed — press ⌘V (check Accessibility permission)")
        }

        // Guarded restore: give the target time to read the clipboard, then
        // restore only if nothing else has written since our set.
        let savedItems = saved
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_700_000_000)
            if pb.changeCount == ourChangeCount, !savedItems.isEmpty {
                pb.clearContents()
                pb.writeObjects(savedItems)
            }
        }
        return .pasted
    }

    private func postCmdV() -> Bool {
        guard let source = CGEventSource(stateID: .combinedSessionState) else { return false }
        source.setLocalEventsFilterDuringSuppressionState(
            [.permitLocalKeyboardEvents, .permitLocalMouseEvents, .permitSystemDefinedEvents],
            state: .eventSuppressionStateSuppressionInterval)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false) else {
            return false
        }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cgSessionEventTap)
        usleep(8000)
        up.post(tap: .cgSessionEventTap)
        return true
    }

    /// Snapshot every item/type currently on the pasteboard so images, RTF,
    /// and files survive the swap. Static + nonisolated so the clipboard
    /// save/restore round-trip is unit-testable against a scratch pasteboard.
    nonisolated static func snapshot(_ pb: NSPasteboard) -> [NSPasteboardItem] {
        (pb.pasteboardItems ?? []).map { item in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) {
                    copy.setData(data, forType: type)
                }
            }
            return copy
        }
    }
}
