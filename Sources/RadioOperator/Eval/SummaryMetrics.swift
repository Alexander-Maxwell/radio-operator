import Foundation

/// Action-item precision/recall/F1 (spec §1.5) and hallucinated-owner rate
/// (§1.6). Per-meeting API only: micro-averaged pooling across meetings is
/// the caller's job (sum matched/refCount/hypCount before dividing).
enum SummaryMetrics {

    /// §1.5 fixed stopword list, applied after EvalNormalizer.tokens.
    /// No lemmatization in v1.
    static let stopwords: Set<String> = [
        "the", "a", "an", "to", "of", "for", "on", "in", "with",
        "and", "or", "by", "at", "from", "will", "should",
    ]

    /// Main eligibility gate; 0.5/0.7 reruns exist so a threshold change can
    /// never manufacture a pass (§1.5).
    static let matchThreshold = 0.60
    private static let sensitivityThresholds: [(key: String, value: Double)] = [
        ("0.5", 0.5), ("0.7", 0.7),
    ]
    private static let eps = 1e-9

    // MARK: - §1.5 action-item F1

    static func actionItemF1(refItems: [GoldenReference.ActionItem],
                             hypItems: [HypNote.ActionItem],
                             roster: RosterMap) -> F1Result {
        let nRef = refItems.count
        let nHyp = hypItems.count
        // Similarity and the owner gate are threshold-independent; compute
        // once so the sensitivity reruns only redo the assignment.
        var sim = [[Double]](repeating: [Double](repeating: 0, count: nHyp), count: nRef)
        var ownerOK = [[Bool]](repeating: [Bool](repeating: false, count: nHyp), count: nRef)
        for i in 0..<nRef {
            for j in 0..<nHyp {
                sim[i][j] = taskSimilarity(refItems[i].task, hypItems[j].task)
                ownerOK[i][j] = ownersEligible(refItems[i].owner, hypItems[j].owner,
                                               roster: roster)
            }
        }
        func matched(at threshold: Double) -> Int {
            matchCount(nRef: nRef, nHyp: nHyp) { i, j in
                ownerOK[i][j] && sim[i][j] >= threshold - eps ? sim[i][j] : nil
            }
        }
        let m = matched(at: matchThreshold)
        var sensitivity: [String: Double] = [:]
        var matchedAt: [String: Int] = [:]
        for t in sensitivityThresholds {
            let mt = matched(at: t.value)
            matchedAt[t.key] = mt
            // Key omitted when F1 is undefined (empty ref or hyp side).
            if let f = f1Value(matched: mt, refCount: nRef, hypCount: nHyp) {
                sensitivity[t.key] = f
            }
        }
        return F1Result(
            precision: nHyp == 0 ? nil : Double(m) / Double(nHyp),
            recall: nRef == 0 ? nil : Double(m) / Double(nRef),
            f1: f1Value(matched: m, refCount: nRef, hypCount: nHyp),
            matched: m,
            refCount: nRef,
            hypCount: nHyp,
            sensitivity: sensitivity,
            matchedAt: matchedAt)
    }

    // MARK: - §1.6 hallucinated owners

    static func hallucinatedOwners(hypActionItems: [HypNote.ActionItem], hypDecisions: [String],
                                   refSummary: GoldenReference.RefSummary?,
                                   roster: RosterMap) -> HallucResult {
        var tier1 = 0
        var tier2 = 0
        var withOwner = 0
        var offenders: [String] = []

        // Tier 1: owner canonicalizes to nothing (phantom). Tier 2: the task
        // matches >= 1 reference item at the main threshold (owner ignored
        // for the match) and NO matching reference item shares the owner.
        // Not one-to-one: §1.6 grades each owned hypothesis item on its own.
        func grade(owner: String, task: String, refPool: [(task: String, owner: String?)]) {
            withOwner += 1
            guard let canonical = canonicalOwner(owner, roster: roster) else {
                tier1 += 1
                offenders.append("tier1 phantom '\(owner)': \(task)")
                return
            }
            let matches = refPool.filter {
                taskSimilarity(task, $0.task) >= matchThreshold - eps
            }
            guard !matches.isEmpty else { return }
            let ownerAgrees = matches.contains { match in
                match.owner.flatMap { canonicalOwner($0, roster: roster) } == canonical
            }
            if !ownerAgrees {
                tier2 += 1
                offenders.append("tier2 misassigned '\(owner)': \(task)")
            }
        }

        let refActionPool = (refSummary?.action_items ?? []).map { (task: $0.task, owner: $0.owner) }
        for item in hypActionItems {
            guard let owner = item.owner else { continue }
            grade(owner: owner, task: item.task, refPool: refActionPool)
        }
        // Hypothesis decisions carry owners only as a trailing "— Owner";
        // unowned decisions never enter the denominator.
        let refDecisionPool = (refSummary?.decisions ?? []).map { (task: $0.text, owner: $0.owner) }
        for decision in hypDecisions {
            guard let parsed = decisionOwner(decision) else { continue }
            grade(owner: parsed.owner, task: parsed.text, refPool: refDecisionPool)
        }
        return HallucResult(tier1Phantom: tier1, tier2Misassigned: tier2,
                            hypItemsWithOwner: withOwner, offenders: offenders)
    }

    // MARK: - Task similarity

    static func taskTokens(_ s: String) -> [String] {
        EvalNormalizer.tokens(s).filter { !stopwords.contains($0) }
    }

    /// §1.5 sim = max(Jaccard over token sets, character-Levenshtein ratio
    /// over the normalized joined strings). Two empty tasks score 1.0.
    static func taskSimilarity(_ a: String, _ b: String) -> Double {
        let ta = taskTokens(a)
        let tb = taskTokens(b)
        let sa = Set(ta)
        let sb = Set(tb)
        let jaccard: Double
        if sa.isEmpty && sb.isEmpty {
            jaccard = 1
        } else {
            jaccard = Double(sa.intersection(sb).count) / Double(sa.union(sb).count)
        }
        let ca = Array(ta.joined(separator: " "))
        let cb = Array(tb.joined(separator: " "))
        let maxLen = max(ca.count, cb.count)
        let levRatio = maxLen == 0
            ? 1.0
            : 1.0 - Double(WordErrorRate.levenshtein(ca, cb)) / Double(maxLen)
        return max(jaccard, levRatio)
    }

    // MARK: - Owner canonicalization

    /// Roster alias map first; then the app's track tokens: "me" -> the me
    /// participant, "them" -> the counterparty id, which RosterMap defines
    /// only for 2-party meetings — a bare "Them" owner in a 3+ party roster
    /// canonicalizes to nil (phantom) per §1.5.
    static func canonicalOwner(_ owner: String, roster: RosterMap) -> String? {
        if let id = roster.resolve(owner) { return id }
        switch EvalNormalizer.normalizedString(owner) {
        case "me": return roster.meId
        case "them": return roster.themId
        default: return nil
        }
    }

    /// Decisions: split on the LAST " — " (spaced em dash only) so em dashes
    /// inside the decision text survive; hyphen/double-hyphen forms are NOT
    /// owner separators here (contract, §1.6).
    static func decisionOwner(_ decision: String) -> (text: String, owner: String)? {
        guard let sep = decision.range(of: " — ", options: .backwards) else { return nil }
        let owner = String(decision[sep.upperBound...]).trimmingCharacters(in: .whitespaces)
        let text = String(decision[..<sep.lowerBound]).trimmingCharacters(in: .whitespaces)
        guard !owner.isEmpty, !text.isEmpty else { return nil }
        return (text, owner)
    }

    /// §1.5 pair gate: nil owners pair only with nil owners; otherwise both
    /// sides must canonicalize (non-nil) to the SAME roster id — an
    /// unresolvable owner blocks the pair entirely.
    private static func ownersEligible(_ refOwner: String?, _ hypOwner: String?,
                                       roster: RosterMap) -> Bool {
        switch (refOwner, hypOwner) {
        case (nil, nil):
            return true
        case let (r?, h?):
            guard let rc = canonicalOwner(r, roster: roster),
                  let hc = canonicalOwner(h, roster: roster) else { return false }
            return rc == hc
        default:
            return false
        }
    }

    // MARK: - Optimal one-to-one assignment

    /// Maximizes TOTAL sim over eligible pairs (weight nil = ineligible).
    /// Exact bitmask DP when the smaller side fits a mask (<= 20 items);
    /// greedy-by-descending-sim above that (contract §1.5).
    private static func matchCount(nRef: Int, nHyp: Int,
                                   weight: (Int, Int) -> Double?) -> Int {
        if nRef == 0 || nHyp == 0 { return 0 }
        if min(nRef, nHyp) > 20 {
            return greedyCount(nRef: nRef, nHyp: nHyp, weight: weight)
        }
        if nHyp <= nRef {
            return dpCount(rows: nRef, cols: nHyp, weight: weight)
        }
        return dpCount(rows: nHyp, cols: nRef) { weight($1, $0) }
    }

    /// dp[mask] after processing rows 0..i = best (total, count) using cols
    /// within mask. Reads only the previous row's array, so a row can never
    /// match twice. Exact-total ties prefer more matched pairs.
    private static func dpCount(rows: Int, cols: Int,
                                weight: (Int, Int) -> Double?) -> Int {
        let full = 1 << cols
        var totals = [Double](repeating: 0, count: full)
        var counts = [Int](repeating: 0, count: full)
        for row in 0..<rows {
            var nextTotals = totals
            var nextCounts = counts
            for mask in 1..<full {
                for col in 0..<cols where mask & (1 << col) != 0 {
                    guard let w = weight(row, col) else { continue }
                    let prev = mask & ~(1 << col)
                    let total = totals[prev] + w
                    let count = counts[prev] + 1
                    if total > nextTotals[mask] + eps
                        || (total > nextTotals[mask] - eps && count > nextCounts[mask]) {
                        nextTotals[mask] = total
                        nextCounts[mask] = count
                    }
                }
            }
            totals = nextTotals
            counts = nextCounts
        }
        return counts[full - 1]
    }

    /// Deterministic tie-break: sim desc, then ref index, then hyp index.
    private static func greedyCount(nRef: Int, nHyp: Int,
                                    weight: (Int, Int) -> Double?) -> Int {
        var pairs: [(w: Double, r: Int, h: Int)] = []
        for r in 0..<nRef {
            for h in 0..<nHyp {
                if let w = weight(r, h) { pairs.append((w, r, h)) }
            }
        }
        pairs.sort {
            if $0.w != $1.w { return $0.w > $1.w }
            if $0.r != $1.r { return $0.r < $1.r }
            return $0.h < $1.h
        }
        var usedRef = Set<Int>()
        var usedHyp = Set<Int>()
        var matched = 0
        for p in pairs where !usedRef.contains(p.r) && !usedHyp.contains(p.h) {
            usedRef.insert(p.r)
            usedHyp.insert(p.h)
            matched += 1
        }
        return matched
    }

    /// nil (Not Applicable) when either side is empty; 0 when both sides have
    /// items but nothing matched — N/A and zero are different signals (§1.5).
    private static func f1Value(matched: Int, refCount: Int, hypCount: Int) -> Double? {
        guard refCount > 0, hypCount > 0 else { return nil }
        let p = Double(matched) / Double(hypCount)
        let r = Double(matched) / Double(refCount)
        return p + r == 0 ? 0 : 2 * p * r / (p + r)
    }
}
