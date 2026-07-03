import Foundation
import Combine

/// Single source of truth for UI-visible app state. All mutation on MainActor.
@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()

    enum DictationPhase: Equatable {
        case idle
        case recording
        case finalizing
        case pasting
        case error(String)
    }

    // Dictation / pill
    @Published var dictationPhase: DictationPhase = .idle
    @Published var pillVolatile: String = ""
    @Published var pillFinal: String = ""
    @Published var micLevel: Float = 0
    /// Hands-free session (double-tap lock): release doesn't stop recording.
    @Published var dictationLocked: Bool = false

    // Meeting
    @Published var meetingActive: Bool = false
    @Published var meetingStartedAt: Date?
    @Published var meetingUtterances: [Utterance] = []
    @Published var meetingVolatileMe: String = ""
    @Published var meetingVolatileThem: String = ""
    /// True when system-audio capture failed and the meeting is mic-only.
    @Published var meetingDegradedNoTap: Bool = false
    @Published var meetingRetainingAudio: Bool = false

    // Intelligence
    @Published var summaryInFlight: Bool = false

    /// SF Symbol for the menu bar icon reflecting the most urgent state.
    var statusSymbol: String {
        if case .error = dictationPhase { return "exclamationmark.bubble" }
        if case .recording = dictationPhase { return "waveform.circle.fill" }
        if case .finalizing = dictationPhase { return "ellipsis.circle" }
        if case .pasting = dictationPhase { return "arrow.down.circle" }
        if meetingActive { return "record.circle.fill" }
        if summaryInFlight { return "sparkles" }
        return "waveform"
    }

    private init() {}
}
