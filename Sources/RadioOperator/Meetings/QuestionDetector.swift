import Foundation
import NaturalLanguage

/// Pure logic for live lookups: spots a question in a finalized meeting line,
/// gates how often lookups fire, retrieves the note excerpts locally (the app
/// decides what leaves the Mac, not the model), and filters the reply.
/// Everything here is deterministic and offline; the Claude call itself lives
/// in MeetingController.
enum QuestionDetector {
    /// Hard ceiling on Claude spawns per meeting — the only spend cap that exists.
    static let perMeetingCap = 20
    /// The same question (normalized) is not re-asked within this window; also
    /// collapses a paraphrased repeat across the two channels.
    static let dedupeWindow: TimeInterval = 60
    static let minWords = 4
    static let maxWords = 40
    /// Notes larger than this are exports, not notes; the retriever skips them.
    static let maxNoteBytes = 2_000_000
    /// Context lines kept on each side of a hit.
    static let contextLines = 2
    static let maxFiles = 5
    /// Characters of a note's head (title, summary, decisions) included first.
    static let headBudget = 900

    /// Question openers that mark a question when the recognizer drops the
    /// terminal "?" (Apple finals sometimes do). Spoken questions often start
    /// with a filler, so a run of them is allowed first.
    private static let lead = regex(
        #"^(?:(?:so|and|but|okay|ok|yeah|um|uh|well|now|hey)[,\s]+)*(what|what's|who|who's|when|when's|where|where's|why|which|how|did|do|does|is|are|was|were|can|could|should|would|will|has|have|had)\b"#,
        [.caseInsensitive])
    /// Conversational / call-logistics shapes never worth a lookup.
    // ponytail: fixed phrase lists; tune from real transcripts before adding a classifier.
    private static let conversational = regex(
        #"(\bhear me\b|\bmake sense\b|\bany questions\b|\bwhat do you think\b|\bdo you want\b|\bcan you\b|\bcould you\b|\bwould you\b|\byou know\b|\bmy screen\b|\bmove on\b|\bmuted?\b|\bare you there\b)"#,
        [.caseInsensitive])
    /// Phrases that ask about OUR state or history: a lookup-worthy question
    /// even without a "?" or an opener ("I'd like to know where we are with…",
    /// "what's the status of…", "any update on…", "which partners we've…").
    private static let strongAsk = regex(
        #"(\b(i|we)('d| would|'ll)? ?(like|want|need) to know\b|\bwhere (are|were) we (with|on|at)\b|\bwhere we (are|were|stand|landed)\b|\b(what|how)('s| is| was|'re| are|'d| did) the (status|latest|update|plan|number|numbers|price|pricing|budget|timeline|deadline|date|deal|outcome|result|results)\b|\bany update(s)? on\b|\bremind me\b|\b(do|does) (we|anyone|anybody) know\b|\b(what|when|where|who|which|how many|how much) (did|do|does|have|has|had|were|was|are|is) (we|our|the|they|it)\b|\bwhich (partners?|vendors?|brands?|customers?|companies|people|accounts?|suppliers?)\b|\b(have|did) we (ever |already |last )?(talk|talked|speak|spoken|meet|met|decide|decided|agree|agreed|send|sent|get|got|hear|heard|discuss|discussed|quote|quoted|ship|shipped|launch|launched|sign|signed)\b)"#,
        [.caseInsensitive])
    /// Questions aimed at the other person ("are you…", "did you…") are
    /// conversation, not lookups — unless they carry a strongAsk phrase.
    private static let secondPerson = regex(
        #"\b(are|do|did|have|will|would|could|can|should|were|was) you\b"#, [.caseInsensitive])
    private static let citation = regex(#"\[[^\]\n]+\.md(:\d+(-\d+)?)?\]"#, [.caseInsensitive])
    /// Unicode-aware: accented names ("Müller", "café") stay whole words.
    private static let nonWord = regex(#"[^\p{L}\p{N} ]+"#)
    private static let tokenBreak = regex(#"[^\p{L}\p{N}]+"#)
    private static let spaces = regex(#"\s+"#)
    private static let heading = regex(#"(^|\n)[ \t]*#+[ \t]*"#)
    private static let checkbox = regex(#"\[[ xX]\][ \t]*"#)

    /// Words that carry no search signal on their own — function words plus
    /// the vocabulary every meeting note shares.
    private static let stopwords: Set<String> = [
        "what", "when", "where", "which", "about", "there", "their", "they", "this",
        "that", "these", "those", "with", "from", "have", "does", "were", "will",
        "would", "could", "should", "into", "than", "then", "them", "some", "been",
        "being", "also", "just", "like", "ever", "back", "over", "your", "know",
        "think", "going", "want", "need", "said", "says", "again", "still", "really",
        "last", "next", "time", "week", "today", "tomorrow", "meeting", "call",
        "notes", "note", "thing", "things", "first", "here", "else", "good", "take",
        "anyone", "everyone", "someone", "sure", "okay", "yeah", "guys", "minute",
        "number", "actually", "right", "maybe", "little", "something", "anything",
        "everything", "nothing", "because", "before", "after", "since", "while",
        "done", "doing", "gonna", "wanna", "kind", "sort", "much", "many", "well",
        // 2–3 letter function words (the length floor is low so acronyms survive)
        "the", "and", "for", "but", "our", "are", "was", "can", "did", "get", "got",
        "how", "who", "why", "you", "yet", "not", "any", "all", "one", "two", "new",
        "old", "way", "say", "see", "use", "now", "out", "off", "per", "via", "has",
        "had", "his", "her", "its", "let", "may", "own", "put", "run", "set", "too",
        "yes", "lot", "bit", "end", "day", "ago", "big", "few", "far", "guy", "hey",
        "yep", "nah", "hmm", "huh", "umm", "ask", "tell", "told", "mean", "us", "ok",
        // question-shape words, not topic words
        "wondering", "wonder", "exactly", "curious", "wanted", "asking", "update",
        "status", "latest", "remind", "anyone", "anybody",
    ]

    /// The trailing sentence of `text` if it reads as a lookup-worthy question.
    nonisolated static func question(in text: String) -> String? {
        let s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty, !s.hasPrefix("[") else { return nil }
        let sentence = lastSentence(of: s)
        let words = sentence.split(whereSeparator: { $0.isWhitespace }).count
        guard (minWords...maxWords).contains(words) else { return nil }
        let range = fullRange(sentence)
        guard conversational.firstMatch(in: sentence, range: range) == nil else { return nil }
        let strong = strongAsk.firstMatch(in: sentence, range: range) != nil
        guard strong || secondPerson.firstMatch(in: sentence, range: range) == nil else { return nil }
        // A recognizer-terminated statement ("Can we move on.") is not a
        // question; the lead-word fallback exists only for missing punctuation.
        let terminated = sentence.last.map { ".!".contains($0) } ?? false
        let asks = strong || sentence.hasSuffix("?")
            || (!terminated && lead.firstMatch(in: sentence, range: range) != nil)
        return asks ? sentence : nil
    }

    /// Sentence-aware split (handles "Mr.", "U.S.", "e.g."), last sentence wins.
    private static func lastSentence(of s: String) -> String {
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = s
        var last: Range<String.Index>?
        tokenizer.enumerateTokens(in: s.startIndex..<s.endIndex) { range, _ in
            last = range
            return true
        }
        guard let last else { return s }
        return s[last].trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Normalized dedupe key: lowercase, letters/digits only, single spaces.
    nonisolated static func key(_ s: String) -> String {
        var k = s.lowercased()
        k = nonWord.stringByReplacingMatches(in: k, range: fullRange(k), withTemplate: " ")
        k = spaces.stringByReplacingMatches(in: k, range: fullRange(k), withTemplate: " ")
        return k.trimmingCharacters(in: .whitespaces)
    }

    /// One lookup at a time, a per-meeting cap, and no repeats inside the
    /// dedupe window. A question that arrives mid-lookup is dropped, not queued.
    // ponytail: drop-not-queue; add a single pending slot if the second of two
    // back-to-back questions matters in practice.
    nonisolated static func shouldFire(key: String, lastKey: String?, lastAt: Date?, now: Date,
                                       inFlight: Bool, count: Int) -> Bool {
        guard !inFlight, count < perMeetingCap else { return false }
        if let lastKey, let lastAt, lastKey == key,
           now.timeIntervalSince(lastAt) < dedupeWindow { return false }
        return true
    }

    /// Content words of a question, for retrieval. Short tokens survive only
    /// when they look like an acronym or a code ("SIP", "PHL", "Q3") — in this
    /// vault those carry the whole signal.
    nonisolated static func searchTerms(_ question: String) -> [String] {
        let tokens = tokenBreak.stringByReplacingMatches(
            in: question, range: fullRange(question), withTemplate: " ")
            .split(separator: " ").map(String.init)
        return tokens.compactMap { token in
            let lower = token.lowercased()
            guard !stopwords.contains(lower) else { return nil }
            let code = token.count >= 2 && token.contains(where: \.isLetter)
                && (token.uppercased() == token || token.contains(where: \.isNumber))
            return lower.count >= 3 || code ? lower : nil
        }
    }

    /// Terms to retrieve on: the question's own, then a few topic words from
    /// the turn before it, because follow-ups lean on what was just said
    /// ("which partners we've spoken to?" after "where are we with delivery").
    nonisolated static func retrievalTerms(question: String, previousTurn: String?) -> [String] {
        var terms = searchTerms(question)
        for term in searchTerms(previousTurn ?? "").prefix(4) where !terms.contains(term) {
            terms.append(term)
        }
        return terms
    }

    /// Excerpts from the notes under `folder` that mention any term as a whole
    /// word: the best few files, a couple of lines around each hit, labelled
    /// `===FILE: name.md===` so the model can cite them. Empty when nothing
    /// matches — and then nothing is sent. `excluding` is the meeting's own
    /// in-progress note, which must never feed a lookup (it is this call's
    /// untrusted speech and earlier answers).
    // ponytail: naive full scan per question (~2 MB today); build an index if
    // the vault grows past a few thousand notes.
    nonisolated static func snippets(terms: [String], in folders: [URL], excluding: URL?,
                                     maxChars: Int) -> String {
        guard !terms.isEmpty else { return "" }
        // Symlinks resolved on both sides: a symlinked notes folder enumerates
        // as empty otherwise, and the live-note exclusion must compare like
        // with like.
        let excluded = excluding?.resolvingSymlinksInPath().standardizedFileURL.path
        let patterns = terms.map {
            regex("\\b" + NSRegularExpression.escapedPattern(for: $0) + "\\b", [.caseInsensitive])
        }
        var scored: [(score: Int, name: String, lines: [String], hits: [Int])] = []
        let files = folders.flatMap { folder -> [URL] in
            guard let e = FileManager.default.enumerator(
                at: folder.resolvingSymlinksInPath(), includingPropertiesForKeys: [.fileSizeKey],
                options: [.skipsHiddenFiles])
            else { return [] }
            return e.compactMap { $0 as? URL }
        }
        for url in files where url.pathExtension == "md" {
            if url.resolvingSymlinksInPath().standardizedFileURL.path == excluded { continue }
            // Sync-conflict / renamed copies of an in-progress note carry this
            // call's own speech too.
            if url.lastPathComponent.localizedCaseInsensitiveContains("Meeting in progress") { continue }
            if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
               size > maxNoteBytes { continue }
            guard let content = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let name = url.lastPathComponent
            let lines = content.components(separatedBy: "\n")
            var hits = Set<Int>()
            var distinct = 0, inTitle = 0, total = 0
            for p in patterns {
                var any = false
                for (i, line) in lines.enumerated()
                where p.firstMatch(in: line, range: fullRange(line)) != nil {
                    hits.insert(i)
                    any = true
                    total += 1
                }
                if any { distinct += 1 }
                if p.firstMatch(in: name, range: fullRange(name)) != nil { inTitle += 1 }
            }
            guard distinct > 0 || inTitle > 0 else { continue }
            // A term in the title says what the note is ABOUT; density says how
            // much it dwells on it. Both beat a stray mention.
            let score = distinct * 10 + inTitle * 10 + min(total, 30)
            scored.append((score, name, lines, hits.sorted()))
        }
        // Best score first; newest note (date-prefixed name) breaks ties.
        scored.sort { $0.score != $1.score ? $0.score > $1.score : $0.name > $1.name }

        var out = ""
        for file in scored.prefix(maxFiles) {
            var body: [String] = []
            // Lead with the note's own head (title + summary/decisions, i.e. the
            // status), then the hit windows from the transcript.
            let headEnd = file.lines.firstIndex {
                $0.hasPrefix("## Transcript") || $0.hasPrefix("## My Notes") || $0.hasPrefix("## Live answers")
            } ?? min(file.lines.count, 40)
            let h1 = file.lines.firstIndex { $0.hasPrefix("# ") } ?? 0
            var headChars = 0
            for i in h1..<headEnd {
                let l = file.lines[i].trimmingCharacters(in: .whitespaces)
                if l.isEmpty || l == NotesStore.summaryPendingMarker { continue }
                if headChars + l.count > headBudget { break }
                body.append(l)
                headChars += l.count
            }
            var lastIncluded = headEnd - 1
            for hit in file.hits.filter({ $0 >= headEnd }).prefix(6) {
                let lo = max(hit - contextLines, lastIncluded + 1)
                let hi = min(hit + contextLines, file.lines.count - 1)
                guard lo <= hi else { continue }
                if lo > lastIncluded + 1 { body.append("…") }
                for i in lo...hi where !file.lines[i].trimmingCharacters(in: .whitespaces).isEmpty {
                    body.append(file.lines[i])
                }
                lastIncluded = hi
            }
            let header = "===FILE: \(file.name)==="
            let block = header + "\n" + body.joined(separator: "\n") + "\n\n"
            if out.count + block.count <= maxChars {
                out += block
            } else {
                let room = maxChars - out.count
                if room > header.count + 20 { out += String(block.prefix(room)) }
                break
            }
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The reply if it is a real, cited answer; nil for the NO_ANSWER sentinel
    /// or an uncited reply (nothing is shown for either).
    nonisolated static func answer(from raw: String) -> String? {
        let a = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !a.isEmpty, !a.uppercased().contains("NO_ANSWER"),
              citation.firstMatch(in: a, range: fullRange(a)) != nil else { return nil }
        return a
    }

    /// Flattens a reply to one line with no markdown structure, so it can never
    /// create a heading, list, or checkbox that the note parser attributes to
    /// this meeting.
    nonisolated static func oneLine(_ s: String) -> String {
        var out = heading.stringByReplacingMatches(in: s, range: fullRange(s), withTemplate: "$1")
        out = checkbox.stringByReplacingMatches(in: out, range: fullRange(out), withTemplate: "")
        out = spaces.stringByReplacingMatches(in: out, range: fullRange(out), withTemplate: " ")
        return out.trimmingCharacters(in: .whitespaces)
    }

    // MARK: - Regex plumbing

    private static func regex(_ pattern: String,
                              _ options: NSRegularExpression.Options = []) -> NSRegularExpression {
        try! NSRegularExpression(pattern: pattern, options: options)
    }

    private static func fullRange(_ s: String) -> NSRange {
        NSRange(s.startIndex..., in: s)
    }
}
