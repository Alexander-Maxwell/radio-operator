import Foundation

/// Alignment-layer eval metrics (spec §1.2–1.3): per-track WER over scored
/// reference segments, 2-party speaker-attribution accuracy, the me-track
/// collapse detector, and cross-track bleed diagnostics. Pure/deterministic;
/// both sides tokenize through EvalNormalizer so normalization is identical.
enum AttributionMetrics {

    // MARK: - Alignment backtrace

    /// Levenshtein backtrace as forward-ordered index pairs:
    /// match/sub → (i, j), deletion → (i, nil), insertion → (nil, j).
    /// Tie-break order (match, sub, del, ins) mirrors WordErrorRate.align so
    /// S/D/I derived from these pairs equals the WER scorer's accounting.
    static func alignmentPairs(ref: [String], hyp: [String]) -> [(r: Int?, h: Int?)] {
        let n = ref.count, m = hyp.count
        if n == 0 { return (0..<m).map { (r: Int?.none, h: Int?.some($0)) } }
        if m == 0 { return (0..<n).map { (r: Int?.some($0), h: Int?.none) } }

        var dist = [[Int]](repeating: [Int](repeating: 0, count: m + 1), count: n + 1)
        for i in 0...n { dist[i][0] = i }
        for j in 0...m { dist[0][j] = j }
        for i in 1...n {
            for j in 1...m {
                if ref[i - 1] == hyp[j - 1] {
                    dist[i][j] = dist[i - 1][j - 1]
                } else {
                    dist[i][j] = min(dist[i - 1][j - 1], dist[i - 1][j], dist[i][j - 1]) + 1
                }
            }
        }

        var pairs: [(r: Int?, h: Int?)] = []
        var i = n, j = m
        while i > 0 || j > 0 {
            if i > 0, j > 0, ref[i - 1] == hyp[j - 1], dist[i][j] == dist[i - 1][j - 1] {
                pairs.append((r: i - 1, h: j - 1)); i -= 1; j -= 1
            } else if i > 0, j > 0, dist[i][j] == dist[i - 1][j - 1] + 1 {
                pairs.append((r: i - 1, h: j - 1)); i -= 1; j -= 1
            } else if i > 0, dist[i][j] == dist[i - 1][j] + 1 {
                pairs.append((r: i - 1, h: nil)); i -= 1
            } else {
                pairs.append((r: nil, h: j - 1)); j -= 1
            }
        }
        return pairs.reversed()
    }

    // MARK: - Per-track WER (§1.2)

    /// Reference side: score==true segments of `track` joined in start_s order.
    /// Hypothesis side: transcript lines whose speaker maps to `track`
    /// ("Me" → me, anything else → them; 2-party v1). Hyp lines whose tRel
    /// falls within ±2 s of ANY non-scored segment contribute no insertions —
    /// a line-level approximation of the spec's per-token exclusion window.
    /// nil score + reason when the track has no scored reference segments.
    static func perTrackWER(reference: GoldenReference, hyp: HypNote, track: String) -> TrackWER {
        let want = normTrack(track)
        let scored = reference.segments
            .filter { normTrack($0.track) == want && $0.score }
            .sorted { $0.start_s != $1.start_s ? $0.start_s < $1.start_s : $0.id < $1.id }
        guard !scored.isEmpty else {
            return TrackWER(track: track, score: nil,
                            notApplicableReason: "no scored reference segments for track '\(track)'")
        }
        let refTokens = scored.flatMap { EvalNormalizer.tokens($0.text) }
        // Scored segments can normalize to zero tokens (all fillers). WER is
        // undefined there and Score.rate would surface a raw insertion count
        // that pollutes aggregation, so report Not Applicable instead.
        guard !refTokens.isEmpty else {
            return TrackWER(track: track, score: nil,
                            notApplicableReason: "scored reference segments for track '\(track)' "
                                + "normalize to zero tokens")
        }

        let unscored = reference.segments.filter { !$0.score }
        var hypTokens: [String] = []
        var forgivable: [Bool] = []       // per hyp token: near a non-scored region
        for line in hyp.transcript where hypTrack(for: line.speaker) == want {
            let near = unscored.contains { line.tRel >= $0.start_s - 2 && line.tRel <= $0.end_s + 2 }
            let toks = EvalNormalizer.tokens(line.text)
            hypTokens.append(contentsOf: toks)
            forgivable.append(contentsOf: Array(repeating: near, count: toks.count))
        }

        var score = WordErrorRate.Score(referenceCount: refTokens.count)
        for pair in alignmentPairs(ref: refTokens, hyp: hypTokens) {
            switch (pair.r, pair.h) {
            case let (ri?, hi?):
                if refTokens[ri] != hypTokens[hi] { score.substitutions += 1 }
            case (.some, nil):
                score.deletions += 1
            case let (nil, hi?):
                if !forgivable[hi] { score.insertions += 1 }
            case (nil, nil):
                break
            }
        }
        return TrackWER(track: track, score: score, notApplicableReason: nil)
    }

    // MARK: - Attribution (§1.3, 2-party)

    /// 2-party: labels are fixed by stream identity ("Me" line ↔ me track), so
    /// `roster` is unused here — the parameter is reserved for the 3+-party
    /// Hungarian remap. Merged reference (all scored segments in start order,
    /// tokens labeled by segment track) is aligned against the merged
    /// hypothesis (lines in order, tokens labeled by speaker-token track).
    /// accuracy = same-label aligned pairs / aligned pairs (match or sub).
    /// Collapse: ≥ 50 scored me-ref tokens with < 5% aligned to me-hyp tokens.
    /// Bleed is a deterministic line-level approximation of the spec's sliding
    /// 10-token window: a whole hyp line is compared (token-set containment
    /// |line ∩ segment| / min(|line|, |segment|) ≥ 0.8) to each other-party
    /// segment whose [start_s-3, end_s+3] window contains the line's tRel;
    /// every token on a matching line counts as bled. Containment, not
    /// Jaccard: a short fully-bled line inside a long segment must still fire.
    static func attribution(reference: GoldenReference, hyp: HypNote,
                            roster: RosterMap) -> AttributionResult {
        let scored = reference.segments
            .filter { $0.score }
            .sorted { $0.start_s != $1.start_s ? $0.start_s < $1.start_s : $0.id < $1.id }
        var refTokens: [String] = []
        var refLabels: [String] = []
        for seg in scored {
            let toks = EvalNormalizer.tokens(seg.text)
            refTokens.append(contentsOf: toks)
            refLabels.append(contentsOf: Array(repeating: normTrack(seg.track), count: toks.count))
        }
        var hypTokens: [String] = []
        var hypLabels: [String] = []
        for line in hyp.transcript {
            let toks = EvalNormalizer.tokens(line.text)
            hypTokens.append(contentsOf: toks)
            hypLabels.append(contentsOf: Array(repeating: hypTrack(for: line.speaker), count: toks.count))
        }

        var aligned = 0, correct = 0, meRefAlignedToMeHyp = 0
        for pair in alignmentPairs(ref: refTokens, hyp: hypTokens) {
            guard let ri = pair.r, let hi = pair.h else { continue }
            aligned += 1
            if refLabels[ri] == hypLabels[hi] { correct += 1 }
            if refLabels[ri] == "me", hypLabels[hi] == "me" { meRefAlignedToMeHyp += 1 }
        }

        let meRefCount = refLabels.lazy.filter { $0 == "me" }.count
        var collapse = false
        var collapseDetail: String?
        if meRefCount >= 50, Double(meRefAlignedToMeHyp) < 0.05 * Double(meRefCount) {
            collapse = true
            collapseDetail = "me-track collapse: \(meRefAlignedToMeHyp)/\(meRefCount) "
                + "scored me reference tokens aligned to me hypothesis tokens (< 5%)"
        }

        return AttributionResult(
            accuracy: aligned == 0 ? nil : Double(correct) / Double(aligned),
            alignedTokens: aligned,
            correctTokens: correct,
            collapseFlag: collapse,
            collapseDetail: collapseDetail,
            bleedRateMe: bleedRate(track: "me", reference: reference, hyp: hyp),
            bleedRateThem: bleedRate(track: "them", reference: reference, hyp: hyp))
    }

    // MARK: - Helpers

    /// nil when the track has no hypothesis tokens (rate undefined, not zero).
    private static func bleedRate(track: String, reference: GoldenReference,
                                  hyp: HypNote) -> Double? {
        let others = reference.segments.filter { normTrack($0.track) != track }
        var total = 0, bled = 0
        for line in hyp.transcript where hypTrack(for: line.speaker) == track {
            let toks = EvalNormalizer.tokens(line.text)
            if toks.isEmpty { continue }
            total += toks.count
            let lineSet = Set(toks)
            let hit = others.contains { seg in
                guard line.tRel >= seg.start_s - 3, line.tRel <= seg.end_s + 3 else { return false }
                return containment(lineSet, Set(EvalNormalizer.tokens(seg.text))) >= 0.8
            }
            if hit { bled += toks.count }
        }
        return total == 0 ? nil : Double(bled) / Double(total)
    }

    /// |a ∩ b| / min(|a|, |b|). Whole-set Jaccard under-detects when lengths
    /// differ (a fully-bled 3-token line inside a 30-token segment scores
    /// 0.1); containment scores it 1.0. 0 when either side is empty.
    private static func containment(_ a: Set<String>, _ b: Set<String>) -> Double {
        let denom = min(a.count, b.count)
        guard denom > 0 else { return 0 }
        return Double(a.intersection(b).count) / Double(denom)
    }

    /// Speaker token → track: "Me" (case-insensitive) is the me stream; every
    /// other token is the them stream in 2-party v1.
    static func hypTrack(for speaker: String) -> String {
        speaker.trimmingCharacters(in: .whitespaces).lowercased() == "me" ? "me" : "them"
    }

    private static func normTrack(_ t: String) -> String {
        t.lowercased() == "me" ? "me" : "them"
    }
}
