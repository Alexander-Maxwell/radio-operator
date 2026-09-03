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
    /// True when the mic monitor auto-armed this meeting (vs a manual start).
    /// Only auto-started meetings self-discard when no conversation follows.
    private var autoStarted = false
    /// Set once any real (non-marker) speech is transcribed, so a phantom
    /// auto-start can be told apart from a genuine call that opened quietly.
    private var sawRealSpeech = false
    /// One-shot grace-window check that discards a silent auto-start.
    private var autoCancelTimer: Timer?
    /// Live lookup (opt-in): at most one Claude call in flight for a question
    /// heard on either channel. The gate lives in QuestionDetector; the
    /// generation lets a cancelled lookup's cleanup never touch a newer one.
    @Published private(set) var lookupInFlight = false
    /// Answers so far, persisted under "## Live answers" — machine-generated,
    /// so kept apart from userNotes (which steers the summary).
    @Published private(set) var liveAnswers: String = "" {
        didSet {
            guard active, liveAnswers != oldValue else { return }
            schedulePersist()
        }
    }
    private var lookupTask: Task<Void, Never>?
    private var lookupGeneration = 0
    private var lookupCount = 0
    private var lastLookupKey: String?
    private var lastLookupAt: Date?

    private init() {}

    var isActive: Bool { active }

    /// Bumped on every teardown so a stale watchdog can't reset a newer meeting.
    private var teardownGeneration = 0

    // MARK: - Start

    func start(autoStarted: Bool = false) {
        guard !active, !stopping else { return }
        active = true
        stopping = false
        self.autoStarted = autoStarted
        sawRealSpeech = false
        banner = nil
        summaryPhase = .none
        userNotes = ""
        liveAnswers = ""
        lookupCount = 0
        lastLookupKey = nil
        lastLookupAt = nil
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
        NSLog("RadioOperator meeting start — trigger=\(autoStarted ? "auto" : "manual") mic=[\(input?.name ?? "?")] out=[\(output?.name ?? "?") · \(AudioOutputDevices.transportLabel(output?.transport ?? 0)) · headphones=\(output?.isHeadphones ?? false)] echoGuard=\(assembler.echoGuard) aec=\(SettingsStore.shared.data.micEchoCancellation)")

        elapsedTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tickElapsed() }
        }
        watchdogTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkLiveness() }
        }
        // A meeting the app armed on its own gets a grace window: if no real
        // speech lands, it's a phantom (mic opened but no call) and self-discards.
        if autoStarted {
            autoCancelTimer = Timer.scheduledTimer(
                withTimeInterval: MeetingAutoCancel.graceWindow, repeats: false) { [weak self] _ in
                Task { @MainActor in self?.discardIfPhantom() }
            }
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

        // Wire audio. Meetings honor the hardware-AEC setting (dictation never
        // does); set before the engine's first start for this session.
        MicCapture.shared.voiceProcessing = SettingsStore.shared.data.micEchoCancellation
        do {
            let micRecorder = self.micRecorder
            let meGate = LevelGate()
            micToken = try MicCapture.shared.subscribe(format: format, onBuffer: { buffer in
                mic.feed(buffer)
                micRecorder?.write(buffer)
            }, onLevel: { level in
                // Fires per audio buffer; gate before touching the MainActor.
                guard meGate.shouldPublish(level) else { return }
                Task { @MainActor in
                    AppState.shared.micLevel = level
                    AppState.shared.meetingMeLevel = level
                }
            })
        } catch {
            failStart("Microphone unavailable: \(error.localizedDescription)")
            return
        }

        let systemRecorder = self.systemRecorder
        let themGate = LevelGate()
        tap.onBuffer = { buffer in
            system.feed(buffer)
            systemRecorder?.write(buffer)
            // Tap buffers arrive converted to the analyzer format (often
            // int16), which rmsLevel can't read — amplitude(of:) can. Same
            // ×12 UI gain as the mic meter.
            let level = min(1, MicCapture.amplitude(of: buffer).rms * 12)
            guard themGate.shouldPublish(level) else { return }
            Task { @MainActor in AppState.shared.meetingThemLevel = level }
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

        // Capture is live (mic at minimum) — surface the HUD.
        RecordingHUDController.shared.show()

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
        AppState.shared.meetingMeLevel = 0
        AppState.shared.meetingThemLevel = 0
        RecordingHUDController.shared.dismiss()
    }

    /// Grace-window verdict for an auto-started meeting: if it captured no real
    /// speech, it's a phantom (a call app was up and the mic opened, but no
    /// conversation followed — or a bare mic-open slipped the front gate). Tear
    /// it down and delete its note + any audio so no empty "Meeting in progress"
    /// junk is left behind. Genuine calls (any speech) are untouched.
    private func discardIfPhantom() {
        guard active, !stopping,
              MeetingAutoCancel.shouldDiscard(
                autoStarted: autoStarted,
                elapsed: Date().timeIntervalSince(startedAt ?? Date()),
                sawSpeech: sawRealSpeech) else { return }
        stopping = true
        autoStarted = false
        // Same guarantee as stop(): the phantom / no-speech discard clears the live
        // flags synchronously so the red icon can never linger on the async path.
        active = false
        AppState.shared.meetingActive = false
        RecordingHUDController.shared.dismiss()
        autoCancelTimer?.invalidate(); autoCancelTimer = nil
        elapsedTimer?.invalidate()
        watchdogTimer?.invalidate()
        persistTask?.cancel()
        cancelLookup()
        armTeardownWatchdog()
        let discardURL = noteURL

        Task { [weak self] in
            guard let self else { return }
            if let micToken = self.micToken {
                MicCapture.shared.unsubscribe(micToken)
                self.micToken = nil
            }
            self.tap.stop()
            await self.micTranscriber?.finishAndWait(timeout: 2.0)
            await self.systemTranscriber?.finishAndWait(timeout: 2.0)
            self.micRecorder?.finish()
            self.systemRecorder?.finish()

            await MainActor.run {
                if let discardURL { NotesStore.shared.deleteMeetingNote(discardURL) }
                AppState.shared.meetingUtterances = []
                AppState.shared.meetingVolatileMe = ""
                AppState.shared.meetingVolatileThem = ""
                AppState.shared.meetingMeLevel = 0
                AppState.shared.meetingThemLevel = 0
                self.summaryPhase = .none
                self.active = false
                self.stopping = false
                self.noteURL = nil
                AppState.shared.meetingActive = false
                self.stopInternals()
                NSLog("RadioOperator meeting auto-discarded — phantom auto-start (no speech in \(Int(MeetingAutoCancel.graceWindow))s)")
            }
        }
    }

    /// Drops a "🚩 <elapsed> flagged" line into the user notes — persisted
    /// with the note and an emphasis signal for the summary.
    func flagMoment() {
        guard active else { return }
        let line = "🚩 \(elapsedText) flagged"
        userNotes = userNotes.isEmpty ? line : userNotes + "\n" + line
    }

    // MARK: - Live lookup

    /// If a finalized line reads as a question, look it up in the user's notes
    /// with Claude while the meeting runs. Opt-in (`liveLookup`), either
    /// channel, one at a time, capped per meeting. The app retrieves the
    /// excerpts locally first (the live note excluded), so a question the
    /// notes can't answer never leaves the Mac, and the spawn gets no tools.
    /// The answer lands as a notification and under "Live answers" in the note.
    // ponytail: notification + note section is the whole surface; add a
    // floating panel if Focus (screen sharing) swallows too many notifications.
    private func maybeLookup(text: String, channel: Speaker) {
        guard SettingsStore.shared.data.liveLookup,
              let question = QuestionDetector.question(in: text) else { return }
        let key = QuestionDetector.key(question)
        guard QuestionDetector.shouldFire(
            key: key, lastKey: lastLookupKey, lastAt: lastLookupAt, now: Date(),
            inFlight: lookupTask != nil, count: lookupCount) else { return }
        lastLookupKey = key
        lastLookupAt = Date()
        lookupGeneration &+= 1
        let gen = lookupGeneration
        let terms = QuestionDetector.searchTerms(question)
        let notesFolder = SettingsStore.shared.notesFolderURL
        let liveNote = noteURL
        let elapsed = elapsedText
        let qLen = question.count
        lookupInFlight = true
        lookupTask = Task { @MainActor [weak self] in
            defer {
                if let self, self.lookupGeneration == gen {
                    self.lookupInFlight = false
                    self.lookupTask = nil
                }
            }
            // Only the app's own corpus (Meetings/, Dictations/), never the rest
            // of a vault the notes folder may live in.
            let corpus = [ClaudeService.scopedFolder(.meetings, notesFolder: notesFolder),
                          ClaudeService.scopedFolder(.dictations, notesFolder: notesFolder)]
            let snippets = await Task.detached(priority: .utility) {
                QuestionDetector.snippets(terms: terms, in: corpus, excluding: liveNote,
                                          maxChars: 6000)
            }.value
            guard !snippets.isEmpty, !Task.isCancelled, let self, self.active else {
                NSLog("RadioOperator live lookup skipped — no local match (\(qLen) chars, \(terms.count) terms)")
                return
            }
            // The cap counts real spawns, not detections.
            self.lookupCount += 1
            let raw: String
            do {
                raw = try await ClaudeService.shared.lookup(
                    question: question, speaker: channel, snippets: snippets, timeout: 45)
            } catch {
                let label = (error as? ClaudeService.ClaudeError)?.logLabel
                    ?? (error is CancellationError ? "cancelled" : String(describing: type(of: error)))
                NSLog("RadioOperator live lookup failed — \(label)")
                return
            }
            guard !Task.isCancelled, self.active,
                  let answer = QuestionDetector.answer(from: raw) else { return }
            let who = channel == .me ? "You" : "They"
            let flat = QuestionDetector.oneLine(answer)
            let line = "❓ \(elapsed) \(who) asked: \(question)\n→ \(flat.prefix(600))"
            self.liveAnswers = self.liveAnswers.isEmpty ? line : self.liveAnswers + "\n\n" + line
            MeetingController.notify(title: "❓ \(question.prefix(60))",
                                     body: String(flat.prefix(500)))
        }
    }

    /// Kills any in-flight lookup (the Claude child dies with the task) so it
    /// can never outlive the meeting or block the drain.
    private func cancelLookup() {
        lookupGeneration &+= 1
        lookupTask?.cancel()
        lookupTask = nil
        lookupInFlight = false
    }

    // MARK: - Live ingestion

    private func ingest(_ event: TranscriptEvent) {
        guard active else { return }
        // Real speech (not a bracketed "[… transcription lost]" honesty marker)
        // means this is a genuine call, so the phantom check won't discard it.
        let text = event.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty, !text.hasPrefix("[") { sawRealSpeech = true }
        let kept = assembler.ingest(event)
        AppState.shared.meetingUtterances = assembler.utterances
        AppState.shared.meetingVolatileMe = assembler.volatileMe
        AppState.shared.meetingVolatileThem = assembler.volatileThem
        if event.isFinal {
            schedulePersist()
            // Only finals that made the transcript: a mic echo of the far side
            // must not be looked up as "You asked".
            if kept { maybeLookup(text: text, channel: event.channel) }
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
            userNotes: userNotes,
            liveAnswers: liveAnswers)
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

    /// - Parameter onQuit: when non-nil, the caller is quitting. Fired on the
    ///   main actor the instant the transcript is durably saved, and the
    ///   auto-summary is skipped (it spawns ClaudeService, which is slow and the
    ///   step most likely to wedge a quit; regenerate it later from the Library).
    func stop(then onQuit: (() -> Void)? = nil) {
        guard active, !stopping else { onQuit?(); return }
        stopping = true
        // Capture is over the instant we commit to stopping — clear the "live"
        // flags SYNCHRONOUSLY. The async drain below is bounded but not guaranteed
        // to reach its own reset if a finalize stalls, and it must never be what
        // turns the red menu-bar icon off. It only finalizes text + summary now.
        // (`stopping` is cleared at the END of the drain, since a new meeting must
        // not start while this one's audio is still draining.)
        active = false
        AppState.shared.meetingActive = false
        RecordingHUDController.shared.dismiss()
        elapsedTimer?.invalidate()
        watchdogTimer?.invalidate()
        autoCancelTimer?.invalidate(); autoCancelTimer = nil
        persistTask?.cancel()
        cancelLookup()
        armTeardownWatchdog()

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
                AppState.shared.meetingMeLevel = 0
                AppState.shared.meetingThemLevel = 0
                self.persistTranscript(final: true)
                self.summaryPhase = .transcriptSaved
                self.active = false
                self.stopping = false
                AppState.shared.meetingActive = false

                // Quit path: transcript is on disk. Hand control back to the
                // terminator now and skip auto-summary to keep quit fast and
                // unhangable. ponytail: summary-on-quit is best-effort; regenerate
                // from the Library if you need it.
                if let onQuit {
                    self.stopInternals()
                    onQuit()
                    return
                }

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

    /// Belt-and-suspenders for the async drain. The bounded finalizes should
    /// always let stop()/discardIfPhantom() reach their `stopping = false`, but if
    /// one ever wedged, `stopping` would stay true and silently block the next
    /// Start (the red icon is already cleared up-front — this is the invisible
    /// half of the hang). Fires well after the drain must have finished and, only
    /// if we're still stuck AND no newer teardown superseded us, slams to idle.
    /// A no-op when teardown already completed.
    /// The watchdog fires ONLY when it still owns the teardown (no newer stop
    /// superseded it) AND the drain hasn't finished. Pure, so the cross-meeting
    /// staleness guard — a stale watchdog must not reset a *newer* meeting's
    /// teardown — is unit-testable.
    nonisolated static func watchdogShouldReset(currentGeneration: Int,
                                                watchdogGeneration: Int,
                                                stopping: Bool) -> Bool {
        currentGeneration == watchdogGeneration && stopping
    }

    private func armTeardownWatchdog() {
        teardownGeneration &+= 1
        let gen = teardownGeneration
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 15_000_000_000)
            guard let self,
                  MeetingController.watchdogShouldReset(
                    currentGeneration: self.teardownGeneration,
                    watchdogGeneration: gen, stopping: self.stopping) else { return }
            NSLog("RadioOperator meeting teardown watchdog — drain wedged, forcing idle reset")
            self.active = false
            self.stopping = false
            AppState.shared.meetingActive = false
            AppState.shared.summaryInFlight = false
            self.stopInternals()
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
        autoCancelTimer?.invalidate()
        autoCancelTimer = nil
        cancelLookup()
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

/// Audio-thread → MainActor meter gate: lets a level through at most ~12 Hz
/// and only when it moved enough to visibly change the bars, so per-buffer
/// callbacks never storm the MainActor.
private final class LevelGate: @unchecked Sendable {
    private let lock = NSLock()
    private var lastValue: Float = -1
    private var lastAt: CFAbsoluteTime = 0

    func shouldPublish(_ value: Float) -> Bool {
        let now = CFAbsoluteTimeGetCurrent()
        lock.lock()
        defer { lock.unlock() }
        guard now - lastAt >= 0.08, abs(value - lastValue) > 0.02 else { return false }
        lastValue = value
        lastAt = now
        return true
    }
}
