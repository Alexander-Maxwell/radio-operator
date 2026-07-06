import Foundation
import AppKit
import AVFoundation
import CoreAudio
import UserNotifications

/// Runs a meeting capture session: mic ("Me") + system audio ("Them") → two
/// transcribers → assembler → live window + crash-safe incremental note file →
/// automatic Claude summary on stop.
@MainActor
final class MeetingController: ObservableObject {
    static let shared = MeetingController()

    enum SummaryPhase: Equatable {
        case none
        case transcriptSaved
        case summarizing(startedAt: Date)
        case ready(noteURL: URL)
        case failed(message: String, noteURL: URL)
    }

    @Published var banner: String?
    @Published var summaryPhase: SummaryPhase = .none
    @Published var elapsedText: String = "00:00"
    /// Notes the user jots during the meeting; persisted with the transcript
    /// and fed to the summary as emphasis signals.
    @Published var userNotes: String = "" {
        didSet {
            guard active, userNotes != oldValue else { return }
            schedulePersist()
        }
    }

    private var micTranscriber: (any TranscriptionEngine)?
    private var systemTranscriber: (any TranscriptionEngine)?
    private let tap = SystemAudioTap()
    private var micToken: UUID?
    private var assembler = TranscriptAssembler()
    private var noteURL: URL?
    private var startedAt: Date?
    private var elapsedTimer: Timer?
    private var watchdogTimer: Timer?
    private var persistTask: Task<Void, Never>?
    private var micRecorder: AudioRecorder?
    private var systemRecorder: AudioRecorder?
    private var stopping = false
    private(set) var active = false

    private init() {}

    var isActive: Bool { active }

    // MARK: - Start

    func start() {
        guard !active, !stopping else { return }
        active = true
        stopping = false
        banner = nil
        summaryPhase = .none
        userNotes = ""
        let echoMode = SettingsStore.shared.data.echoGuardMode
        // Echo guard turns on whenever the far side can leak from the speakers
        // back into the mic — i.e. any output that isn't confidently headphones
        // (built-in speakers, external/USB/HDMI/Bluetooth). The old check only
        // recognized built-in speakers, so external speakers ran with no guard.
        let output = AudioOutputDevices.defaultOutput()
        let onSpeakers = !(output?.isHeadphones ?? false)
        assembler = TranscriptAssembler(
            mergeWindow: 2.0,
            echoGuard: echoMode.resolved(onSpeakers: onSpeakers))
        let start = Date()
        startedAt = start

        AppState.shared.meetingActive = true
        AppState.shared.meetingStartedAt = start
        AppState.shared.meetingUtterances = []
        AppState.shared.meetingVolatileMe = ""
        AppState.shared.meetingVolatileThem = ""
        AppState.shared.meetingDegradedNoTap = false
        AppState.shared.meetingRetainingAudio = SettingsStore.shared.data.retainAudio

        // Crash-safety: the note exists on disk from minute zero and is
        // rewritten as finals arrive. A bad notes folder surfaces NOW.
        noteURL = NotesStore.shared.writeMeetingNote(
            title: "Meeting in progress", start: start, durationSeconds: 0,
            utterances: [], degradedMicOnly: false)

        // Speakers + Auto: tell the user echo filtering kicked in and nudge
        // toward headphones for the cleanest transcript.
        if assembler.echoGuard, echoMode == .auto, onSpeakers {
            banner = "Speakers detected — echo filtering on. Headphones give the cleanest transcript."
        }

        // Start-time device diagnostics: the one line that tells us after the
        // fact whether a garbled transcript was speaker bleed or a routing
        // issue — mic + output device, output transport, and whether AEC ran.
        let input = AudioInputDevices.defaultInput()
        NSLog("RadioOperator meeting start — mic=[\(input?.name ?? "?")] out=[\(output?.name ?? "?") · \(AudioOutputDevices.transportLabel(output?.transport ?? 0)) · headphones=\(output?.isHeadphones ?? false)] echoGuard=\(assembler.echoGuard) aec=\(SettingsStore.shared.data.micEchoCancellation)")

        elapsedTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tickElapsed() }
        }
        watchdogTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkLiveness() }
        }

        Task { [weak self] in
            guard let self else { return }
            await self.startPipelines(start: start)
        }
    }

    private func startPipelines(start: Date) async {
        let locale = SettingsStore.shared.data.transcriptionLocale
        guard let format = await Transcriber.preferredFormat(locale: locale) else {
            failStart("Speech model unavailable for \(locale.identifier).")
            return
        }

        // Mic → "Me"
        let mic: any TranscriptionEngine = Transcriber(channel: .me)
        micTranscriber = mic
        mic.onEvent = { [weak self] event in
            Task { @MainActor in self?.ingest(event) }
        }
        mic.onError = { [weak self] message in
            Task { @MainActor in self?.channelFailed(.me, message: message) }
        }

        // System audio → "Them"
        let system: any TranscriptionEngine = Transcriber(channel: .them)
        systemTranscriber = system
        system.onEvent = { [weak self] event in
            Task { @MainActor in self?.ingest(event) }
        }
        system.onError = { [weak self] message in
            Task { @MainActor in self?.channelFailed(.them, message: message) }
        }

        // Optional retention
        if SettingsStore.shared.data.retainAudio, let noteURL {
            let stem = noteURL.deletingPathExtension().lastPathComponent
            let audioDir = NotesStore.shared.audioFolder
            micRecorder = AudioRecorder(url: audioDir.appendingPathComponent("\(stem) - me.m4a"), format: format)
            systemRecorder = AudioRecorder(url: audioDir.appendingPathComponent("\(stem) - them.m4a"), format: format)
        }

        // Wire audio
        do {
            let micRecorder = self.micRecorder
            micToken = try MicCapture.shared.subscribe(format: format, onBuffer: { buffer in
                mic.feed(buffer)
                micRecorder?.write(buffer)
            }, onLevel: { level in
                Task { @MainActor in AppState.shared.micLevel = level }
            })
        } catch {
            failStart("Microphone unavailable: \(error.localizedDescription)")
            return
        }

        let systemRecorder = self.systemRecorder
        tap.onBuffer = { buffer in
            system.feed(buffer)
            systemRecorder?.write(buffer)
        }
        do {
            try tap.start(outputFormat: format)
            Permissions.markSystemAudioGranted()
        } catch {
            // Degraded mic-only mode — visible, never silent.
            AppState.shared.meetingDegradedNoTap = true
            banner = "System audio unavailable (\(error.localizedDescription)) — capturing your mic only."
            UserDefaults.standard.set(false, forKey: "systemAudioPermissionSeen")
        }

        do { try await mic.start(locale: locale) } catch {
            channelFailed(.me, message: error.localizedDescription)
        }
        if !AppState.shared.meetingDegradedNoTap {
            do { try await system.start(locale: locale) } catch {
                channelFailed(.them, message: error.localizedDescription)
            }
        }
    }

    private func failStart(_ message: String) {
        banner = message
        stopInternals()
        active = false
        AppState.shared.meetingActive = false
    }

    // MARK: - Live ingestion

    private func ingest(_ event: TranscriptEvent) {
        guard active else { return }
        assembler.ingest(event)
        AppState.shared.meetingUtterances = assembler.utterances
        AppState.shared.meetingVolatileMe = assembler.volatileMe
        AppState.shared.meetingVolatileThem = assembler.volatileThem
        if event.isFinal {
            schedulePersist()
        }
    }

    /// Debounced rewrite of the on-disk note with the current transcript.
    private func schedulePersist() {
        persistTask?.cancel()
        persistTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled, let self, self.active else { return }
            self.persistTranscript(final: false)
        }
    }

    private func persistTranscript(final: Bool) {
        guard let noteURL, let startedAt else { return }
        let duration = Int(Date().timeIntervalSince(startedAt))
        let content = NotesStore.renderNote(
            title: final ? "Meeting" : "Meeting in progress",
            start: startedAt,
            durationSeconds: duration,
            summaryMarkdown: NotesStore.summaryPendingMarker,
            utterances: assembler.utterances,
            degradedMicOnly: AppState.shared.meetingDegradedNoTap,
            userNotes: userNotes)
        try? content.write(to: noteURL, atomically: true, encoding: .utf8)
    }

    private func channelFailed(_ channel: Speaker, message: String) {
        guard active else { return }
        let tf = DateFormatter()
        tf.dateFormat = "HH:mm"
        let stamp = tf.string(from: Date())
        banner = "\(channel.rawValue)-channel transcription failed at \(stamp) — capturing the other side only."
        // Honesty marker in the transcript itself.
        ingest(TranscriptEvent(channel: channel,
                               text: "[\(channel.rawValue) transcription lost at \(stamp)]",
                               isFinal: true))
    }

    private func tickElapsed() {
        guard let startedAt else { return }
        let s = Int(Date().timeIntervalSince(startedAt))
        elapsedText = String(format: "%02d:%02d", s / 60, s % 60)
        if s >= 3600 {
            elapsedText = String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
        }
    }

    private func checkLiveness() {
        guard active, !stopping else { return }
        if !AppState.shared.meetingDegradedNoTap,
           let last = tap.lastBufferAt, Date().timeIntervalSince(last) > 10 {
            banner = "System audio stalled — check your audio device. Mic capture continues."
        }
    }

    // MARK: - Stop

    func stop() {
        guard active, !stopping else { return }
        stopping = true
        elapsedTimer?.invalidate()
        watchdogTimer?.invalidate()
        persistTask?.cancel()

        let startedAt = self.startedAt ?? Date()

        Task { [weak self] in
            guard let self else { return }
            // Finalize both channels (bounded).
            if let micToken = self.micToken {
                MicCapture.shared.unsubscribe(micToken)
                self.micToken = nil
            }
            self.tap.stop()
            await self.micTranscriber?.finishAndWait(timeout: 4.0)
            await self.systemTranscriber?.finishAndWait(timeout: 4.0)
            self.micRecorder?.finish()
            self.systemRecorder?.finish()

            await MainActor.run {
                let utterances = self.assembler.finish()
                AppState.shared.meetingUtterances = utterances
                AppState.shared.meetingVolatileMe = ""
                AppState.shared.meetingVolatileThem = ""
                self.persistTranscript(final: true)
                self.summaryPhase = .transcriptSaved
                self.active = false
                self.stopping = false
                AppState.shared.meetingActive = false

                guard let noteURL = self.noteURL else { return }
                let duration = Int(Date().timeIntervalSince(startedAt))

                if utterances.isEmpty {
                    self.summaryPhase = .failed(message: "No speech captured", noteURL: noteURL)
                    self.stopInternals()
                    return
                }

                // Auto-summary is opt-out: when off, the transcript is saved and
                // the user can summarize later from the Library.
                if !SettingsStore.shared.data.autoSummarize {
                    self.summaryPhase = .transcriptSaved
                    MeetingController.notify(
                        title: "Transcript saved",
                        body: "Auto-summary is off — summarize from the Library when ready.")
                    self.stopInternals()
                    return
                }

                // Auto-summary on stop — the moment competitors don't have.
                self.summaryPhase = .summarizing(startedAt: Date())
                AppState.shared.summaryInFlight = true
                let transcriptMD = utterances
                    .map { "\($0.speaker.rawValue): \($0.text)" }
                    .joined(separator: "\n")
                let df = DateFormatter()
                df.dateFormat = "yyyy-MM-dd"
                let fallbackTitle = "Meeting \(df.string(from: startedAt))"

                ClaudeService.shared.summarizeNote(
                    at: noteURL, transcriptMarkdown: transcriptMD, fallbackTitle: fallbackTitle,
                    userNotes: self.userNotes
                ) { [weak self] result in
                    guard let self else { return }
                    AppState.shared.summaryInFlight = false
                    switch result {
                    case .success(let finalURL):
                        // Note was retitled and renamed to Claude's title.
                        self.summaryPhase = .ready(noteURL: finalURL)
                        MeetingController.notify(
                            title: "Meeting summarized",
                            body: "Summary and action items are ready.")
                        _ = duration
                    case .failure(let error):
                        self.summaryPhase = .failed(message: error.localizedDescription, noteURL: noteURL)
                        MeetingController.notify(
                            title: "Summary pending",
                            body: "Transcript saved. Retry the summary from the Library.")
                    }
                }
                self.stopInternals()
            }
        }
    }

    /// Retry a failed/pending summary for a note (used by Library + status strip).
    func retrySummary(noteURL: URL) {
        guard let content = NotesStore.shared.read(noteURL: noteURL) else { return }
        let transcript = content.components(separatedBy: "## Transcript").last ?? content
        summaryPhase = .summarizing(startedAt: Date())
        AppState.shared.summaryInFlight = true
        ClaudeService.shared.summarizeNote(
            at: noteURL, transcriptMarkdown: transcript,
            fallbackTitle: noteURL.deletingPathExtension().lastPathComponent,
            userNotes: NotesStore.parseUserNotes(content) ?? ""
        ) { [weak self] result in
            AppState.shared.summaryInFlight = false
            switch result {
            case .success(let finalURL):
                self?.summaryPhase = .ready(noteURL: finalURL)
            case .failure(let error):
                self?.summaryPhase = .failed(message: error.localizedDescription, noteURL: noteURL)
            }
        }
    }

    private func stopInternals() {
        micTranscriber = nil
        systemTranscriber = nil
        micRecorder = nil
        systemRecorder = nil
        tap.onBuffer = nil
        elapsedTimer?.invalidate()
        elapsedTimer = nil
        watchdogTimer?.invalidate()
        watchdogTimer = nil
    }

    // MARK: - Helpers

    static func notify(title: String, body: String) {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .authorized
                || settings.authorizationStatus == .provisional else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            center.add(UNNotificationRequest(
                identifier: UUID().uuidString, content: content, trigger: nil))
        }
    }
}
