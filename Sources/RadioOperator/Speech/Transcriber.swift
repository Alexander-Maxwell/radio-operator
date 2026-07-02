import Foundation
import Speech
import AVFoundation

/// Wraps one SpeechAnalyzer + SpeechTranscriber session for a single audio
/// channel. The input stream exists from init, so buffers can be fed (and are
/// buffered) even before `start()` finishes — no first-word clipping.
/// Events arrive on an arbitrary task context; marshal to MainActor yourself.
final class Transcriber: @unchecked Sendable {
    let channel: Speaker

    private var analyzer: SpeechAnalyzer?
    private var module: SpeechTranscriber?
    private let inputStream: AsyncStream<AnalyzerInput>
    private var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?
    private var resultsTask: Task<Void, Never>?
    private(set) var analyzerFormat: AVAudioFormat?
    private(set) var lastEventAt: Date?

    var onEvent: (@Sendable (TranscriptEvent) -> Void)?
    var onError: (@Sendable (String) -> Void)?

    init(channel: Speaker) {
        self.channel = channel
        let (stream, continuation) = AsyncStream.makeStream(of: AnalyzerInput.self)
        inputStream = stream
        inputContinuation = continuation
    }

    /// The analyzer's preferred input format for this machine/locale. Cached
    /// after first query so hot-path sessions don't pay for it.
    private static var cachedFormat: AVAudioFormat?

    static func preferredFormat() async -> AVAudioFormat? {
        if let cachedFormat { return cachedFormat }
        let probe = SpeechTranscriber(locale: Locale(identifier: "en_US"),
                                      transcriptionOptions: [],
                                      reportingOptions: [.volatileResults],
                                      attributeOptions: [])
        let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [probe])
        cachedFormat = format
        return format
    }

    /// Ensures the on-device model for the locale is installed (no-op when,
    /// as on this machine, English is preinstalled).
    static func ensureModel(locale: Locale = Locale(identifier: "en_US")) async throws {
        let probe = SpeechTranscriber(locale: locale,
                                      transcriptionOptions: [],
                                      reportingOptions: [],
                                      attributeOptions: [])
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [probe]) {
            try await request.downloadAndInstall()
        }
    }

    func start(locale: Locale = Locale(identifier: "en_US")) async throws {
        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults],
            attributeOptions: [.audioTimeRange]
        )
        module = transcriber

        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }

        analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        self.analyzer = analyzer

        let channel = self.channel
        let onEvent = { [weak self] (event: TranscriptEvent) in
            self?.lastEventAt = Date()
            self?.onEvent?(event)
        }
        let onError = { [weak self] (msg: String) in self?.onError?(msg) }

        resultsTask = Task.detached(priority: .userInitiated) {
            do {
                for try await result in transcriber.results {
                    let text = String(result.text.characters)
                    let start = result.range.start.seconds
                    let end = result.range.end.seconds
                    onEvent(TranscriptEvent(
                        channel: channel,
                        text: text,
                        isFinal: result.isFinal,
                        audioStart: start.isFinite ? start : nil,
                        audioEnd: end.isFinite ? end : nil,
                        wallClock: Date()
                    ))
                }
            } catch is CancellationError {
                // expected on cancel
            } catch {
                onError("Transcription failed: \(error.localizedDescription)")
            }
        }

        try await analyzer.start(inputSequence: inputStream)
    }

    /// Feed a PCM buffer already converted to the analyzer's preferred format.
    /// Safe to call before `start()` completes — audio is buffered.
    func feed(_ buffer: AVAudioPCMBuffer) {
        inputContinuation?.yield(AnalyzerInput(buffer: buffer))
    }

    /// Stop feeding, force finalization of pending audio, and wait until every
    /// result (including the last final) has been delivered. Bounded by
    /// `timeout` so a wedged analyzer can never hang the state machine.
    /// Returns false on timeout.
    @discardableResult
    func finishAndWait(timeout: TimeInterval = 3.0) async -> Bool {
        inputContinuation?.finish()
        inputContinuation = nil
        let analyzer = self.analyzer
        let resultsTask = self.resultsTask
        let finished = await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                do {
                    try await analyzer?.finalizeAndFinishThroughEndOfInput()
                } catch {
                    // Finalize errors still surface finals that already arrived.
                }
                await resultsTask?.value
                return true
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
        self.resultsTask = nil
        self.analyzer = nil
        module = nil
        return finished
    }

    /// Abandon the session without waiting for finals.
    func cancel() {
        inputContinuation?.finish()
        inputContinuation = nil
        resultsTask?.cancel()
        resultsTask = nil
        let analyzer = self.analyzer
        Task.detached { try? await analyzer?.cancelAndFinishNow() }
        self.analyzer = nil
        module = nil
    }
}
