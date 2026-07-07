import Foundation

/// Task priority, mapped from the Obsidian Tasks glyphs. Highest/lowest fold
/// into high/low — v1 is a three-level model.
enum TaskPriority: String, Equatable, Sendable, CaseIterable {
    case high, medium, low

    /// Sort weight: higher is more urgent.
    var weight: Int { switch self { case .high: 3; case .medium: 2; case .low: 1 } }
}

/// One parsed markdown task line in Obsidian Tasks format. `text` keeps inline
/// `#tags` (Obsidian renders them in place) but strips the emoji metadata;
/// `project` surfaces the first tag for grouping. `due` is the raw ISO string
/// as written (`yyyy-MM-dd`) — kept string-pure here so this layer needs no
/// calendar/timezone; the index converts it to a Date.
struct ParsedTaskLine: Equatable, Sendable {
    var text: String
    var done: Bool
    var due: String?
    var priority: TaskPriority?
    var recurrence: String?
    var project: String?
    var id: String?
    var sourceLine: String
}

/// Pure parse/format for a single Obsidian-Tasks markdown line. No I/O, no
/// actor isolation — the foundation of the Tasks feature, unit-tested offline.
enum TaskLine {
    static let dueGlyph = "📅"
    static let recurGlyph = "🔁"
    static let idGlyph = "🆔"

    /// Obsidian Tasks priority glyphs, checked in this order. 🔺 highest and
    /// ⏬ lowest fold into high/low.
    static let priorityGlyphs: [(glyph: String, priority: TaskPriority)] = [
        ("🔺", .high), ("⏫", .high), ("🔼", .medium), ("🔽", .low), ("⏬", .low),
    ]

    /// Parse a `- [ ]` / `- [x]` checkbox task line. Returns nil for anything
    /// that is not a checkbox (plain bullets and prose are not tasks).
    static func parse(_ line: String) -> ParsedTaskLine? {
        let t = line.trimmingCharacters(in: .whitespaces)
        var done = false
        var body: String
        if t.hasPrefix("- [x]") || t.hasPrefix("- [X]") {
            done = true; body = String(t.dropFirst(5))
        } else if t.hasPrefix("- [ ]") {
            body = String(t.dropFirst(5))
        } else {
            return nil
        }
        body = body.trimmingCharacters(in: .whitespaces)

        var due: String?, recurrence: String?, id: String?, priority: TaskPriority?
        // Single-token metadata first (id, due), so the recurrence phrase only
        // has to stop at a trailing #tag or the end.
        if let (val, rest) = extractToken(body, glyph: idGlyph)  { id = val;  body = rest }
        if let (val, rest) = extractToken(body, glyph: dueGlyph) { due = val; body = rest }
        for (glyph, p) in priorityGlyphs {
            if let r = body.range(of: glyph) { priority = p; body.removeSubrange(r); break }
        }
        if let (val, rest) = extractPhrase(body, glyph: recurGlyph) { recurrence = val; body = rest }

        let text = body.split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ")
        guard !text.isEmpty else { return nil }
        return ParsedTaskLine(text: text, done: done, due: due, priority: priority,
                              recurrence: recurrence, project: firstTag(in: text),
                              id: id, sourceLine: line)
    }

    /// Value = first whitespace-delimited token after `glyph`; removes the
    /// `glyph … token` span. For 📅 / 🆔.
    private static func extractToken(_ body: String, glyph: String) -> (value: String, remainder: String)? {
        guard let gr = body.range(of: glyph) else { return nil }
        var i = gr.upperBound
        while i < body.endIndex, body[i] == " " { i = body.index(after: i) }
        let start = i
        while i < body.endIndex, body[i] != " " { i = body.index(after: i) }
        let token = String(body[start..<i])
        guard !token.isEmpty else { return nil }
        var remainder = body
        remainder.removeSubrange(gr.lowerBound..<i)
        return (token, remainder)
    }

    /// Value = phrase after `glyph` up to the next `#tag` or end (recurrence is
    /// multi-word). Assumes single-token metadata was already stripped.
    private static func extractPhrase(_ body: String, glyph: String) -> (value: String, remainder: String)? {
        guard let gr = body.range(of: glyph) else { return nil }
        var i = gr.upperBound
        while i < body.endIndex, body[i] == " " { i = body.index(after: i) }
        let start = i
        while i < body.endIndex, body[i] != "#" { i = body.index(after: i) }
        let phrase = String(body[start..<i]).trimmingCharacters(in: .whitespaces)
        guard !phrase.isEmpty else { return nil }
        var remainder = body
        remainder.removeSubrange(gr.lowerBound..<i)
        return (phrase, remainder)
    }

    private static func firstTag(in text: String) -> String? {
        for token in text.split(separator: " ") where token.hasPrefix("#") && token.count > 1 {
            return String(token.dropFirst())
        }
        return nil
    }

    /// Render a canonical task line:
    /// `- [ ] text 📅 due <prio> 🔁 recurrence 🆔 id` (absent fields omitted).
    /// `#tags` are expected to already live inside `text`.
    static func format(text: String, done: Bool, due: String? = nil,
                       priority: TaskPriority? = nil, recurrence: String? = nil,
                       id: String? = nil) -> String {
        var s = "- [\(done ? "x" : " ")] " + text.trimmingCharacters(in: .whitespaces)
        if let due { s += " \(dueGlyph) \(due)" }
        if let priority { s += " \(glyph(for: priority))" }
        if let recurrence { s += " \(recurGlyph) \(recurrence)" }
        if let id { s += " \(idGlyph) \(id)" }
        return s
    }

    private static func glyph(for p: TaskPriority) -> String {
        switch p { case .high: "⏫"; case .medium: "🔼"; case .low: "🔽" }
    }
}
