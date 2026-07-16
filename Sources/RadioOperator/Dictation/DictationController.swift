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
    private var transcriber: (any TranscriptionEngine)?
    private var micToken: UUID?
    private var target: PasteService.Target?
    private let paste = PasteService()
    private var startTask: Task<Void, Never>?
    private var pressedAt: Date?
    private var finals: [String] = []
    private var stopRequested = false
    private var errorDismissTask: Task<Void, Never>?
    /// Hands-free mode: entered by double-tapping the hold hotkey; the session
    /// keeps recording after release and the next press finishes it.
    private var locked = false
    private var lastHotkeyDownAt: Date?

    let hotkeys = HotkeyManager()

    private init() {
        hotkeys.onHoldDown = { [weak self] in self?.hotkeyDown() }
        hotkeys.onHoldUp = { [weak self] in self?.hotkeyUp() }
        hotkeys.onCancel = { [weak self] in self?.cancel() }
    }

    func startListening() {
        hotkeys.start()
    }

    /// True anywhere between hotkey-down and paste/cancel. Read by Command
    /// Mode's begin gate (a parallel controller — this property is the only
    /// thing it touches here, and dictation never reads Command Mode state).
    var isActive: Bool { state != .idle }

    /// Two hotkey presses inside this window mean "lock hands-free".
    nonisolated static func isDoubleTap(previousDown: Date?, now: Date) -> Bool {
        guard let previousDown else { return false }
        let dt = now.timeIntervalSince(previousDown)
        return dt > 0 && dt < 0.4
    }

    /// What a hotkey-down press should do, decided purely from the current
    /// state so the double-tap/lock transitions are unit-testable without
    /// touching the mic/transcriber singletons.
    enum HotkeyDownAction: Equatable { case ignore, beginNormal, beginLocked, finishLocked }

    nonisolated static func hotkeyDownAction(idle: Bool, activeOrStarting: Bool,
                                             locked: Bool, doubleTap: Bool) -> HotkeyDownAction {
        // A press during a live locked session ends it (hands-free stop).
        if locked && activeOrStarting { return .finishLocked }
        // A quick second press locks — even if the first tap is still
        // finalizing (the old bug: this was ignored because state != .idle).
        if doubleTap { return .beginLocked }
        if idle { return .beginNormal }
        return .ignore
    }

    /// What finalize should do once the transcriber has drained, decided
    /// purely from the observed session facts (same pattern as
    /// `hotkeyDownAction`) so the edge transitions are unit-testable. A wrong
    /// call here silently loses dictated text: `discardQuiet` on a timed-out
    /// session hides the loss, `paste` on an empty cleanup pastes nothing.
    enum FinalizeOutcome: Equatable {
        /// Nothing worth pasting and nothing went wrong — dismiss silently.
        case discardQuiet
        /// Finalize timed out with no finals: the user spoke, the words are
        /// gone. Must surface as an error, never a silent dismiss.
        case errorTimeout
        /// Clean the text, paste it, record history.
        case paste
    }

    nonisolated static func finalizeOutcome(rawEmpty: Bool, finishedCleanly: Bool,
                                            cleanedEmpty: Bool) -> FinalizeOutcome {
        if rawEmpty {
            // Nothing heard — dismiss quietly, unless the finalize timed out
            // (words may be lost in the analyzer; that is an error, not silence).
            return finishedCleanly ? .discardQuiet : .errorTimeout
        }
        // Heard something, but cleanup reduced it to nothing (pure filler).
        if cleanedEmpty { return .discardQuiet }
        return .paste
    }

    // MARK: - Hotkey entry points

    func hotkeyDown() {
        let now = Date()
        let doubleTap = DictationController.isDoubleTap(previousDown: lastHotkeyDownAt, now: now)
        lastHotkeyDownAt = now
        let active = (state == .starting || state == .recording)
        switch DictationController.hotkeyDownAction(
            idle: state == .idle, activeOrStarting: active, locked: locked, doubleTap: doubleTap) {
        case .finishLocked:
            endAndPaste()
        case .beginLocked:
            // Abandon the throwaway first tap, start a fresh hands-free locked
            // session. The abandoned session's finalize is a no-op: its Task
            // guards on `state == .stopping`, which begin() has since changed.
            cancel(quiet: true)
            begin(locked: true)
        case .beginNormal:
            begin(locked: false)
        case .ignore:
            break
        }
    }

    func hotkeyUp() {
        if locked { return } // hands-free: releasing the key means nothing
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

    private func begin(locked: Bool = false) {
        // Capture the paste target BEFORE any of our UI can appear.
        target = paste.captureTarget()
        pressedAt = Date()
        finals = []
        stopRequested = false
        state = .starting
        errorDismissTask?.cancel()
        self.locked = locked
        AppState.shared.dictationLocked = locked

        AppState.shared.dictationPhase = .recording
        AppState.shared.pillVolatile = ""
        AppState.shared.pillFinal = ""
        PillController.shared.show()
        hotkeys.setRecordingTapEnabled(true)

        let transcriber: any TranscriptionEngine = Transcriber(channel: .me)
        self.transcriber = transcriber
        // Bias Apple's recognizer toward the user's own vocabulary — dictionary
        // terms (spoken + written) and snippet triggers. On-device, zero added
        // latency; the single highest-leverage recognition aid that keeps the
        // hot path deterministic.
        if let apple = transcriber as? Transcriber {
            let d = SettingsStore.shared.data
            apple.contextualStrings = Array(Set(
                d.dictionary.flatMap { [$0.spoken, $0.written] }
                    + d.snippets.map(\.trigger)
            )).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        }

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

        // Resolve the language on the MainActor before the task hops off it.
        let locale = SettingsStore.shared.data.transcriptionLocale

        startTask = Task { [weak self] in
            guard let self else { return }
            do {
                guard let format = await Transcriber.preferredFormat(locale: locale) else {
                    throw NSError(domain: "Radio Operator", code: 2, userInfo: [
                        NSLocalizedDescriptionKey: "Speech model unavailable for \(locale.identifier)."])
                }
                // Dictation never uses Voice-Processing I/O: there is no far-end
                // echo to cancel, and VPIO reconfigures the input device (badly
                // on multi-channel mics) and can gate speech to silence — which
                // would strand a dictation with no finals (no paste, no record).
                // Only meetings enable AEC. Set before the engine's first start.
                MicCapture.shared.voiceProcessing = false
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
                try await transcriber.start(locale: locale)
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
        clearLock()
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

                // Cleanup only runs on non-empty raw (unchanged); the decision
                // itself is the extracted pure static.
                let cleaned = raw.isEmpty ? "" : CleanupEngine.clean(raw, settings: SettingsStore.shared.data)
                switch DictationController.finalizeOutcome(
                    rawEmpty: raw.isEmpty, finishedCleanly: completed, cleanedEmpty: cleaned.isEmpty) {
                case .errorTimeout:
                    self.failSession("Transcription timed out — nothing captured")
                    return
                case .discardQuiet:
                    self.resetToIdle()
                    return
                case .paste:
                    break
                }

                self.state = .idle
                AppState.shared.dictationPhase = .pasting
                let target = self.target ?? self.paste.captureTarget()
                let text = SettingsStore.shared.data.smartLeadingSpace
                    ? SmartSpace.merged(cleaned, needsSpace: SmartSpace.needsLeadingSpace(target: target))
                    : cleaned
                Task { @MainActor in
                    let outcome = await self.paste.paste(text, target: target)
                    let pasteOK = outcome == .pasted
                    let retention = SettingsStore.shared.data.historyRetention
                    if retention != .never {
                        HistoryStore.shared.record(
                            raw: raw, cleaned: cleaned,
                            appBundleID: target.bundleID,
                            durationMs: durationMs, pasteOK: pasteOK)
                        // Markdown mirror so Ask's CLI grep can see dictations.
                        NotesStore.shared.appendDictation(text: cleaned, appName: target.bundleID)
                        if retention == .day {
                            HistoryStore.shared.prune(olderThan: Date(timeIntervalSinceNow: -86_400))
                            NotesStore.pruneDictationLogs(
                                in: NotesStore.shared.dictationsFolder, keepingDays: 1)
                        }
                    }
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
        clearLock()
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

    private func clearLock() {
        locked = false
        AppState.shared.dictationLocked = false
    }

    private func failSession(_ message: String) {
        clearLock()
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
        clearLock()
        AppState.shared.dictationPhase = .idle
        AppState.shared.pillVolatile = ""
        AppState.shared.pillFinal = ""
        AppState.shared.micLevel = 0
        PillController.shared.dismiss()
    }
}
