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

    /// Lowercase, trim punctuation/symbols off token edges, collapse
    /// whitespace. Interior characters survive ("don't", "u.s") — consistent
    /// on both sides, so contractions and initialisms still match each other.
    static func normalize(_ s: String) -> [String] {
        let strip = CharacterSet.punctuationCharacters.union(.symbols)
        return s.lowercased()
            .components(separatedBy: .whitespacesAndNewlines)
            .map { $0.trimmingCharacters(in: strip) }
            .filter { !$0.isEmpty }
    }

    /// Word error rate: token-level Levenshtein with an operation backtrace.
    static func score(reference: String, hypothesis: String) -> Score {
        align(ref: normalize(reference), hyp: normalize(hypothesis))
    }

    /// Character error rate over the normalized text (spaces included).
    static func characterScore(reference: String, hypothesis: String) -> Score {
        let r = normalize(reference).joined(separator: " ").map(String.init)
        let h = normalize(hypothesis).joined(separator: " ").map(String.init)
        return align(ref: r, hyp: h)
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
