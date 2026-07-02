import Foundation

/// Which side of a conversation a piece of transcript came from.
enum Speaker: String, Codable, Sendable {
    case me = "Me"
    case them = "Them"
}

/// A single event emitted by a Transcriber: either a volatile (in-progress)
/// hypothesis or a finalized segment.
struct TranscriptEvent: Sendable {
    let channel: Speaker
    let text: String
    let isFinal: Bool
    /// Seconds from the start of the audio stream, when available.
    let audioStart: TimeInterval?
    let audioEnd: TimeInterval?
    let wallClock: Date

    init(channel: Speaker, text: String, isFinal: Bool,
         audioStart: TimeInterval? = nil, audioEnd: TimeInterval? = nil,
         wallClock: Date = Date()) {
        self.channel = channel
        self.text = text
        self.isFinal = isFinal
        self.audioStart = audioStart
        self.audioEnd = audioEnd
        self.wallClock = wallClock
    }
}

/// An ordered, merged unit of finalized speech shown in a meeting transcript.
struct Utterance: Identifiable, Sendable, Equatable {
    let id: UUID
    var speaker: Speaker
    var text: String
    var start: Date
    var end: Date

    init(id: UUID = UUID(), speaker: Speaker, text: String, start: Date, end: Date) {
        self.id = id
        self.speaker = speaker
        self.text = text
        self.start = start
        self.end = end
    }
}

/// A saved dictation, as stored in the SQLite history.
struct DictationRecord: Identifiable, Sendable, Equatable {
    let id: Int64
    let timestamp: Date
    let rawText: String
    let cleanedText: String
    let appBundleID: String?
    let durationMs: Int
    let pasteOK: Bool
}

/// Lightweight metadata for a meeting note markdown file on disk.
struct MeetingNoteMeta: Identifiable, Sendable, Equatable {
    /// Filename (unique within the notes folder).
    let id: String
    let url: URL
    let title: String
    let date: Date
    let durationSeconds: Int
    let hasSummary: Bool
}
