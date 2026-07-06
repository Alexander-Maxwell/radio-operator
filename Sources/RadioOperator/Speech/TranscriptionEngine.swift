import Foundation
import AVFoundation

/// The transcription-engine contract: one live speech session on one audio
/// channel. Extracted from the concrete Apple `Transcriber` as decoupling
/// only (D2) — Apple SpeechAnalyzer remains the sole engine unless the WER
/// harness someday proves it materially weaker.
///
/// Semantics every conforming engine must honor:
/// - Buffers may be fed before `start()` completes (pre-roll buffering, so
///   there is no first-word clipping).
/// - Events and errors arrive on an arbitrary task context; callers marshal
///   to MainActor themselves.
/// - `finishAndWait` is bounded by its timeout so a wedged engine can never
///   hang the caller's state machine.
protocol TranscriptionEngine: AnyObject, Sendable {
    /// Which speaker this session is attributed to (Me vs Them).
    var channel: Speaker { get }

    /// Volatile and final transcript events.
    var onEvent: (@Sendable (TranscriptEvent) -> Void)? { get set }
    /// Fatal session errors, as a human-readable message.
    var onError: (@Sendable (String) -> Void)? { get set }

    /// Begin the session for the given locale.
    func start(locale: Locale) async throws

    /// Feed a PCM buffer already converted to the engine's preferred format.
    /// Safe to call before `start()` completes — audio is buffered.
    func feed(_ buffer: AVAudioPCMBuffer)

    /// Stop feeding, force finalization of pending audio, and wait until
    /// every result has been delivered. Returns false on timeout.
    @discardableResult
    func finishAndWait(timeout: TimeInterval) async -> Bool

    /// Abandon the session without waiting for finals.
    func cancel()

    /// The engine's preferred input format for this machine and locale.
    static func preferredFormat(locale: Locale) async -> AVAudioFormat?

    /// Ensure the on-device model for the locale is installed.
    static func ensureModel(locale: Locale) async throws
}
