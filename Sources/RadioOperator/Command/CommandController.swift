import AppKit
import AVFoundation
import Carbon.HIToolbox

/// Command Mode: hold the command hotkey, speak an instruction, release —
/// Claude transforms the current selection and the result is pasted over it
/// (or, with nothing selected, inserted at the cursor). One native ⌘Z in the
/// target app reverses the paste; the pill shows a 4s "⌘Z to undo" notice.
///
/// This is a PARALLEL controller to DictationController, never a branch
/// inside it: the dictation hot path gains zero work from Command Mode
/// existing. Each controller owns its own HotkeyManager, Transcriber, and
/// PasteService; MicCapture broadcasts to whichever is live.
@MainActor
final class CommandController {
    static let shared = CommandController()

    /// Session state, mirrored into AppState for the pill.
    private var state: AppState.CommandPhase = .idle {
        didSet { AppState.shared.commandPhase = state }
    }

    private var transcriber: (any TranscriptionEngine)?
    private var micToken: UUID?
    private var target: PasteService.Target?
    private var selection: SelectionReader.Selection?
    private let paste = PasteService()
    private var startTask: Task<Void, Never>?
    private var transformTask: Task<Void, Never>?
    private var noticeTask: Task<Void, Never>?
    private var stopRequested = false
    private var finals: [String] = []

    let hotkeys: HotkeyManager

    private init() {
        hotkeys = HotkeyManager(hotkeyProvider: { SettingsStore.shared.data.resolvedCommandHotkey })
        hotkeys.onHoldDown = { [weak self] in self?.hotkeyDown() }
        hotkeys.onHoldUp = { [weak self] in self?.hotkeyUp() }
        hotkeys.onCancel = { [weak self] in self?.cancel() }
    }

    func startListening() {
        hotkeys.start()
    }

    // MARK: - Begin gate (D6c)

    /// Frontmost apps where Command Mode refuses to run: pasting a rewritten
    /// shell command is an execution risk, not a convenience.
    nonisolated static let terminalDenylist: Set<String> = [
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "dev.warp.Warp",
        "com.github.wez.wezterm",
        "io.alacritty",
        "net.kovidgoyal.kitty",
    ]

    enum BeginDecision: Equatable {
        case allow
        case refuse(reason: String)
    }

    /// Pure begin gate so the refusal matrix is unit-testable.
    nonisolated static func beginDecision(dictating: Bool, meeting: Bool, secureInput: Bool,
                                          frontmostBundleID: String?) -> BeginDecision {
        if dictating { return .refuse(reason: "Finish dictating first") }
        if meeting { return .refuse(reason: "Command Mode is off during meetings") }
        if secureInput { return .refuse(reason: "Secure input active — Command Mode is off") }
        if let id = frontmostBundleID, terminalDenylist.contains(id) {
            return .refuse(reason: "Command Mode is off in terminals")
        }
        return .allow
    }

    // MARK: - Hotkey entry points

    private func hotkeyDown() {
        guard state == .idle else { return }
        let target = paste.captureTarget()
        switch CommandController.beginDecision(
            dictating: DictationController.shared.isActive,
            meeting: MeetingController.shared.isActive,
            secureInput: IsSecureEventInputEnabled(),
            frontmostBundleID: target.bundleID) {
        case .refuse(let reason):
            showTransientNotice(reason)
        case .allow:
            begin(target: target)
        }
    }

    private func hotkeyUp() {
        switch state {
        case .capturing:
            // Still capturing the selection / spinning up — flag it; the
            // start task resolves this as an accidental tap.
            stopRequested = true
        case .recording:
            finishAndTransform()
        default:
            break
        }
    }

    // MARK: - Session lifecycle

    private func begin(target: PasteService.Target) {
        self.target = target
        selection = nil
        finals = []
        stopRequested = false
        state = .capturing
        noticeTask?.cancel()
        AppState.shared.commandNotice = nil
        PillController.shared.show()

        let transcriber: any TranscriptionEngine = Transcriber(channel: .me)
        self.transcriber = transcriber
        transcriber.onEvent = { event in
            Task { @MainActor in
                guard CommandController.shared.transcriber === transcriber else { return }
                if event.isFinal {
                    CommandController.shared.finals.append(event.text)
                }
            }
        }
        transcriber.onError = { message in
            Task { @MainActor in
                guard CommandController.shared.transcriber === transcriber else { return }
                CommandController.shared.finish(notice: message)
            }
        }

        let locale = SettingsStore.shared.data.transcriptionLocale

        startTask = Task { [weak self] in
            guard let self else { return }
            // Selection first: the Cmd-C fallback posts a synthetic keystroke
            // that the recording-scoped Esc/chord tap (enabled below) must
            // never see as a chord.
            let sel = await SelectionReader.read(target: target)
            guard self.state == .capturing, self.transcriber === transcriber else { return }
            self.selection = sel
            if self.stopRequested {
                // Released before recording ever began — accidental tap.
                self.cancelQuietly()
                return
            }
            do {
                guard let format = await Transcriber.preferredFormat(locale: locale) else {
                    throw NSError(domain: "Radio Operator", code: 3, userInfo: [
                        NSLocalizedDescriptionKey: "Speech model unavailable for \(locale.identifier)."])
                }
                guard self.state == .capturing, self.transcriber === transcriber else { return }
                let token = try MicCapture.shared.subscribe(format: format, onBuffer: { buffer in
                    transcriber.feed(buffer)
                }, onLevel: { level in
                    Task { @MainActor in AppState.shared.micLevel = level }
                })
                self.micToken = token
                self.hotkeys.setRecordingTapEnabled(true)
                self.state = .recording
                if self.stopRequested {
                    self.cancelQuietly()
                    return
                }
                try await transcriber.start(locale: locale)
            } catch {
                guard self.state == .capturing || self.state == .recording else { return }
                self.finish(notice: error.localizedDescription)
            }
        }
    }

    private func finishAndTransform() {
        guard state == .recording else { return }
        state = .transforming
        if let micToken {
            MicCapture.shared.unsubscribe(micToken)
            self.micToken = nil
        }
        AppState.shared.micLevel = 0
        // Sticky progress notice; the Esc tap stays on so Esc still cancels.
        noticeTask?.cancel()
        AppState.shared.commandNotice = "Transforming — Esc cancels"
        let transcriber = self.transcriber

        transformTask = Task { [weak self] in
            guard let self else { return }
            _ = await transcriber?.finishAndWait(timeout: 3.0)
            guard self.state == .transforming else { return }
            self.transcriber = nil
            let instruction = self.finals.joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !instruction.isEmpty else {
                self.finish(notice: "Didn't catch an instruction")
                return
            }
            let sel = self.selection ?? SelectionReader.Selection(text: nil, mode: .insert)
            do {
                let text = try await ClaudeService.shared.transform(
                    selection: sel.text, instruction: instruction,
                    appBundleID: self.target?.bundleID)
                guard self.state == .transforming else { return }
                self.state = .pasting
                self.hotkeys.setRecordingTapEnabled(false)
                let target = self.target ?? self.paste.captureTarget()
                // Replace pastes over the still-live selection; insert pastes
                // at the cursor. The paste primitive is identical either way.
                switch await self.paste.paste(text, target: target) {
                case .pasted:
                    self.finish(notice: "⌘Z to undo")
                case .clipboardOnly(let reason):
                    self.finish(notice: reason)
                }
            } catch {
                guard self.state == .transforming else { return } // cancelled
                self.finish(notice: error.localizedDescription)
            }
        }
    }

    /// Esc / chord cancel: abandon whatever phase we're in, quietly.
    func cancel() {
        guard state != .idle else { return }
        transformTask?.cancel()
        transformTask = nil
        cancelQuietly()
    }

    private func cancelQuietly() {
        cleanup()
        AppState.shared.commandNotice = nil
        dismissPillIfUnused()
    }

    private func finish(notice: String) {
        cleanup()
        showTransientNotice(notice)
    }

    /// Tear down session resources; state returns to idle.
    private func cleanup() {
        state = .idle
        stopRequested = false
        hotkeys.setRecordingTapEnabled(false)
        startTask?.cancel()
        startTask = nil
        if let micToken {
            MicCapture.shared.unsubscribe(micToken)
            self.micToken = nil
        }
        transcriber?.cancel()
        transcriber = nil
        selection = nil
        finals = []
        AppState.shared.micLevel = 0
    }

    // MARK: - Pill notice

    private func showTransientNotice(_ message: String) {
        AppState.shared.commandNotice = message
        PillController.shared.show()
        noticeTask?.cancel()
        noticeTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard !Task.isCancelled else { return }
            AppState.shared.commandNotice = nil
            self.dismissPillIfUnused()
        }
    }

    /// The pill is shared with dictation — only dismiss it when neither
    /// state machine is using it.
    private func dismissPillIfUnused() {
        guard AppState.shared.dictationPhase == .idle,
              AppState.shared.commandPhase == .idle,
              AppState.shared.commandNotice == nil else { return }
        PillController.shared.dismiss()
    }
}
