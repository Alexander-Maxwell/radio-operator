import Foundation

/// Markdown meeting-note parser for the eval harness (spec §0 grammar).
/// Pure string → HypNote, no I/O. Foreign files (no Radio Operator
/// frontmatter) still parse structurally, but isMeetingNote == false so the
/// harness excludes them from grading (D3 foreign-note rule).
enum EvalNoteParser {

    static func parse(markdown: String) -> HypNote {
        var lines = markdown.components(separatedBy: "\n")
        for i in lines.indices where lines[i].hasSuffix("\r") {
            lines[i].removeLast()
        }

        var frontmatter: [String: String] = [:]
        var hasFrontmatter = false
        var bodyStart = 0
        // Frontmatter must open on line 0 and close on a later bare "---";
        // an unclosed fence is treated as no frontmatter.
        if lines.first?.trimmingCharacters(in: .whitespaces) == "---",
           let close = lines.dropFirst().firstIndex(where: {
               $0.trimmingCharacters(in: .whitespaces) == "---"
           }) {
            hasFrontmatter = true
            bodyStart = close + 1
            for raw in lines[1..<close] {
                guard let colon = raw.firstIndex(of: ":") else { continue }
                let key = raw[..<colon].trimmingCharacters(in: .whitespaces)
                guard !key.isEmpty else { continue }
                var value = raw[raw.index(after: colon)...]
                    .trimmingCharacters(in: .whitespaces)
                // One level of surrounding quotes off scalars only. Bracket
                // lists (tags/attendees) start with "[" so they stay raw.
                if value.count >= 2, let f = value.first, f == value.last,
                   f == "\"" || f == "'" {
                    value = String(value.dropFirst().dropLast())
                }
                frontmatter[key] = value
            }
        }

        var headings: [String] = []
        var transcript: [HypNote.Line] = []
        var summaryBullets: [String] = []
        var decisions: [String] = []
        var actionItems: [HypNote.ActionItem] = []

        var section = ""
        var firstSod: Int?
        var prevSod: Int?
        var rolledOver = false      // single midnight rollover per spec §1.9

        for line in lines[bodyStart...] {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if line.hasPrefix("## ") {
                let title = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                headings.append(title)
                section = title
                continue
            }

            if let turn = turnMatch(line) {
                let sod = secondsOfDay(turn.timestamp)
                if firstSod == nil { firstSod = sod }
                // Rollover fires when the clock drops > 12h vs the PREVIOUS
                // line (small backwards jitter is not a rollover); once fired
                // it stays applied — one rollover per note.
                if !rolledOver, let prev = prevSod, prev - sod > 12 * 3600 {
                    rolledOver = true
                }
                let tRel = Double(sod - (firstSod ?? sod) + (rolledOver ? 86400 : 0))
                transcript.append(HypNote.Line(
                    speaker: turn.speaker, timestamp: turn.timestamp,
                    tRel: tRel, text: turn.text))
                prevSod = sod
                continue
            }

            switch section {
            case "Summary":
                if trimmed.hasPrefix("- ") {
                    summaryBullets.append(String(trimmed.dropFirst(2))
                        .trimmingCharacters(in: .whitespaces))
                }
            case "Decisions":
                if trimmed.hasPrefix("- ") {
                    decisions.append(String(trimmed.dropFirst(2))
                        .trimmingCharacters(in: .whitespaces))
                }
            case "Action Items":
                if let item = actionItem(trimmed) { actionItems.append(item) }
            case "Transcript":
                // Continuation: non-matching, non-empty line before the next
                // heading appends to the previous turn's text.
                if !trimmed.isEmpty, !transcript.isEmpty {
                    transcript[transcript.count - 1].text += " " + trimmed
                }
            default:
                break
            }
        }

        return HypNote(
            frontmatter: frontmatter,
            hasFrontmatter: hasFrontmatter,
            headings: headings,
            transcript: transcript,
            summaryBullets: summaryBullets,
            decisions: decisions,
            actionItems: actionItems,
            isMeetingNote: hasFrontmatter && frontmatter["source"] == "Radio Operator")
    }

    // MARK: - Transcript turn lines

    /// `**<speaker>** _(<HH:MM:SS>)_: <text>` — speaker token kept verbatim.
    private static let turnRegex = try! NSRegularExpression(
        pattern: #"^\*\*([^*]+)\*\* _\((\d{2}:\d{2}:\d{2})\)_: ?(.*)$"#)

    private static func turnMatch(_ line: String)
        -> (speaker: String, timestamp: String, text: String)? {
        let ns = line as NSString
        guard let m = turnRegex.firstMatch(
            in: line, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return (speaker: ns.substring(with: m.range(at: 1)),
                timestamp: ns.substring(with: m.range(at: 2)),
                text: ns.substring(with: m.range(at: 3))
                    .trimmingCharacters(in: .whitespaces))
    }

    private static func secondsOfDay(_ hms: String) -> Int {
        let p = hms.split(separator: ":").compactMap { Int($0) }
        guard p.count == 3 else { return 0 }
        return p[0] * 3600 + p[1] * 60 + p[2]
    }

    // MARK: - Action items

    /// Checkbox items only; "None" placeholders (plain or checkboxed) are
    /// dropped. Non-checkbox bullets are ignored here — flagging them is V5's
    /// job (ValidityChecks reads the raw markdown).
    private static func actionItem(_ trimmed: String) -> HypNote.ActionItem? {
        let checked: Bool
        if trimmed.hasPrefix("- [ ] ") {
            checked = false
        } else if trimmed.hasPrefix("- [x] ") || trimmed.hasPrefix("- [X] ") {
            checked = true
        } else {
            return nil
        }
        let body = String(trimmed.dropFirst(6)).trimmingCharacters(in: .whitespaces)
        if body.lowercased() == "none" { return nil }
        let (task, owner, due) = extractOwner(body)
        return HypNote.ActionItem(raw: trimmed, task: task, owner: owner,
                                  due: due, checked: checked)
    }

    /// Owner extraction per spec §0: trailing-dash suffix first, else leading
    /// `<Name> to <verb>`, else unowned. Due lives only inside the owner part
    /// (", due X" suffix).
    private static func extractOwner(_ text: String)
        -> (task: String, owner: String?, due: String?) {
        if let (task, ownerPart) = dashSplit(text) {
            let (owner, due) = splitDue(ownerPart)
            return (task, owner, due)
        }
        if let (owner, task) = leadingName(text) {
            return (task, owner, nil)
        }
        return (text, nil, nil)
    }

    /// Split on the LAST occurrence of a dash separator. The em-dash form is
    /// the app's own convention and needs no gate; " -- " and " - " count only
    /// when the owner part starts with a roster-looking capitalized word.
    /// Only the last occurrence of each separator is considered — no backtrack.
    private static func dashSplit(_ text: String) -> (task: String, ownerPart: String)? {
        for sep in [" \u{2014} ", " -- ", " - "] {
            guard let r = text.range(of: sep, options: .backwards) else { continue }
            let task = String(text[..<r.lowerBound]).trimmingCharacters(in: .whitespaces)
            let ownerPart = String(text[r.upperBound...]).trimmingCharacters(in: .whitespaces)
            guard !task.isEmpty, !ownerPart.isEmpty else { continue }
            if sep != " \u{2014} ", ownerPart.first?.isUppercase != true { continue }
            return (task, ownerPart)
        }
        return nil
    }

    private static func splitDue(_ ownerPart: String) -> (owner: String?, due: String?) {
        guard let r = ownerPart.range(of: ", due ", options: .backwards) else {
            return (stripParenthetical(ownerPart), nil)
        }
        let owner = String(ownerPart[..<r.lowerBound]).trimmingCharacters(in: .whitespaces)
        let due = String(ownerPart[r.upperBound...]).trimmingCharacters(in: .whitespaces)
        return (stripParenthetical(owner), due.isEmpty ? nil : due)
    }

    /// "Them (email already sent)" → "Them": a trailing parenthetical is a status
    /// note, not part of the owner, and would read as a phantom to RosterMap.
    private static func stripParenthetical(_ owner: String) -> String? {
        var s = owner
        if s.hasSuffix(")"), let r = s.range(of: " (", options: .backwards) {
            s = String(s[..<r.lowerBound]).trimmingCharacters(in: .whitespaces)
        }
        return s.isEmpty ? nil : s
    }

    /// `<Name> to <verb>` where Name is 1-2 capitalized words plus an optional
    /// parenthetical alias — "Maxwell (Me) to advise..." → owner "Maxwell".
    /// The parenthetical is dropped so RosterMap.resolve can match the name;
    /// the task keeps its leading "to" (a stopword downstream).
    private static let leadingNameRegex = try! NSRegularExpression(
        pattern: #"^([A-Z][A-Za-z'’-]*(?: [A-Z][A-Za-z'’-]*)?)(?: \([^)]*\))? (to [a-z].*)$"#)

    private static func leadingName(_ text: String) -> (owner: String, task: String)? {
        let ns = text as NSString
        guard let m = leadingNameRegex.firstMatch(
            in: text, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return (owner: ns.substring(with: m.range(at: 1)),
                task: ns.substring(with: m.range(at: 2)))
    }
}
