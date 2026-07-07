import Foundation

/// Brand/number term accuracy (spec §1.4). Occurrences are the reference
/// segments' term tags; an occurrence is correct iff a same-track hypothesis
/// line whose interval overlaps [start_s - 5, end_s + 5] contains the
/// canonical or an alias (exact rule — no fuzzy credit for "Kelbow Fizz"),
/// or, for match == "money", carries a money value exactly equal to the
/// canonical's ($500,000 != $50,000 is precisely the D2 failure).
///
/// A line's interval is [tRel, next transcript line's tRel); the last line
/// gets tRel + 30. Overlap, not start-point containment: a long turn that
/// starts before the window but runs into the tagged segment still carries
/// its terms.
enum TermMetrics {

    /// Window slack in seconds on each side of a tagged segment (§1.4).
    private static let windowSlack: Double = 5.0

    /// Assumed duration of the final transcript line (no successor to bound it).
    private static let lastLineDuration: Double = 30.0

    static func score(reference: GoldenReference, hyp: HypNote, terms: TermsFile) -> TermResult {
        // Each transcript line paired with the end of its interval: the next
        // line's tRel (any speaker — a turn ends when the next turn starts),
        // or tRel + lastLineDuration for the final line.
        let timedLines: [(line: HypNote.Line, end: Double)] = hyp.transcript.enumerated().map { i, line in
            let end = i + 1 < hyp.transcript.count
                ? hyp.transcript[i + 1].tRel
                : line.tRel + lastLineDuration
            return (line, end)
        }

        // Normalized canonical/alias -> terms-file entry, so a reference tag
        // resolves to its aliases + match mode. Canonicals win over aliases
        // on key collision.
        var lookup: [String: TermsFile.Term] = [:]
        for term in terms.terms {
            for alias in term.aliases ?? [] {
                let key = EvalNormalizer.normalizedString(alias)
                if lookup[key] == nil { lookup[key] = term }
            }
        }
        for term in terms.terms {
            lookup[EvalNormalizer.normalizedString(term.canonical)] = term
        }

        var total = 0
        var correct = 0
        var perCategory: [String: (total: Int, correct: Int)] = [:]
        var misses: [String] = []

        for segment in reference.segments {
            for tag in segment.terms ?? [] {
                // Tags absent from the terms file still count as occurrences:
                // exact match on the tag text, no aliases, category from the tag.
                let entry = lookup[EvalNormalizer.normalizedString(tag.term)]
                let canonical = entry?.canonical ?? tag.term
                let category = entry?.category ?? tag.category
                let aliases = entry?.aliases ?? []
                let isMoney = (entry?.match ?? "exact") == "money"

                // Interval overlap of [tRel, end) with the closed window
                // [start_s - 5, end_s + 5]: tRel <= window end AND end > window
                // start. Keeps the window edges inclusive on the start side.
                let windowStart = segment.start_s - windowSlack
                let windowEnd = segment.end_s + windowSlack
                let windowLines = timedLines
                    .filter { timed in
                        track(ofSpeaker: timed.line.speaker) == segment.track
                            && timed.line.tRel <= windowEnd
                            && timed.end > windowStart
                    }
                    .map { $0.line }
                let hit = occurrenceFound(canonical: canonical, aliases: aliases,
                                          money: isMoney, in: windowLines)

                total += 1
                var bucket = perCategory[category] ?? (total: 0, correct: 0)
                bucket.total += 1
                if hit {
                    correct += 1
                    bucket.correct += 1
                } else {
                    misses.append("\(canonical) @ \(segment.id)")
                }
                perCategory[category] = bucket
            }
        }

        return TermResult(total: total, correct: correct,
                          perCategory: perCategory, misses: misses)
    }

    /// 2-party v1 speaker mapping (same convention as AttributionMetrics):
    /// "Me" -> me, any other speaker token -> them.
    private static func track(ofSpeaker speaker: String) -> String {
        speaker.lowercased() == "me" ? "me" : "them"
    }

    private static func occurrenceFound(canonical: String, aliases: [String],
                                        money: Bool, in lines: [HypNote.Line]) -> Bool {
        let needles = ([canonical] + aliases)
            .map { EvalNormalizer.normalizedString($0) }
            .filter { !$0.isEmpty }
        // nil canonical money value (malformed terms entry) degrades to the
        // exact rule rather than crediting nothing parseable.
        let moneyTarget = money ? EvalNormalizer.moneyValue(canonical) : nil

        for line in lines {
            // Token-boundary containment, not raw substring: "$50,000" must not
            // credit inside "$130,000" ("30000 dollars" ⊂ "130000 dollars"),
            // nor "EMO" inside "memory".
            let padded = " " + EvalNormalizer.normalizedString(line.text) + " "
            if needles.contains(where: { padded.contains(" " + $0 + " ") }) {
                return true
            }
            if let target = moneyTarget, moneyValueAppears(target, in: line) {
                return true
            }
        }
        return false
    }

    /// Money scan per contract: EvalNormalizer.moneyValue over single tokens
    /// and adjacent token pairs (pairs catch "500000 dollars", "50 cents").
    private static func moneyValueAppears(_ target: Double, in line: HypNote.Line) -> Bool {
        let tokens = EvalNormalizer.tokens(line.text)
        for (i, token) in tokens.enumerated() {
            if EvalNormalizer.moneyValue(token) == target { return true }
            if i + 1 < tokens.count,
               EvalNormalizer.moneyValue(token + " " + tokens[i + 1]) == target {
                return true
            }
        }
        return false
    }
}
