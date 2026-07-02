import Foundation

/// Reads and writes meeting notes as plain markdown files with YAML
/// frontmatter, in an Obsidian-compatible folder the user owns.
///
/// Layout: `<notesFolder>/Meetings/YYYY-MM-DD-HHmm <title>.md`
/// Audio (optional): `<notesFolder>/Audio/<same-stem>.m4a`
@MainActor
final class NotesStore {
    static let shared = NotesStore()

    static let summaryPendingMarker = "> ⏳ Summary pending — open Radio Operator Library to retry."

    var meetingsFolder: URL {
        let url = SettingsStore.shared.notesFolderURL.appendingPathComponent("Meetings", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    var audioFolder: URL {
        let url = SettingsStore.shared.notesFolderURL.appendingPathComponent("Audio", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Writes a fresh meeting note containing the transcript and a pending-summary
    /// marker. Returns the file URL.
    func writeMeetingNote(title: String, start: Date, durationSeconds: Int,
                          utterances: [Utterance], degradedMicOnly: Bool) -> URL {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd-HHmm"
        let stamp = df.string(from: start)
        let safeTitle = NotesStore.sanitizeFilename(title.isEmpty ? "Meeting" : title)
        var url = meetingsFolder.appendingPathComponent("\(stamp) \(safeTitle).md")
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = meetingsFolder.appendingPathComponent("\(stamp) \(safeTitle) \(n).md")
            n += 1
        }
        let content = NotesStore.renderNote(
            title: title, start: start, durationSeconds: durationSeconds,
            summaryMarkdown: NotesStore.summaryPendingMarker,
            utterances: utterances, degradedMicOnly: degradedMicOnly)
        try? content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// Replaces the pending marker (or previous summary section) with a fresh summary.
    func updateSummary(noteURL: URL, summaryMarkdown: String) {
        guard var content = try? String(contentsOf: noteURL, encoding: .utf8) else { return }
        if let transcriptRange = content.range(of: "\n## Transcript") {
            // Everything between frontmatter/title and "## Transcript" is the summary zone.
            if let headerEnd = content.range(of: "\n\n", range: content.startIndex..<transcriptRange.lowerBound,
                                             locale: nil) {
                // Find end of the H1 title line to preserve frontmatter + title.
                if let titleLine = content.range(of: "\n# ", range: content.startIndex..<transcriptRange.lowerBound),
                   let titleEnd = content[titleLine.upperBound...].firstIndex(of: "\n") {
                    let prefix = String(content[content.startIndex...titleEnd])
                    let suffix = String(content[transcriptRange.lowerBound...])
                    content = prefix + "\n" + summaryMarkdown.trimmingCharacters(in: .whitespacesAndNewlines) + "\n" + suffix
                } else {
                    _ = headerEnd
                    content = content.replacingOccurrences(of: NotesStore.summaryPendingMarker,
                                                           with: summaryMarkdown)
                }
            } else {
                content = content.replacingOccurrences(of: NotesStore.summaryPendingMarker,
                                                       with: summaryMarkdown)
            }
        } else {
            content += "\n\n" + summaryMarkdown
        }
        content = content.replacingOccurrences(of: "summary: pending", with: "summary: done")
        try? content.write(to: noteURL, atomically: true, encoding: .utf8)
    }

    func listMeetings() -> [MeetingNoteMeta] {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: meetingsFolder, includingPropertiesForKeys: [.contentModificationDateKey])
        else { return [] }
        var metas: [MeetingNoteMeta] = []
        for url in files where url.pathExtension == "md" {
            guard let content = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let fm = NotesStore.parseFrontmatter(content)
            let df = ISO8601DateFormatter()
            let date = fm["date"].flatMap { df.date(from: $0) }
                ?? (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
                ?? Date.distantPast
            metas.append(MeetingNoteMeta(
                id: url.lastPathComponent,
                url: url,
                title: fm["title"] ?? url.deletingPathExtension().lastPathComponent,
                date: date,
                durationSeconds: fm["duration_seconds"].flatMap(Int.init) ?? 0,
                hasSummary: (fm["summary"] ?? "pending") == "done"
            ))
        }
        return metas.sorted { $0.date > $1.date }
    }

    func read(noteURL: URL) -> String? {
        try? String(contentsOf: noteURL, encoding: .utf8)
    }

    // MARK: - Rendering / parsing (pure helpers)

    nonisolated static func renderNote(title: String, start: Date, durationSeconds: Int,
                                       summaryMarkdown: String, utterances: [Utterance],
                                       degradedMicOnly: Bool) -> String {
        let iso = ISO8601DateFormatter()
        let tf = DateFormatter()
        tf.dateFormat = "HH:mm:ss"
        var lines: [String] = []
        lines.append("---")
        lines.append("title: \(title.isEmpty ? "Meeting" : title)")
        lines.append("date: \(iso.string(from: start))")
        lines.append("duration_seconds: \(durationSeconds)")
        lines.append("summary: pending")
        lines.append("source: Radio Operator")
        lines.append("tags: [meeting]")
        lines.append("---")
        lines.append("")
        lines.append("# \(title.isEmpty ? "Meeting" : title)")
        lines.append("")
        lines.append(summaryMarkdown)
        lines.append("")
        lines.append("## Transcript")
        lines.append("")
        if degradedMicOnly {
            lines.append("> ⚠️ System audio capture was unavailable — this transcript is microphone-only.")
            lines.append("")
        }
        if utterances.isEmpty {
            lines.append("_No speech captured._")
        }
        for u in utterances {
            lines.append("**\(u.speaker.rawValue)** _(\(tf.string(from: u.start)))_: \(u.text)")
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    nonisolated static func parseFrontmatter(_ content: String) -> [String: String] {
        var out: [String: String] = [:]
        guard content.hasPrefix("---") else { return out }
        let lines = content.components(separatedBy: "\n")
        for line in lines.dropFirst() {
            if line.hasPrefix("---") { break }
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            out[key] = value
        }
        return out
    }

    nonisolated static func sanitizeFilename(_ s: String) -> String {
        let bad = CharacterSet(charactersIn: "/\\:?%*|\"<>#")
        let cleaned = s.components(separatedBy: bad).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return String(cleaned.prefix(60))
    }
}
