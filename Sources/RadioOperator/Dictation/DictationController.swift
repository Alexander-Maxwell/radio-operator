import Foundation
import AppKit
import AVFoundation

/// The core dictation loop: hotkey-down → mic + transcriber start instantly
/// (audio buffered from T0, no first-word clipping) → live pill → hotkey-up →
/// finalize (bounded) → deterministic cleanup → paste → history.
///
/// Handles the reviewed edge transitions: stop-while-starting, cancel from
/// Escape/chord, release-before-120ms discard, empty-utterance discard,
/// double-press safety, and dictation during meetings (mic broadcaster).
@MainActor
final class DictationController {
    static let shared = DictationController()

    private enum State: Equatable {
        case idle
        case starting        // hotkey down, session spinning up
        case recording
        case stopping        // waiting for finals
        case cancelling
    }

    private var state: State = .idle
    private var transcriber: Transcriber?
    private var micToken: UUID?
    private var target: PasteService.Target?
    private let paste = PasteService()
    private var startTask: Task<Void, Never>?
    private var pressedAt: Date?
    private var finals: [String] = []
    private var stopRequested = false
    private var errorDismissTask: Task<Void, Never>?

    let hotkeys = HotkeyManager()

    private init() {
        hotkeys.onHoldDown = { [weak self] in self?.hotkeyDown() }
        hotkeys.onHoldUp = { [weak self] in self?.hotkeyUp() }
        hotkeys.onCancel = { [weak self] in self?.cancel() }
    }

    func startListening() {
        hotkeys.start()
    }

    // MARK: - Hotkey entry points

    func hotkeyDown() {
        guard state == .idle else { return }
        begin()
    }

    func hotkeyUp() {
        switch state {
        case .starting, .recording:
            // Release faster than 120ms = accidental tap, discard quietly.
            if let pressedAt, Date().timeIntervalSince(pressedAt) < 0.12 {
                cancel(quiet: true)
            } else {
                endAndPaste()
            }
        default:
            break
        }
    }

    /// Menu-initiated toggle (also the pill's click-to-stop path).
    func toggle() {
        switch state {
        case .idle: begin()
        case .starting, .recording: endAndPaste()
        default: break
        }
    }

    // MARK: - Session lifecycle

    private func begin() {
        // Capture the paste target BEFORE any of our UI can appear.
        target = paste.captureTarget()
        pressedAt = Date()
        finals = []
        stopRequested = false
        state = .starting
        errorDismissTask?.cancel()

        AppState.shared.dictationPhase = .recording
        AppState.shared.pillVolatile = ""
        AppState.shared.pillFinal = ""
        PillController.shared.show()
        hotkeys.setRecordingTapEnabled(true)

        let transcriber = Transcriber(channel: .me)
        self.transcriber = transcriber

        transcriber.onEvent = { event in
            Task { @MainActor in
                guard DictationController.shared.transcriber === transcriber else { return }
                if event.isFinal {
                    DictationController.shared.finals.append(event.text)
                    AppState.shared.pillFinal = DictationController.shared.finals.joined(separator: " ")
                    AppState.shared.pillVolatile = ""
                } else {
                    AppState.shared.pillVolatile = event.text
                }
            }
        }
        transcriber.onError = { message in
            Task { @MainActor in
                guard DictationController.shared.transcriber === transcriber else { return }
                DictationController.shared.failSession(message)
            }
        }

        startTask = Task { [weak self] in
            guard let self else { return }
            do {
                guard let format = await Transcriber.preferredFormat() else {
                    throw NSError(domain: "Radio Operator", code: 2, userInfo: [
                        NSLocalizedDescriptionKey: "Speech model unavailable for English."])
                }
                // Mic first so buffers queue into the transcriber's input
                // stream while the analyzer spins up.
                let token = try MicCapture.shared.subscribe(format: format, onBuffer: { buffer in
                    transcriber.feed(buffer)
                }, onLevel: { level in
                    Task { @MainActor in AppState.shared.micLevel = level }
                })
                await MainActor.run {
                    self.micToken = token
                    if self.state == .starting { self.state = .recording }
                }
                try await transcriber.start()
                // If the user released during startup, run the stop path now.
                await MainActor.run {
                    if self.stopRequested {
                        self.finishSession()
                    }
                }
            } catch {
                await MainActor.run {
                    self.failSession(error.localizedDescription)
                }
            }
        }
    }

    private func endAndPaste() {
        guard state == .starting || state == .recording else { return }
        if state == .starting {
            // Transcriber still spinning up; flag and let startTask finish it.
            stopRequested = true
            state = .stopping
            AppState.shared.dictationPhase = .finalizing
            return
        }
        finishSession()
    }

    private func finishSession() {
        guard state == .recording || state == .stopping else { return }
        state = .stopping
        AppState.shared.dictationPhase = .finalizing
        hotkeys.setRecordingTapEnabled(false)

        if let micToken {
            MicCapture.shared.unsubscribe(micToken)
            self.micToken = nil
        }
        let transcriber = self.transcriber
        let pressedAt = self.pressedAt

        Task { [weak self] in
            guard let self else { return }
            let completed = await transcriber?.finishAndWait(timeout: 3.0) ?? false
            await MainActor.run {
                guard self.state == .stopping else { return }
                let raw = self.finals.joined(separator: " ")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let durationMs = pressedAt.map { Int(Date().timeIntervalSince($0) * 1000) } ?? 0

                if raw.isEmpty {
                    // Nothing heard — dismiss quietly (finalize timeout with
                    // no finals surfaces as an error instead).
                    if !completed {
                        self.failSession("Transcription timed out — nothing captured")
                    } else {
                        self.resetToIdle()
                    }
                    return
                }

                let cleaned = CleanupEngine.clean(raw, settings: SettingsStore.shared.data)
                guard !cleaned.isEmpty else {
                    self.resetToIdle()
                    return
                }

                self.state = .idle
                AppState.shared.dictationPhase = .pasting
                let target = self.target ?? self.paste.captureTarget()
                let text = SettingsStore.shared.data.smartLeadingSpace ? cleaned : cleaned
                Task { @MainActor in
                    let outcome = await self.paste.paste(text, target: target)
                    let pasteOK = outcome == .pasted
                    HistoryStore.shared.record(
                        raw: raw, cleaned: cleaned,
                        appBundleID: target.bundleID,
                        durationMs: durationMs, pasteOK: pasteOK)
                    switch outcome {
                    case .pasted:
                        AppState.shared.dictationPhase = .idle
                        PillController.shared.dismiss()
                    case .clipboardOnly(let reason):
                        // Pill is the primary failure channel (reviewer P0):
                        // persist 4s with the reason, text stays on clipboard.
                        AppState.shared.dictationPhase = .error(reason)
                        self.scheduleErrorDismiss()
                    }
                }
            }
        }
    }

    func cancel(quiet: Bool = false) {
        guard state == .starting || state == .recording || state == .stopping else { return }
        state = .cancelling
        hotkeys.setRecordingTapEnabled(false)
        startTask?.cancel()
        if let micToken {
            MicCapture.shared.unsubscribe(micToken)
            self.micToken = nil
        }
        transcriber?.cancel()
        transcriber = nil
        resetToIdle()
        _ = quiet // both paths dismiss silently; parameter kept for clarity at call sites
    }

    private func failSession(_ message: String) {
        hotkeys.setRecordingTapEnabled(false)
        if let micToken {
            MicCapture.shared.unsubscribe(micToken)
            self.micToken = nil
        }
        transcriber?.cancel()
        transcriber = nil
        state = .idle
        AppState.shared.dictationPhase = .error(message)
        scheduleErrorDismiss()
    }

    private func scheduleErrorDismiss() {
        errorDismissTask?.cancel()
        errorDismissTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard !Task.isCancelled else { return }
            if case .error = AppState.shared.dictationPhase {
                AppState.shared.dictationPhase = .idle
                PillController.shared.dismiss()
            }
        }
    }

    private func resetToIdle() {
        state = .idle
        transcriber = nil
        AppState.shared.dictationPhase = .idle
        AppState.shared.pillVolatile = ""
        AppState.shared.pillFinal = ""
        AppState.shared.micLevel = 0
        PillController.shared.dismiss()
    }
}
