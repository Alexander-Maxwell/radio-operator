import Foundation

/// Reads and writes meeting notes as plain markdown files with YAML
/// frontmatter, in an Obsidian-compatible folder the user owns.
///
/// Layout: `<notesFolder>/Meetings/YYYY-MM-DD-HHmm <title>.md`
/// Audio (optional): `<notesFolder>/Audio/<same-stem>.m4a`
@MainActor
final class NotesStore {
    static let shared = NotesStore()

    nonisolated static let summaryPendingMarker = "> ⏳ Summary pending — open Radio Operator Library to retry."

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

    var dictationsFolder: URL {
        let url = SettingsStore.shared.notesFolderURL.appendingPathComponent("Dictations", isDirectory: true)
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
        guard let content = try? String(contentsOf: noteURL, encoding: .utf8) else { return }
        try? NotesStore.replacedSummary(in: content, with: summaryMarkdown)
            .write(to: noteURL, atomically: true, encoding: .utf8)
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

    /// Rewrites the note's title (frontmatter + H1) and renames the file —
    /// and any retained audio sharing its stem — to match. Returns the new URL.
    func retitleNote(noteURL: URL, title: String) -> URL {
        NotesStore.performRetitle(noteURL: noteURL, title: title, audioFolder: audioFolder)
    }

    /// Appends a dictation to today's markdown log so Ask's CLI grep can see it.
    func appendDictation(text: String, appName: String?, date: Date = Date()) {
        NotesStore.appendDictation(text: text, appName: appName, date: date, folder: dictationsFolder)
    }

    // MARK: - Retitle / dictation-log helpers (pure-ish, testable)

    /// Swaps the frontmatter `title:` line and the first H1 for the new title.
    nonisolated static func retitledContent(_ content: String, title: String) -> String {
        var lines = content.components(separatedBy: "\n")
        var inFrontmatter = false
        var frontmatterDone = false
        var replacedH1 = false
        for i in lines.indices {
            let line = lines[i]
            if i == 0, line == "---" {
                inFrontmatter = true
                continue
            }
            if inFrontmatter, !frontmatterDone {
                if line.hasPrefix("---") {
                    frontmatterDone = true
                } else if line.hasPrefix("title:") {
                    lines[i] = "title: \(title)"
                }
                continue
            }
            if !replacedH1, line.hasPrefix("# ") {
                lines[i] = "# \(title)"
                replacedH1 = true
            }
        }
        return lines.joined(separator: "\n")
    }

    /// New filename stem: preserves a leading `YYYY-MM-DD-HHmm ` stamp when present.
    nonisolated static func retitledFilename(currentStem: String, title: String) -> String {
        let safe = sanitizeFilename(title.isEmpty ? "Meeting" : title)
        if let re = try? NSRegularExpression(pattern: "^\\d{4}-\\d{2}-\\d{2}-\\d{4} "),
           let m = re.firstMatch(in: currentStem, range: NSRange(currentStem.startIndex..., in: currentStem)),
           let r = Range(m.range, in: currentStem) {
            return String(currentStem[r]) + safe
        }
        return safe
    }

    /// Rewrites title in place, renames the note file (collision-safe), and
    /// moves audio files sharing the old stem. Returns the new URL, or the
    /// original on any failure.
    nonisolated static func performRetitle(noteURL: URL, title: String, audioFolder: URL) -> URL {
        let fm = FileManager.default
        guard let content = try? String(contentsOf: noteURL, encoding: .utf8) else { return noteURL }
        try? retitledContent(content, title: title).write(to: noteURL, atomically: true, encoding: .utf8)

        let oldStem = noteURL.deletingPathExtension().lastPathComponent
        let newStem = retitledFilename(currentStem: oldStem, title: title)
        guard newStem != oldStem else { return noteURL }

        let dir = noteURL.deletingLastPathComponent()
        var target = dir.appendingPathComponent("\(newStem).md")
        var n = 2
        while fm.fileExists(atPath: target.path) {
            target = dir.appendingPathComponent("\(newStem) \(n).md")
            n += 1
        }
        do {
            try fm.moveItem(at: noteURL, to: target)
        } catch {
            return noteURL
        }

        // Retained audio pairs by stem: "<stem> - me.m4a" / "<stem> - them.m4a".
        let finalStem = target.deletingPathExtension().lastPathComponent
        if let audioFiles = try? fm.contentsOfDirectory(at: audioFolder, includingPropertiesForKeys: nil) {
            for f in audioFiles where f.lastPathComponent.hasPrefix("\(oldStem) - ") {
                let suffix = String(f.lastPathComponent.dropFirst(oldStem.count))
                try? fm.moveItem(at: f, to: audioFolder.appendingPathComponent(finalStem + suffix))
            }
        }
        return target
    }

    /// Replaces the summary zone (pending marker or previous summary) while
    /// preserving frontmatter, H1, "## My Notes", and the transcript.
    nonisolated static func replacedSummary(in content: String, with summaryMarkdown: String) -> String {
        var out = content
        let anchor = out.range(of: "\n## My Notes") ?? out.range(of: "\n## Transcript")
        if let anchor {
            if let titleLine = out.range(of: "\n# ", range: out.startIndex..<anchor.lowerBound),
               let titleEnd = out[titleLine.upperBound...].firstIndex(of: "\n") {
                let prefix = String(out[out.startIndex...titleEnd])
                let suffix = String(out[anchor.lowerBound...])
                out = prefix + "\n" + summaryMarkdown.trimmingCharacters(in: .whitespacesAndNewlines) + "\n" + suffix
            } else {
                out = out.replacingOccurrences(of: summaryPendingMarker, with: summaryMarkdown)
            }
        } else {
            out += "\n\n" + summaryMarkdown
        }
        return out.replacingOccurrences(of: "summary: pending", with: "summary: done")
    }

    /// Extracts the "## My Notes" section body, if present.
    nonisolated static func parseUserNotes(_ content: String) -> String? {
        guard let start = content.range(of: "\n## My Notes") else { return nil }
        let after = content[start.upperBound...]
        let end = after.range(of: "\n## ")?.lowerBound ?? after.endIndex
        let body = after[..<end].trimmingCharacters(in: .whitespacesAndNewlines)
        return body.isEmpty ? nil : body
    }

    /// Appends one dictation entry to `<folder>/YYYY-MM-DD.md`.
    nonisolated static func appendDictation(text: String, appName: String?, date: Date, folder: URL) {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        let day = df.string(from: date)
        let url = folder.appendingPathComponent("\(day).md")
        let tf = DateFormatter()
        tf.dateFormat = "HH:mm"
        var entry = "- **\(tf.string(from: date))**"
        if let appName, !appName.isEmpty { entry += " (\(appName))" }
        entry += ": \(text.replacingOccurrences(of: "\n", with: "\n  "))\n"
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(entry.utf8))
        } else {
            try? ("# Dictations \(day)\n\n" + entry).write(to: url, atomically: true, encoding: .utf8)
        }
    }

    /// Deletes daily dictation logs older than `keepingDays` (by filename date).
    nonisolated static func pruneDictationLogs(in folder: URL, keepingDays: Int) {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else { return }
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        let cutoff = Calendar.current.startOfDay(for: Date())
            .addingTimeInterval(-Double(keepingDays) * 86_400)
        for f in files where f.pathExtension == "md" {
            guard let d = df.date(from: f.deletingPathExtension().lastPathComponent) else { continue }
            if d < cutoff { try? fm.removeItem(at: f) }
        }
    }

    // MARK: - Rendering / parsing (pure helpers)

    nonisolated static func renderNote(title: String, start: Date, durationSeconds: Int,
                                       summaryMarkdown: String, utterances: [Utterance],
                                       degradedMicOnly: Bool, userNotes: String = "") -> String {
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
        let notes = userNotes.trimmingCharacters(in: .whitespacesAndNewlines)
        if !notes.isEmpty {
            lines.append("## My Notes")
            lines.append("")
            lines.append(notes)
            lines.append("")
        }
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
