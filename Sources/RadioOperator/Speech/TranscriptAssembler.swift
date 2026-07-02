import Foundation

/// Merges two channels of transcript events (mic = `.me`, system audio = `.them`)
/// into a single, ordered meeting transcript.
///
/// This type is deliberately not an actor and not `Sendable`: it holds no locks
/// and performs no async work. The caller is responsible for serializing access.
final class TranscriptAssembler {

    /// Maximum gap (in seconds) between a preceding utterance's end and a new
    /// final's start for the two to be merged into one utterance (same speaker only).
    var mergeWindow: TimeInterval

    /// When enabled, drops `me` finals that look like echoes of nearby `them`
    /// utterances (e.g. the mic picking up meeting audio played through speakers).
    var echoGuard: Bool

    /// The merged transcript so far, kept sorted by `start`.
    private(set) var utterances: [Utterance] = []

    /// Current in-progress hypothesis for the mic channel; "" when none.
    private(set) var volatileMe: String = ""

    /// Current in-progress hypothesis for the system-audio channel; "" when none.
    private(set) var volatileThem: String = ""

    init(mergeWindow: TimeInterval = 2.0, echoGuard: Bool = false) {
        self.mergeWindow = mergeWindow
        self.echoGuard = echoGuard
    }

    func ingest(_ event: TranscriptEvent) {
        guard event.isFinal else {
            // Volatiles replace, never append. Empty text clears the hypothesis.
            setVolatile(event.text, for: event.channel)
            return
        }

        // A final always supersedes the channel's in-progress hypothesis.
        setVolatile("", for: event.channel)

        let text = event.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        let end = event.wallClock
        let start: Date
        if let audioStart = event.audioStart, let audioEnd = event.audioEnd {
            start = end.addingTimeInterval(-(audioEnd - audioStart))
        } else {
            start = end
        }

        if echoGuard, event.channel == .me,
           isLikelyEcho(meText: text, start: start, end: end) {
            return
        }

        insert(Utterance(speaker: event.channel, text: text, start: start, end: end))
    }

    /// Clears volatiles and returns the final utterance list.
    func finish() -> [Utterance] {
        volatileMe = ""
        volatileThem = ""
        return utterances
    }

    func reset() {
        utterances = []
        volatileMe = ""
        volatileThem = ""
    }

    // MARK: - Private

    private func setVolatile(_ text: String, for channel: Speaker) {
        switch channel {
        case .me:
            volatileMe = text
        case .them:
            volatileThem = text
        }
    }

    private func insert(_ new: Utterance) {
        // Stable start-order: land after every existing utterance whose start is
        // <= the new start, so equal starts keep arrival order.
        let index = utterances.firstIndex { $0.start > new.start } ?? utterances.count

        // Merge with the utterance that precedes the insertion point when it has
        // the same speaker and the gap is within the merge window. Overlapping
        // ranges (negative gap) merge as well.
        if index > 0 {
            let previous = utterances[index - 1]
            if previous.speaker == new.speaker,
               new.start.timeIntervalSince(previous.end) <= mergeWindow {
                utterances[index - 1].text += " " + new.text
                utterances[index - 1].end = max(previous.end, new.end)
                return
            }
        }

        utterances.insert(new, at: index)
    }

    // MARK: - Echo guard

    /// How far (seconds) a `them` utterance's time range may sit from the `me`
    /// final's range and still be considered for echo comparison.
    private static let echoOverlapSlack: TimeInterval = 3.0

    /// Minimum normalized length (of the shorter, i.e. matched, text) for a
    /// substring match to count as an echo.
    private static let echoMinimumLength = 12

    private func isLikelyEcho(meText: String, start: Date, end: Date) -> Bool {
        let me = Self.normalizeForEchoComparison(meText)
        guard !me.isEmpty else { return false }

        let windowStart = start.addingTimeInterval(-Self.echoOverlapSlack)
        let windowEnd = end.addingTimeInterval(Self.echoOverlapSlack)

        for utterance in utterances where utterance.speaker == .them {
            guard utterance.start <= windowEnd, utterance.end >= windowStart else {
                continue
            }
            let them = Self.normalizeForEchoComparison(utterance.text)
            guard min(me.count, them.count) >= Self.echoMinimumLength else {
                continue
            }
            if them.contains(me) || me.contains(them) {
                return true
            }
        }
        return false
    }

    /// Lowercases, strips punctuation, and collapses whitespace runs to single spaces.
    private static func normalizeForEchoComparison(_ text: String) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in text.lowercased().unicodeScalars
        where !CharacterSet.punctuationCharacters.contains(scalar) {
            scalars.append(scalar)
        }
        return String(scalars)
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }
}
