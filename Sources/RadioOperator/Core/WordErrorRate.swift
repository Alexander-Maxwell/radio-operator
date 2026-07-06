import Foundation

/// Pure word/character error-rate scoring for the `--probe-wer` benchmark.
/// No engine coupling: reference and hypothesis are just strings, so the same
/// scorer grades Apple SpeechAnalyzer today and any alternate engine later.
enum WordErrorRate {
    struct Score: Equatable {
        var substitutions = 0
        var deletions = 0
        var insertions = 0
        var referenceCount = 0

        var errors: Int { substitutions + deletions + insertions }

        /// Errors over reference length. An empty reference scores 0 against an
        /// empty hypothesis; against a non-empty one, every inserted token is
        /// an error over a floor denominator of 1 (WER is undefined there —
        /// this keeps the aggregate monotone instead of dividing by zero).
        var rate: Double {
            if referenceCount == 0 {
                return errors == 0 ? 0 : Double(errors)
            }
            return Double(errors) / Double(referenceCount)
        }

        mutating func add(_ other: Score) {
            substitutions += other.substitutions
            deletions += other.deletions
            insertions += other.insertions
            referenceCount += other.referenceCount
        }
    }

    /// Lowercase, split on whitespace AND interior hyphens/slashes (so
    /// "twenty-five" == "twenty five" and "and/or" == "and or" — hyphenation is
    /// a formatting choice, not a transcription error), then trim punctuation/
    /// symbols off token edges. Apostrophes and interior periods survive
    /// ("don't", "u.s") — consistent on both sides, so contractions and
    /// initialisms still match each other.
    ///
    /// Numeral policy: digits are compared as-is. A reference must spell numbers
    /// the way the engine under test emits them (see the README manifest note);
    /// "25" vs "twenty five" counts as an error by design.
    static func normalize(_ s: String) -> [String] {
        let strip = CharacterSet.punctuationCharacters.union(.symbols)
        let separators = CharacterSet.whitespacesAndNewlines
            .union(CharacterSet(charactersIn: "-/"))
        return s.lowercased()
            .components(separatedBy: separators)
            .map { $0.trimmingCharacters(in: strip) }
            .filter { !$0.isEmpty }
    }

    /// Word error rate: token-level Levenshtein with an operation backtrace.
    static func score(reference: String, hypothesis: String) -> Score {
        align(ref: normalize(reference), hyp: normalize(hypothesis))
    }

    /// Character error rate over the normalized text (spaces included). Uses a
    /// memory-bounded distance (two rolling rows, O(min(n,m)) space) since no
    /// caller needs the S/D/I split for characters — only the rate. This keeps
    /// long transcripts from allocating an O(n·m) matrix.
    static func characterScore(reference: String, hypothesis: String) -> Score {
        let r = Array(normalize(reference).joined(separator: " "))
        let h = Array(normalize(hypothesis).joined(separator: " "))
        let distance = levenshtein(r, h)
        // Report the whole distance as substitutions: rate only reads `errors`
        // (= distance) and `referenceCount`, so the split is immaterial here.
        return Score(substitutions: distance, deletions: 0, insertions: 0, referenceCount: r.count)
    }

    /// Distance-only Levenshtein with two rolling rows.
    static func levenshtein<T: Equatable>(_ a: [T], _ b: [T]) -> Int {
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var prev = Array(0...b.count)
        var curr = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            curr[0] = i
            for j in 1...b.count {
                curr[j] = a[i - 1] == b[j - 1]
                    ? prev[j - 1]
                    : min(prev[j - 1], prev[j], curr[j - 1]) + 1
            }
            swap(&prev, &curr)
        }
        return prev[b.count]
    }

    /// Classic DP alignment; backtrace splits the distance into S/D/I counts.
    static func align(ref: [String], hyp: [String]) -> Score {
        let n = ref.count, m = hyp.count
        if n == 0 { return Score(substitutions: 0, deletions: 0, insertions: m, referenceCount: 0) }
        if m == 0 { return Score(substitutions: 0, deletions: n, insertions: 0, referenceCount: n) }

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

        var i = n, j = m
        var score = Score(referenceCount: n)
        while i > 0 || j > 0 {
            if i > 0, j > 0, ref[i - 1] == hyp[j - 1], dist[i][j] == dist[i - 1][j - 1] {
                i -= 1; j -= 1
            } else if i > 0, j > 0, dist[i][j] == dist[i - 1][j - 1] + 1 {
                score.substitutions += 1; i -= 1; j -= 1
            } else if i > 0, dist[i][j] == dist[i - 1][j] + 1 {
                score.deletions += 1; i -= 1
            } else {
                score.insertions += 1; j -= 1
            }
        }
        return score
    }

    /// "12.5%" style label, one decimal, deterministic (no locale drift).
    static func percent(_ rate: Double) -> String {
        String(format: "%.1f%%", rate * 100)
    }
}
