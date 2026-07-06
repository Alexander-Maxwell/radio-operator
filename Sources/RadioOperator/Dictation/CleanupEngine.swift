import Foundation

/// Pure, deterministic transcript cleanup — no LLM, no async, no state.
///
/// Pipeline per `CleanupLevel`:
///   .off      → trimmed raw
///   .light    → removeFillers → normalize
///   .standard → removeFillers → applyDictionary → expandSnippets → normalize
///
/// If a snippet trigger matches the whole utterance, its expansion is
/// returned verbatim and never normalized — the user's snippet is sacred.
enum CleanupEngine {

    // MARK: - Pipeline

    static func clean(_ raw: String, settings: SettingsData) -> String {
        switch settings.cleanupLevel {
        case .off:
            return raw.trimmingCharacters(in: .whitespacesAndNewlines)
        case .light:
            return normalize(applyCommands(removeFillers(raw)))
        case .standard:
            var text = applyCommands(removeFillers(raw))
            text = applyDictionary(text, entries: settings.dictionary)
            if let expansion = snippetExpansion(for: text, snippets: settings.snippets) {
                return expansion
            }
            return normalize(text)
        }
    }

    // MARK: - Voice commands

    /// Deterministic spoken commands: "new line" → \n, "new paragraph" → \n\n,
    /// "scratch that" deletes back through the previous clause/sentence.
    /// Article-guarded ("a new line of products" survives); like the filler
    /// pass, telling every literal use apart would need a parser, not regex.
    static func applyCommands(_ s: String) -> String {
        guard !s.isEmpty else { return s }
        var text = applyScratchThat(s)
        text = newParagraphCmd.stringByReplacingMatches(
            in: text, options: [], range: fullRange(text), withTemplate: "\n\n")
        text = newLineCmd.stringByReplacingMatches(
            in: text, options: [], range: fullRange(text), withTemplate: "\n")
        return text
    }

    /// Words that mark "new line/paragraph" as content, not command.
    private static let articleGuard =
        "(?<!\\ba )(?<!\\ban )(?<!\\bthe )(?<!\\bthis )(?<!\\bthat )(?<!\\banother )" +
        "(?<!\\beach )(?<!\\bevery )(?<!\\bany )(?<!\\bwhole )(?<!\\bentire )(?<!\\bbrand )"

    private static let newLineCmd = regex(
        ",?[ \\t]*\(articleGuard)\\bnew[ \\t]+line\\b[.,!?;:]?[ \\t]*", .caseInsensitive)
    private static let newParagraphCmd = regex(
        ",?[ \\t]*\(articleGuard)\\bnew[ \\t]+paragraph\\b[.,!?;:]?[ \\t]*", .caseInsensitive)

    private static let scratchCmd = regex("\\bscratch that\\b[.,!?;:]?[ \\t]*", .caseInsensitive)
    private static let clauseBoundaries = CharacterSet(charactersIn: ".!?,;:\n")

    /// Each "scratch that" deletes back to the previous clause boundary; when
    /// the phrase opens its own clause ("… Monday. Scratch that."), it takes
    /// the clause before that one with it.
    private static func applyScratchThat(_ s: String) -> String {
        var text = s
        while let m = scratchCmd.firstMatch(in: text, options: [], range: fullRange(text)) {
            let ns = text as NSString
            let phraseStart = m.range.location
            let phraseEnd = m.range.location + m.range.length

            func boundaryBefore(_ limit: Int) -> Int {
                var i = limit - 1
                while i >= 0 {
                    if let scalar = Unicode.Scalar(ns.character(at: i)),
                       clauseBoundaries.contains(scalar) {
                        return i + 1
                    }
                    i -= 1
                }
                return 0
            }

            let b1 = boundaryBefore(phraseStart)
            let segment = ns.substring(with: NSRange(location: b1, length: phraseStart - b1))
                .trimmingCharacters(in: .whitespaces)
            let deleteFrom = (segment.isEmpty && b1 > 0) ? boundaryBefore(b1 - 1) : b1

            let mutable = NSMutableString(string: text)
            mutable.deleteCharacters(in: NSRange(location: deleteFrom, length: phraseEnd - deleteFrom))
            text = mutable as String
        }
        return text
    }

    // MARK: - Fillers

    /// Removes standalone filler words/phrases case-insensitively at word
    /// boundaries, plus the comma/space debris they leave behind
    /// ("Hello, um, world" → "Hello, world"). "like" and "mean" survive
    /// normal use ("I like dogs"); "like" is only dropped between commas and
    /// "i mean" only when followed by a comma. Known collateral: "you know"
    /// is removed even when it is a real verb phrase ("Do you know her") —
    /// telling that apart from the discourse marker needs a parser, not regex.
    static func removeFillers(_ s: String) -> String {
        guard !s.isEmpty else { return s }
        var text = s
        // Fixed point: chained fillers (", like, like,") overlap, so a single
        // replace pass can leave a survivor.
        var previous: String
        repeat {
            previous = text
            for (re, template) in fillerPasses {
                text = re.stringByReplacingMatches(
                    in: text, options: [], range: fullRange(text), withTemplate: template)
            }
        } while text != previous
        for (re, template) in debrisPasses {
            text = re.stringByReplacingMatches(
                in: text, options: [], range: fullRange(text), withTemplate: template)
        }
        return text
    }

    /// Multi-word fillers first so shorter patterns cannot split them.
    private static let fillerPasses: [(NSRegularExpression, String)] = [
        (regex(",[ \\t]*like[ \\t]*,", .caseInsensitive), ","),  // "was, like, huge" → "was, huge"
        (regex("\\bi mean[ \\t]*,", .caseInsensitive), ""),      // marker only; "what i mean is" survives
        (regex("\\bsort of like\\b", .caseInsensitive), ""),
        (regex("\\bkind of like\\b", .caseInsensitive), ""),
        (regex("\\byou know\\b", .caseInsensitive), ""),
        (regex("\\b(?:uhm|erm|um|uh)\\b", .caseInsensitive), ""),
    ]

    /// Debris fixes double as harmless whitespace tidying when no filler fired.
    private static let debrisPasses: [(NSRegularExpression, String)] = [
        (regex("[ \\t]{2,}"), " "),                          // "should  move" → "should move"
        (regex("[ \\t]+([,.!?;:])"), "$1"),                  // "Hello ," → "Hello,"
        (regex(",(?:[ \\t]*,)+"), ","),                      // "Hello,, world" → "Hello, world"
        (regex("([.!?;:])[ \\t]*,"), "$1"),                  // "Stop., then" → "Stop. then"
        (regex("^[ \\t]*,[ \\t]*", .anchorsMatchLines), ""), // "Um, so…" left ", so…"
        (regex("^[ \\t]+", .anchorsMatchLines), ""),
        (regex("[ \\t]+$", .anchorsMatchLines), ""),
    ]

    // MARK: - Dictionary

    /// Replaces each `spoken` phrase with its `written` form, case-insensitive
    /// on word boundaries, longest spoken phrase first. Output is exactly
    /// `written` — except a `written` that begins lowercase gets its first
    /// letter uppercased when the match sits at a sentence start.
    static func applyDictionary(_ s: String, entries: [DictionaryEntry]) -> String {
        guard !s.isEmpty else { return s }
        let usable = entries.filter {
            !$0.spoken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        guard !usable.isEmpty else { return s }

        // ICU tries alternation branches in order, so ranking longest-first
        // makes "sip program" beat "sip" at the same position. Ties keep the
        // original entry order for determinism.
        let ranked = usable.enumerated()
            .sorted {
                if $0.element.spoken.count != $1.element.spoken.count {
                    return $0.element.spoken.count > $1.element.spoken.count
                }
                return $0.offset < $1.offset
            }
            .map(\.element)

        var writtenBySpoken: [String: String] = [:]
        for entry in ranked where writtenBySpoken[entry.spoken.lowercased()] == nil {
            writtenBySpoken[entry.spoken.lowercased()] = entry.written
        }

        // Built per call because it depends on user entries; the fixed
        // patterns above are precompiled statics.
        let alternation = ranked
            .map { NSRegularExpression.escapedPattern(for: $0.spoken) }
            .joined(separator: "|")
        guard let re = try? NSRegularExpression(
            pattern: "\\b(?:\(alternation))\\b", options: [.caseInsensitive]
        ) else { return s }

        let ns = s as NSString
        var out = ""
        var cursor = 0
        for match in re.matches(in: s, options: [], range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            let matched = ns.substring(with: match.range)
            var replacement = writtenBySpoken[matched.lowercased()] ?? matched
            if isSentenceStart(before: out), let first = replacement.first, first.isLowercase {
                replacement = first.uppercased() + String(replacement.dropFirst())
            }
            out += replacement
            cursor = match.range.location + match.range.length
        }
        out += ns.substring(from: cursor)
        return out
    }

    /// Sentence start = start of text, start of a line, or the previous
    /// non-space character is sentence-ending punctuation.
    private static func isSentenceStart(before prefix: String) -> Bool {
        for ch in prefix.reversed() {
            if ch == " " || ch == "\t" { continue }
            if ch == "\n" || ch == "\r" { return true }
            return ch == "." || ch == "!" || ch == "?"
        }
        return true
    }

    // MARK: - Snippets

    /// Whole-utterance triggers only: if the entire input — trimmed,
    /// lowercased, punctuation stripped — equals a trigger, the expansion
    /// replaces it verbatim. No partial or inline expansion.
    static func expandSnippets(_ s: String, snippets: [Snippet]) -> String {
        snippetExpansion(for: s, snippets: snippets) ?? s
    }

    private static func snippetExpansion(for s: String, snippets: [Snippet]) -> String? {
        guard !snippets.isEmpty else { return nil }
        let key = snippetKey(s)
        guard !key.isEmpty else { return nil }
        return snippets.first { snippetKey($0.trigger) == key }?.expansion
    }

    private static let punctuation = CharacterSet.punctuationCharacters

    private static func snippetKey(_ s: String) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in s.unicodeScalars where !punctuation.contains(scalar) {
            scalars.append(scalar)
        }
        return String(scalars)
            .lowercased()
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    // MARK: - Normalize

    /// Whitespace/punctuation spacing plus sentence capitalization, applied
    /// per line so line breaks survive; runs of 3+ newlines collapse to 2.
    /// A missing space is inserted after . ! ? only between a lowercase and
    /// an uppercase letter ("said.Then" → "said. Then") — the guard keeps
    /// decimals ("5.50"), URLs ("example.com") and initialisms ("U.S.") intact.
    static func normalize(_ s: String) -> String {
        guard !s.isEmpty else { return s }
        var text = s
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        text = text
            .components(separatedBy: "\n")
            .map(normalizeLine)
            .joined(separator: "\n")
        text = newlineRuns.stringByReplacingMatches(
            in: text, options: [], range: fullRange(text), withTemplate: "\n\n")
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static let spaceRuns = regex("[ \\t]+")
    private static let spaceBeforeComma = regex("[ \\t]+,")
    private static let missingSentenceSpace = regex("([a-z])([.!?])([A-Z])")
    private static let newlineRuns = regex("\\n{3,}")

    private static func normalizeLine(_ line: String) -> String {
        var l = spaceRuns.stringByReplacingMatches(
            in: line, options: [], range: fullRange(line), withTemplate: " ")
        l = spaceBeforeComma.stringByReplacingMatches(
            in: l, options: [], range: fullRange(l), withTemplate: ",")
        l = missingSentenceSpace.stringByReplacingMatches(
            in: l, options: [], range: fullRange(l), withTemplate: "$1$2 $3")
        l = l.trimmingCharacters(in: .whitespaces)
        return capitalizeSentences(l)
    }

    /// Uppercases the first letter of the line and of each sentence (after
    /// . ! ? followed by a space) — only when that letter is a cased
    /// lowercase character (Unicode-aware: "él" → "Él", "ñandú" → "Ñandú"),
    /// so digits and emoji are left alone. Quoted text gets no special
    /// treatment beyond these mechanical rules.
    private static func capitalizeSentences(_ line: String) -> String {
        guard !line.isEmpty else { return line }
        var out = ""
        out.reserveCapacity(line.count)
        var expectCapital = true
        var afterSentencePunct = false
        for ch in line {
            if afterSentencePunct, ch == " " || ch == "\t" {
                expectCapital = true
            }
            if ch != " ", ch != "\t" {
                afterSentencePunct = ch == "." || ch == "!" || ch == "?"
            }
            if expectCapital, ch != " ", ch != "\t" {
                expectCapital = false
                if ch.isLowercase {
                    out += ch.uppercased()
                    continue
                }
            }
            out.append(ch)
        }
        return out
    }

    // MARK: - Regex plumbing

    private static func regex(
        _ pattern: String, _ options: NSRegularExpression.Options = []
    ) -> NSRegularExpression {
        // Patterns are compile-time constants; failure is programmer error.
        try! NSRegularExpression(pattern: pattern, options: options)
    }

    private static func fullRange(_ s: String) -> NSRange {
        NSRange(s.startIndex..., in: s)
    }
}
