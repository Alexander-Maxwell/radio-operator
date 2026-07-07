import Foundation

/// Shared text normalizer for the eval harness (spec §1.1), applied
/// identically to reference and hypothesis. `version` is recorded in every
/// report; any behavior change here MUST bump it (baseline invalidation, §5.3).
///
/// Divergence from WordErrorRate.normalize, by contract: apostrophes are
/// deleted in place ("jerry's" -> "jerrys", not "jerry's"), "&" -> "and",
/// numerals canonicalize to digits, "$"/"%" become "dollars"/"percent"
/// tokens, fillers are dropped. Hyphens/slashes split as separators exactly
/// like WordErrorRate (en/em dashes added as a strict superset).
enum EvalNormalizer {
    static let version = "1.1"

    /// Pre-merge marker for a "$" money prefix. Emitted BEFORE the amount
    /// token and resolved to a trailing "dollars" token inside
    /// mergeSpelledNumbers, so scaled amounts ("$1.5 million") canonicalize
    /// to ["1500000", "dollars"] instead of splitting the merge with an
    /// adjacent "dollars" token. cleanToken strips "$" from every token, so
    /// this sentinel can never collide with real input.
    private static let dollarsMarker = "$"

    // §1.1 step 4, both sides. "mm-hmm" is unreachable after hyphen splitting
    // (arrives as "mm"+"hmm", both listed) but kept to mirror the spec table.
    private static let fillers: Set<String> = ["uh", "um", "mm", "mm-hmm", "hmm", "erm"]

    private static let separators = CharacterSet.whitespacesAndNewlines
        .union(CharacterSet(charactersIn: "-/\u{2013}\u{2014}"))

    private static let smallNumbers: [String: Int] = [
        "zero": 0, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5,
        "six": 6, "seven": 7, "eight": 8, "nine": 9, "ten": 10, "eleven": 11,
        "twelve": 12, "thirteen": 13, "fourteen": 14, "fifteen": 15,
        "sixteen": 16, "seventeen": 17, "eighteen": 18, "nineteen": 19,
        "twenty": 20, "thirty": 30, "forty": 40, "fifty": 50, "sixty": 60,
        "seventy": 70, "eighty": 80, "ninety": 90,
    ]
    private static let scales: [String: Double] = [
        "thousand": 1_000, "million": 1_000_000,
    ]

    /// Full §1.1 pipeline: NFKC fold -> lowercase -> "&" -> " and " -> split
    /// on whitespace/hyphens/slashes -> per-token punctuation strip with
    /// $/%/k handling -> spelled-cardinal merge -> filler drop.
    static func tokens(_ s: String) -> [String] {
        let folded = s.precomposedStringWithCompatibilityMapping
            .lowercased()
            .replacingOccurrences(of: "&", with: " and ")
        var toks: [String] = []
        for raw in folded.components(separatedBy: separators) where !raw.isEmpty {
            let (core, dollars, percent) = cleanToken(raw)
            let expanded = expandThousandsSuffix(core)
            // Lone "$" (no attached amount) emits nothing: "$ 300" must still
            // money-parse as 300, and a floating "dollars" token would not.
            // The marker precedes the amount; the merge pass moves it to a
            // trailing "dollars" AFTER cardinal/scale merging, so
            // "$1.5 million" -> ["1500000", "dollars"].
            if dollars && !expanded.isEmpty { toks.append(dollarsMarker) }
            if !expanded.isEmpty { toks.append(expanded) }
            if percent { toks.append("percent") }
        }
        toks.removeAll { fillers.contains($0) }
        return mergeSpelledNumbers(toks)
    }

    static func normalizedString(_ s: String) -> String {
        tokens(s).joined(separator: " ")
    }

    /// Numeric-equivalence money parser (spec §1.4 match: money). Accepts the
    /// normalized shapes `[amount]`, `[amount, dollars|dollar]`,
    /// `[amount, cents|cent]` (cents scale /100). Anything else — including
    /// percentages — is nil: "$50" must never equal "50%".
    static func moneyValue(_ s: String) -> Double? {
        let toks = tokens(s)
        guard let first = toks.first, isNumeric(first), let v = Double(first) else {
            return nil
        }
        switch toks.count {
        case 1:
            return v
        case 2:
            switch toks[1] {
            case "dollars", "dollar": return v
            case "cents", "cent": return v / 100
            default: return nil
            }
        default:
            return nil
        }
    }

    // MARK: - Pipeline stages

    /// Keeps letters/digits and digit-internal decimal points; deletes all
    /// other punctuation/symbols in place (commas in digit groups, apostrophes,
    /// stray marks). "$" counts as a money prefix only before any alnum; "%"
    /// counts as a percent suffix only after the last alnum.
    private static func cleanToken(_ raw: String) -> (core: String, dollars: Bool, percent: Bool) {
        let chars = Array(raw)
        var core = ""
        var dollars = false
        var percent = false
        for i in chars.indices {
            let c = chars[i]
            if c.isLetter || c.isNumber {
                core.append(c)
                percent = false
            } else if c == "$" {
                if core.isEmpty { dollars = true }
            } else if c == "%" {
                percent = true
            } else if c == "." {
                let prevIsDigit = core.last.map(isASCIIDigit) ?? false
                let nextIsDigit = i + 1 < chars.count && isASCIIDigit(chars[i + 1])
                if prevIsDigit && nextIsDigit { core.append(c) }
            }
        }
        return (core, dollars, percent)
    }

    /// "75k" -> "75000" (input is already lowercased). Digits+k only, so
    /// ordinary words ending in k ("book", "42nd") pass through.
    private static func expandThousandsSuffix(_ core: String) -> String {
        guard core.hasSuffix("k"), core.count > 1 else { return core }
        let head = String(core.dropLast())
        guard isNumeric(head), let v = Double(head) else { return core }
        return format(v * 1_000)
    }

    /// Spelled-out cardinals up to millions -> digit tokens. A digit token
    /// directly before hundred/thousand/million seeds the accumulator so
    /// "300 thousand" and "1.5 million" canonicalize too. Non-number tokens
    /// flush; malformed sequences degrade to separate numbers, never crash.
    /// A dollarsMarker attaches a "dollars" token AFTER the next emitted
    /// token (merged amount or plain word), so "$1.5 million" merges fully
    /// before the currency word lands.
    private static func mergeSpelledNumbers(_ toks: [String]) -> [String] {
        enum Last { case start, small(Int), hundred, scale }
        var out: [String] = []
        var total = 0.0
        var current = 0.0
        var active = false
        var last = Last.start
        var pendingDollars = false

        func emit(_ token: String) {
            out.append(token)
            if pendingDollars {
                out.append("dollars")
                pendingDollars = false
            }
        }
        func flush() {
            if active { emit(format(total + current)) }
            total = 0; current = 0; active = false; last = .start
        }
        // "twenty five" / "two hundred five" / scale then fresh group extend;
        // "five six", "zero zero", "twenty twenty" do not.
        func canExtend(_ u: Int) -> Bool {
            if current == 0 { if case .scale = last { return true }; return false }
            if case .small(let prev) = last {
                return prev >= 20 && prev % 10 == 0 && (1...9).contains(u)
            }
            if case .hundred = last { return (1...99).contains(u) }
            return false
        }

        var i = 0
        while i < toks.count {
            let t = toks[i]
            if t == dollarsMarker {
                // A number already in progress is not the $-amount: flush it
                // (attaching any earlier pending marker), then arm for the
                // tokens that follow this "$".
                flush()
                pendingDollars = true
            } else if let u = smallNumbers[t] {
                if active && !canExtend(u) { flush() }
                current += Double(u)
                active = true
                last = .small(u)
            } else if t == "hundred" {
                if !active { current = 1; active = true }
                if current == 0 { current = 1 }
                current *= 100
                last = .hundred
            } else if let scale = scales[t] {
                if !active { current = 1; active = true }
                total += (current == 0 ? 1 : current) * scale
                current = 0
                last = .scale
            } else if isNumeric(t), i + 1 < toks.count,
                      toks[i + 1] == "hundred" || scales[toks[i + 1]] != nil,
                      let v = Double(t) {
                flush()
                current = v
                active = true
                last = .scale
            } else {
                flush()
                emit(t)
            }
            i += 1
        }
        flush()
        // "$" whose amount vanished (e.g. "$um" after filler drop): keep the
        // pre-1.1 behavior of a bare trailing "dollars" token.
        if pendingDollars { out.append("dollars") }
        return out
    }

    // MARK: - Helpers

    private static func isASCIIDigit(_ c: Character) -> Bool {
        ("0"..."9").contains(c)
    }

    /// ASCII digits with at most one interior decimal point. Deliberately
    /// stricter than Double.init: "inf", "nan", "1e5" are NOT numbers here.
    private static func isNumeric(_ s: String) -> Bool {
        guard !s.isEmpty else { return false }
        var sawDot = false
        var sawDigit = false
        for c in s {
            if isASCIIDigit(c) { sawDigit = true }
            else if c == "." && !sawDot { sawDot = true }
            else { return false }
        }
        return sawDigit
    }

    /// Whole values render without a decimal ("300000", not "300000.0").
    private static func format(_ v: Double) -> String {
        if v.rounded() == v, abs(v) < 9_000_000_000_000_000 {
            return String(Int64(v))
        }
        return String(v)
    }
}
