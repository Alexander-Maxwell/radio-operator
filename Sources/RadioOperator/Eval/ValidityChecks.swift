import Foundation

/// Output-validity checks V1-V5 (spec §1.7). V6-V8 are phase-gated later and
/// intentionally absent. Pure and sync: no I/O, no engine coupling. Foreign
/// files (no valid Radio Operator frontmatter) are excluded from grading:
/// every check returns applicable=false so `ValidityResult.pass` stays true.
enum ValidityChecks {

    static func check(markdown: String, note: HypNote) -> ValidityResult {
        guard note.isMeetingNote else {
            let detail = "not a meeting note (frontmatter absent or source != Radio Operator); excluded"
            return ValidityResult(checks: (1...5).map {
                ValidityResult.Check(id: "V\($0)", applicable: false, pass: true, detail: detail)
            })
        }
        let lines = markdown.components(separatedBy: "\n")
        let status = note.frontmatter["summary"] ?? ""
        return ValidityResult(checks: [
            v1Frontmatter(note),
            v2StatusSemantics(status: status, lines: lines),
            v3SingleBlock(headings: note.headings, status: status),
            v4TranscriptGrammar(lines: lines),
            v5ActionCheckboxes(lines: lines),
        ])
    }

    // MARK: - V1 frontmatter schema

    private static func v1Frontmatter(_ note: HypNote) -> ValidityResult.Check {
        let fm = note.frontmatter
        var fails: [String] = []
        if (fm["title"] ?? "").trimmingCharacters(in: .whitespaces).isEmpty {
            fails.append("title empty")
        }
        if !isISO8601WithZone(fm["date"] ?? "") {
            fails.append("date not ISO-8601 with Z/offset")
        }
        let duration = Int((fm["duration_seconds"] ?? "").trimmingCharacters(in: .whitespaces))
        if duration == nil || duration! <= 0 {
            fails.append("duration_seconds not int > 0")
        }
        // Vacuous behind isMeetingNote; kept so V1 stands alone if that gate moves.
        if fm["source"] != "Radio Operator" {
            fails.append("source != Radio Operator")
        }
        if !tagList(fm["tags"] ?? "").contains("meeting") {
            fails.append("tags missing meeting")
        }
        if !["pending", "done", "failed"].contains(fm["summary"] ?? "") {
            fails.append("summary not in pending|done|failed")
        }
        return ValidityResult.Check(id: "V1", applicable: true, pass: fails.isEmpty,
                                    detail: failDetail(fails))
    }

    /// Zone is required: "2026-07-06T12:00:00" (no Z/offset) must fail.
    private static func isISO8601WithZone(_ s: String) -> Bool {
        let plain = ISO8601DateFormatter()   // .withInternetDateTime default
        if plain.date(from: s) != nil { return true }
        let frac = ISO8601DateFormatter()
        frac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return frac.date(from: s) != nil
    }

    /// Frontmatter keeps bracket lists raw ("[meeting, work]"); items may be quoted.
    private static func tagList(_ raw: String) -> [String] {
        var s = raw.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("["), s.hasSuffix("]") { s = String(s.dropFirst().dropLast()) }
        return s.split(separator: ",").map {
            var t = $0.trimmingCharacters(in: .whitespaces)
            if t.count >= 2,
               (t.hasPrefix("\"") && t.hasSuffix("\"")) || (t.hasPrefix("'") && t.hasSuffix("'")) {
                t = String(t.dropFirst().dropLast())
            }
            return t
        }
    }

    // MARK: - V2 status semantics (by meaning)

    private static func v2StatusSemantics(status: String, lines: [String]) -> ValidityResult.Check {
        let names = ["Summary", "Decisions", "Action Items"]
        switch status {
        case "done":
            var missing: [String] = []
            var empty: [String] = []
            for name in names {
                guard let sec = sectionLines(lines, name) else { missing.append(name); continue }
                // "- None" is a bullet line, so an explicit None satisfies "rendered".
                if bulletCount(sec) == 0 { empty.append(name) }
            }
            var fails: [String] = []
            if !missing.isEmpty { fails.append("done but missing: \(missing.joined(separator: ", "))") }
            if !empty.isEmpty { fails.append("done but no bullets/None in: \(empty.joined(separator: ", "))") }
            return ValidityResult.Check(id: "V2", applicable: true, pass: fails.isEmpty,
                                        detail: failDetail(fails))
        case "pending", "failed":
            // The "> ⏳" pending marker is a blockquote, never a bullet, so it is allowed.
            let rendered = names.filter { name in
                sectionLines(lines, name).map { bulletCount($0) > 0 } ?? false
            }
            return ValidityResult.Check(id: "V2", applicable: true, pass: rendered.isEmpty,
                                        detail: rendered.isEmpty ? "ok"
                                            : "\(status) but rendered bullets in: \(rendered.joined(separator: ", "))")
        default:
            // Invalid status is V1's failure; V2 semantics are undefined there.
            return ValidityResult.Check(id: "V2", applicable: true, pass: true,
                                        detail: "status \"\(status)\" unrecognized; graded by V1")
        }
    }

    // MARK: - V3 single block, fixed relative order

    /// Duplicates and ordering are unconditional; PRESENCE of the summary trio
    /// is required only when summary == done (a pending note legitimately has
    /// no Summary/Decisions/Action Items yet, and V2 owns that semantic).
    /// ## Transcript is required always. ## My Notes may interleave.
    private static func v3SingleBlock(headings: [String], status: String) -> ValidityResult.Check {
        let order = ["Summary", "Decisions", "Action Items", "Transcript"]
        var fails: [String] = []
        for name in order {
            let count = headings.filter { $0 == name }.count
            if count > 1 { fails.append("\(name) appears \(count)x") }
        }
        if !headings.contains("Transcript") { fails.append("Transcript missing") }
        if status == "done" {
            for name in ["Summary", "Decisions", "Action Items"] where !headings.contains(name) {
                fails.append("\(name) missing (summary: done)")
            }
        }
        let firstIndices = order.compactMap { name in headings.firstIndex(of: name) }
        if firstIndices != firstIndices.sorted() { fails.append("sections out of order") }
        return ValidityResult.Check(id: "V3", applicable: true, pass: fails.isEmpty,
                                    detail: failDetail(fails))
    }

    // MARK: - V4 transcript grammar + monotonic timestamps

    private static func v4TranscriptGrammar(lines: [String]) -> ValidityResult.Check {
        guard let sec = sectionLines(lines, "Transcript") else {
            return ValidityResult.Check(id: "V4", applicable: true, pass: true,
                                        detail: "no Transcript section (V3 reports)")
        }
        guard let regex = try? NSRegularExpression(
            pattern: #"^\*\*([^*]+)\*\* _\((\d{2}):(\d{2}):(\d{2})\)_:( .*)?$"#, options: []) else {
            return ValidityResult.Check(id: "V4", applicable: true, pass: false,
                                        detail: "turn regex failed to compile")
        }
        // v1 emits exactly two stream labels; anything else ("Bob", "me") is a
        // grammar violation. Roster-based aliasing of display names arrives
        // with the 3+-party phase and will relax this to the roster set.
        let allowedSpeakers: Set<String> = ["Me", "Them"]
        var fails: [String] = []
        var prevAbs: Int?
        var rolledOver = false   // one midnight rollover allowed (spec §1.9)
        var turns = 0
        for raw in sec {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if line.hasPrefix(">") { continue }   // "> ⏳" pending / "> ⚠️" degraded banners
            if line.hasPrefix("_") { continue }   // italic markers, e.g. "_No speech captured._"
            if line.hasPrefix("*") && !line.hasPrefix("**") { continue } // "*Participants: ...*"
            let range = NSRange(line.startIndex..<line.endIndex, in: line)
            guard let m = regex.firstMatch(in: line, options: [], range: range),
                  let speakerRange = Range(m.range(at: 1), in: line),
                  let h = intGroup(m, 2, line),
                  let mi = intGroup(m, 3, line),
                  let s = intGroup(m, 4, line) else {
                fails.append("bad turn line: \(snippet(line))")
                continue
            }
            guard allowedSpeakers.contains(String(line[speakerRange])) else {
                fails.append("unknown speaker token: \(snippet(line))")
                continue
            }
            guard h < 24, mi < 60, s < 60 else {
                fails.append("invalid clock time: \(snippet(line))")
                continue
            }
            turns += 1
            var abs = h * 3600 + mi * 60 + s + (rolledOver ? 86_400 : 0)
            if let prev = prevAbs, abs < prev {
                if prev - abs > 12 * 3600, !rolledOver {
                    rolledOver = true
                    abs += 86_400
                } else {
                    fails.append("non-monotonic timestamp: \(snippet(line))")
                }
            }
            prevAbs = max(prevAbs ?? abs, abs)
        }
        return ValidityResult.Check(id: "V4", applicable: true, pass: fails.isEmpty,
                                    detail: fails.isEmpty ? "ok (\(turns) turn lines)" : failDetail(fails))
    }

    private static func intGroup(_ m: NSTextCheckingResult, _ i: Int, _ line: String) -> Int? {
        guard let r = Range(m.range(at: i), in: line) else { return nil }
        return Int(line[r])
    }

    // MARK: - V5 action items are checkboxes

    private static func v5ActionCheckboxes(lines: [String]) -> ValidityResult.Check {
        guard let sec = sectionLines(lines, "Action Items") else {
            return ValidityResult.Check(id: "V5", applicable: true, pass: true,
                                        detail: "no Action Items section (V2/V3 report)")
        }
        var fails: [String] = []
        var items = 0
        for raw in sec {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("- ") else { continue }   // only bullets are items
            items += 1
            if line == "- None" { continue }               // exact placeholder allowed
            if isCheckbox(line) { continue }
            fails.append("non-checkbox item: \(snippet(line))")
        }
        return ValidityResult.Check(id: "V5", applicable: true, pass: fails.isEmpty,
                                    detail: fails.isEmpty ? "ok (\(items) items)" : failDetail(fails))
    }

    private static func isCheckbox(_ line: String) -> Bool {
        for prefix in ["- [ ]", "- [x]", "- [X]"] {
            if line == prefix || line.hasPrefix(prefix + " ") { return true }
        }
        return false
    }

    // MARK: - Section scanning

    /// Body lines of the FIRST `## <title>` section, up to the next H2.
    /// Duplicate headings are V3's finding, not a parse concern here.
    private static func sectionLines(_ lines: [String], _ title: String) -> [String]? {
        guard let start = lines.firstIndex(where: { isHeading($0, title) }) else { return nil }
        var out: [String] = []
        for line in lines[(start + 1)...] {
            if line.hasPrefix("## ") { break }
            out.append(line)
        }
        return out
    }

    private static func isHeading(_ line: String, _ title: String) -> Bool {
        line.hasPrefix("## ") && line.dropFirst(3).trimmingCharacters(in: .whitespaces) == title
    }

    private static func bulletCount(_ sectionLines: [String]) -> Int {
        sectionLines.filter { $0.trimmingCharacters(in: .whitespaces).hasPrefix("- ") }.count
    }

    // MARK: - Detail formatting

    private static func failDetail(_ fails: [String]) -> String {
        if fails.isEmpty { return "ok" }
        let shown = fails.prefix(3).joined(separator: "; ")
        return fails.count > 3 ? "\(shown) (+\(fails.count - 3) more)" : shown
    }

    private static func snippet(_ line: String) -> String {
        line.count <= 60 ? line : String(line.prefix(57)) + "..."
    }
}
