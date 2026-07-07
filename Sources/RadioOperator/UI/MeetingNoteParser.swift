import Foundation

/// Pure markdown parsing for meeting notes: structured sections (summary,
/// decisions, action items, follow-ups, my notes) plus the speaker-attributed
/// transcript. Notes are user-editable (templates can rename headings), so
/// section matching is case-insensitive and by-keyword, never positional.
/// No I/O, no actor isolation — testable and callable off the MainActor.
enum MeetingNoteParser {

    /// One `- [ ]` / `- [x]` task line. `sourceLine` is the exact original
    /// line (untrimmed) so checkbox toggles can rewrite it in place.
    struct ActionItem: Equatable, Sendable {
        let text: String
        let done: Bool
        /// Trailing "— owner, due" tag when present.
        let meta: String?
        let sourceLine: String
    }

    /// One transcript line: `**Me** _(HH:mm:ss)_: text`. `time` is wall-clock.
    struct Turn: Equatable, Sendable {
        let speaker: Speaker
        let time: String
        let text: String
    }

    struct Note: Equatable, Sendable {
        var summaryLines: [String] = []
        var decisions: [String] = []
        var actionItems: [ActionItem] = []
        var followUps: [String] = []
        var myNotes: String? = nil
        var turns: [Turn] = []
        /// True when the mic-only degradation marker is present.
        var micOnly = false
        /// True when the summary-pending marker is still in the note.
        var pending = false

        var summaryText: String { summaryLines.joined(separator: "\n") }

        /// Plain-text summary for list cards: bold markers stripped, one line.
        var excerpt: String {
            summaryLines.joined(separator: " ")
                .replacingOccurrences(of: "**", with: "")
                .replacingOccurrences(of: "__", with: "")
        }

        var hasThem: Bool { turns.contains { $0.speaker == .them } }
        var speakerCount: Int { Set(turns.map(\.speaker)).count }
    }

    // MARK: - Parse

    static func parse(_ content: String) -> Note {
        var note = Note()
        let lines = content.components(separatedBy: "\n")

        // Skip YAML frontmatter.
        var i = 0
        if lines.first == "---" {
            i = 1
            while i < lines.count, !lines[i].hasPrefix("---") { i += 1 }
            i = min(i + 1, lines.count)
        }

        // Global markers (position-independent, survive edited templates).
        for line in lines[i...] {
            if line.hasPrefix("> ⏳ Summary pending") { note.pending = true }
            if line.hasPrefix(">"), line.contains("microphone-only") { note.micOnly = true }
        }

        // Prelude = lines between the H1 and the first "## " heading.
        var prelude: [String] = []
        var sections: [(name: String, lines: [String])] = []
        var currentSection: String? = nil
        var currentLines: [String] = []
        var seenH1 = false
        for line in lines[i...] {
            if line.hasPrefix("## ") {
                if let name = currentSection { sections.append((name, currentLines)) }
                currentSection = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                currentLines = []
                continue
            }
            if currentSection != nil {
                currentLines.append(line)
            } else if line.hasPrefix("# ") {
                seenH1 = true
                prelude = []
            } else if seenH1 || !line.hasPrefix("---") {
                prelude.append(line)
            }
        }
        if let name = currentSection { sections.append((name, currentLines)) }

        note.summaryLines = summaryLines(from: prelude)
        for (name, body) in sections {
            let key = name.lowercased()
            if key.contains("transcript") {
                note.turns.append(contentsOf: body.compactMap(parseTurn))
            } else if key.contains("my notes") {
                let text = body.joined(separator: "\n")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty { note.myNotes = text }
            } else if key.contains("decision") {
                note.decisions.append(contentsOf: bulletTexts(from: body))
            } else if key.contains("action") {
                note.actionItems.append(contentsOf: body.compactMap(parseActionItem))
            } else if key.contains("follow") {
                note.followUps.append(contentsOf: bulletTexts(from: body))
            } else if key.contains("summary"), note.summaryLines.isEmpty {
                note.summaryLines = summaryLines(from: body)
            }
        }

        // Renamed-beyond-recognition transcript heading: scan everything.
        if note.turns.isEmpty {
            note.turns = lines[i...].compactMap(parseTurn)
        }
        return note
    }

    // MARK: - Line parsers

    /// `**Me** _(14:03:22)_: text` → Turn. Nil for anything else.
    static func parseTurn(_ line: String) -> Turn? {
        guard line.hasPrefix("**"), let nameEnd = line.range(of: "** ") else { return nil }
        let name = String(line[line.index(line.startIndex, offsetBy: 2)..<nameEnd.lowerBound])
        guard let speaker = Speaker(rawValue: name) else { return nil }
        let rest = line[nameEnd.upperBound...]
        guard rest.hasPrefix("_("), let timeEnd = rest.range(of: ")_:") else { return nil }
        let time = String(rest[rest.index(rest.startIndex, offsetBy: 2)..<timeEnd.lowerBound])
        guard clockSeconds(time) != nil else { return nil }
        let text = String(rest[timeEnd.upperBound...]).trimmingCharacters(in: .whitespaces)
        return Turn(speaker: speaker, time: time, text: text)
    }

    /// Checkbox task line → ActionItem; plain bullets in an actions section
    /// become untoggleable not-done items (defensive against edited notes).
    static func parseActionItem(_ line: String) -> ActionItem? {
        let t = line.trimmingCharacters(in: .whitespaces)
        var body: String
        var done = false
        if t.hasPrefix("- [x]") || t.hasPrefix("- [X]") {
            done = true
            body = String(t.dropFirst(5))
        } else if t.hasPrefix("- [ ]") {
            body = String(t.dropFirst(5))
        } else if let plain = bulletText(t) {
            body = plain
        } else {
            return nil
        }
        body = body.trimmingCharacters(in: .whitespaces)
        guard !isNone(body) else { return nil }
        var meta: String? = nil
        if let sep = body.range(of: " — ", options: .backwards) {
            let tail = String(body[sep.upperBound...]).trimmingCharacters(in: .whitespaces)
            let head = String(body[..<sep.lowerBound]).trimmingCharacters(in: .whitespaces)
            if !tail.isEmpty, !head.isEmpty {
                meta = tail
                body = head
            }
        }
        guard !body.isEmpty else { return nil }
        return ActionItem(text: body, done: done, meta: meta, sourceLine: line)
    }

    // MARK: - Checkbox toggle

    /// Flips `- [ ]` ↔ `- [x]` on the first line exactly equal to `sourceLine`,
    /// leaving every other byte untouched. Nil if the line is missing or is
    /// not a checkbox.
    static func togglingCheckbox(in content: String, sourceLine: String) -> String? {
        var lines = content.components(separatedBy: "\n")
        guard let idx = lines.firstIndex(of: sourceLine) else { return nil }
        let flipped: String
        if let r = sourceLine.range(of: "- [ ]") {
            flipped = sourceLine.replacingCharacters(in: r, with: "- [x]")
        } else if let r = sourceLine.range(of: "- [x]") {
            flipped = sourceLine.replacingCharacters(in: r, with: "- [ ]")
        } else if let r = sourceLine.range(of: "- [X]") {
            flipped = sourceLine.replacingCharacters(in: r, with: "- [ ]")
        } else {
            return nil
        }
        lines[idx] = flipped
        return lines.joined(separator: "\n")
    }

    // MARK: - Timecode → player offset

    /// Seconds from the note's start to a wall-clock `HH:mm:ss` timecode.
    /// Handles meetings that cross midnight; clamps small clock skew to 0.
    static func timeOffset(clock: String, noteStart: Date,
                           calendar: Calendar = .current) -> TimeInterval? {
        guard let clockSecs = clockSeconds(clock) else { return nil }
        let c = calendar.dateComponents([.hour, .minute, .second], from: noteStart)
        let startSecs = (c.hour ?? 0) * 3600 + (c.minute ?? 0) * 60 + (c.second ?? 0)
        var offset = TimeInterval(clockSecs - startSecs)
        if offset < -43_200 { offset += 86_400 }
        return max(0, offset)
    }

    // MARK: - Helpers

    private static func clockSeconds(_ s: String) -> Int? {
        let parts = s.split(separator: ":")
        guard parts.count == 3,
              let h = Int(parts[0]), let m = Int(parts[1]), let sec = Int(parts[2]),
              (0..<24) ~= h, (0..<60) ~= m, (0..<60) ~= sec else { return nil }
        return h * 3600 + m * 60 + sec
    }

    /// Non-blank content lines with bullet prefixes and markers stripped,
    /// literal "None" entries dropped.
    private static func summaryLines(from lines: [String]) -> [String] {
        lines.compactMap { line in
            let t = line.trimmingCharacters(in: .whitespaces)
            guard !t.isEmpty, !t.hasPrefix("> ⏳"), t != "---" else { return nil }
            let text = bulletText(t) ?? t
            return isNone(text) || text.isEmpty ? nil : text
        }
    }

    private static func bulletTexts(from lines: [String]) -> [String] {
        lines.compactMap { line in
            guard var text = bulletText(line.trimmingCharacters(in: .whitespaces)) else { return nil }
            // A checkbox in a non-actions section still reads as a bullet.
            for marker in ["[ ]", "[x]", "[X]"] where text.hasPrefix(marker) {
                text = String(text.dropFirst(3)).trimmingCharacters(in: .whitespaces)
            }
            return isNone(text) || text.isEmpty ? nil : text
        }
    }

    private static func bulletText(_ trimmedLine: String) -> String? {
        for prefix in ["- ", "* "] where trimmedLine.hasPrefix(prefix) {
            return String(trimmedLine.dropFirst(prefix.count))
                .trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    private static func isNone(_ s: String) -> Bool {
        let t = s.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: " .*_"))
        return t == "none"
    }
}
