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

    // Command Mode (parallel controller; shares the pill with dictation)
    enum CommandPhase: Equatable {
        case idle
        case capturing      // reading the selection
        case recording      // hearing the instruction
        case transforming   // Claude in flight
        case pasting
    }
    @Published var commandPhase: CommandPhase = .idle
    /// Transient pill notice ("⌘Z to undo", refusal reasons). Set and
    /// auto-cleared by CommandController.
    @Published var commandNotice: String? = nil

    // Meeting
    @Published var meetingActive: Bool = false
    @Published var meetingStartedAt: Date?
    @Published var meetingUtterances: [Utterance] = []
    @Published var meetingVolatileMe: String = ""
    @Published var meetingVolatileThem: String = ""
    /// True when system-audio capture failed and the meeting is mic-only.
    @Published var meetingDegradedNoTap: Bool = false
    @Published var meetingRetainingAudio: Bool = false
    /// Meeting meter levels (0–1), throttled at the source to ≤ ~12 Hz.
    @Published var meetingMeLevel: Float = 0
    @Published var meetingThemLevel: Float = 0

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
