import AppKit
import CoreGraphics

/// Global push-to-talk hotkey (hold a configurable modifier) plus a
/// recording-scoped CGEventTap that (a) consumes Escape to cancel and
/// (b) aborts the session when any non-modifier key is pressed while the
/// hold modifier is down (it was a keyboard shortcut, not dictation).
@MainActor
final class HotkeyManager {
    var onHoldDown: (() -> Void)?
    var onHoldUp: (() -> Void)?
    /// Cancel current session, discard audio (Escape or chord detected).
    var onCancel: (() -> Void)?

    private var globalFlagsMonitor: Any?
    private var localFlagsMonitor: Any?
    private var holdActive = false
    private var eventTap: CFMachPort?
    private var tapRunLoopSource: CFRunLoopSource?

    private var hotkey: HoldHotkey { SettingsStore.shared.data.holdHotkey }

    func start() {
        installFlagsMonitors()
    }

    func restart() {
        removeFlagsMonitors()
        installFlagsMonitors()
    }

    /// True when flagsChanged events are observable (permission smoke test).
    private(set) var sawAnyFlagsEvent = false

    private func installFlagsMonitors() {
        let handler: (NSEvent) -> Void = { [weak self] event in
            self?.handleFlags(event)
        }
        globalFlagsMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged, handler: handler)
        localFlagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
            handler(event)
            return event
        }
    }

    private func removeFlagsMonitors() {
        if let globalFlagsMonitor { NSEvent.removeMonitor(globalFlagsMonitor) }
        if let localFlagsMonitor { NSEvent.removeMonitor(localFlagsMonitor) }
        globalFlagsMonitor = nil
        localFlagsMonitor = nil
    }

    private func handleFlags(_ event: NSEvent) {
        sawAnyFlagsEvent = true
        let keyCode = event.keyCode
        let flags = event.modifierFlags

        let isDown: Bool
        switch hotkey {
        case .rightCommand:
            guard keyCode == 54 else { return }
            isDown = flags.contains(.command)
        case .rightOption:
            guard keyCode == 61 else { return }
            isDown = flags.contains(.option)
        case .fn:
            guard keyCode == 63 else { return }
            isDown = flags.contains(.function)
        case .off:
            return
        }

        if isDown && !holdActive {
            holdActive = true
            onHoldDown?()
        } else if !isDown && holdActive {
            holdActive = false
            onHoldUp?()
        }
    }

    // MARK: - Recording-scoped event tap (Escape consume + chord abort)

    /// Enable while recording. Consumes Escape (cancel without leaking the key
    /// to the frontmost app); any other keyDown aborts the hold session but is
    /// passed through (the user was typing a shortcut).
    func setRecordingTapEnabled(_ enabled: Bool) {
        if enabled {
            guard eventTap == nil else { return }
            installEventTap()
        } else {
            removeEventTap()
        }
    }

    private func installEventTap() {
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let manager = Unmanaged<HotkeyManager>.fromOpaque(refcon).takeUnretainedValue()
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                Task { @MainActor in manager.reenableTap() }
                return Unmanaged.passUnretained(event)
            }
            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
            if keyCode == 53 { // Escape
                Task { @MainActor in manager.onCancel?() }
                return nil // consume
            }
            // Any other key while holding: chord, not dictation — abort quietly.
            Task { @MainActor in
                if manager.holdActive {
                    manager.holdActive = false
                    manager.onCancel?()
                }
            }
            return Unmanaged.passUnretained(event)
        }

        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: refcon
        ) else {
            // Tap creation failed (permission edge) — fall back to a passive
            // Escape monitor: cancel still works, but Escape leaks to the app.
            installFallbackEscapeMonitor()
            return
        }
        eventTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        tapRunLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private func reenableTap() {
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: true)
        }
    }

    private func removeEventTap() {
        if let tapRunLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), tapRunLoopSource, .commonModes)
        }
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
        }
        tapRunLoopSource = nil
        eventTap = nil
        if let fallbackEscMonitor {
            NSEvent.removeMonitor(fallbackEscMonitor)
            self.fallbackEscMonitor = nil
        }
    }

    private var fallbackEscMonitor: Any?

    private func installFallbackEscapeMonitor() {
        fallbackEscMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return }
            Task { @MainActor in
                if event.keyCode == 53 {
                    self.onCancel?()
                } else if self.holdActive {
                    self.holdActive = false
                    self.onCancel?()
                }
            }
        }
    }
}
