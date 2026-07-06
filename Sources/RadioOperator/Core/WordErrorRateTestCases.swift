import Foundation

/// Known-answer tests for the WER/CER scorer that gates every future engine
/// decision — if the ruler is wrong, every benchmark is wrong.
enum WordErrorRateTestCases {
    static func run(_ t: TestContext) {
        t.test("identical strings score zero") { t in
            let s = WordErrorRate.score(reference: "the quick brown fox", hypothesis: "the quick brown fox")
            t.expectEqual(s.errors, 0, "no errors")
            t.expectEqual(s.rate, 0, "rate zero")
            t.expectEqual(s.referenceCount, 4, "reference words counted")
        }

        t.test("case and punctuation are normalized away") { t in
            let s = WordErrorRate.score(reference: "Hello, world!", hypothesis: "hello world")
            t.expectEqual(s.errors, 0, "formatting differences are not errors")
        }

        t.test("single substitution in four words is 25%") { t in
            let s = WordErrorRate.score(reference: "the cat sat down", hypothesis: "the hat sat down")
            t.expectEqual(s.substitutions, 1, "one substitution")
            t.expectEqual(s.deletions, 0, "no deletions")
            t.expectEqual(s.insertions, 0, "no insertions")
            t.expectEqual(s.rate, 0.25, "1/4")
        }

        t.test("deletion counted against reference") { t in
            let s = WordErrorRate.score(reference: "a b c d", hypothesis: "a b c")
            t.expectEqual(s.deletions, 1, "one deletion")
            t.expectEqual(s.rate, 0.25, "1/4")
        }

        t.test("insertions counted") { t in
            let s = WordErrorRate.score(reference: "a b c", hypothesis: "a x b c y")
            t.expectEqual(s.insertions, 2, "two insertions")
            t.expectEqual(s.substitutions, 0, "no substitutions")
            t.expect(abs(s.rate - 2.0 / 3.0) < 0.0001, "2/3")
        }

        t.test("mixed errors backtrace correctly") { t in
            // ref: "one two three four" hyp: "one too three" → 1 sub + 1 del
            let s = WordErrorRate.score(reference: "one two three four", hypothesis: "one too three")
            t.expectEqual(s.substitutions, 1, "sub for two→too")
            t.expectEqual(s.deletions, 1, "del for four")
            t.expectEqual(s.errors, 2, "total 2")
        }

        t.test("empty reference edge cases") { t in
            let empty = WordErrorRate.score(reference: "", hypothesis: "")
            t.expectEqual(empty.rate, 0, "empty vs empty is 0")
            let ins = WordErrorRate.score(reference: "", hypothesis: "hello there")
            t.expectEqual(ins.insertions, 2, "hypothesis words become insertions")
            t.expectEqual(ins.referenceCount, 0, "no reference words")
        }

        t.test("empty hypothesis is all deletions") { t in
            let s = WordErrorRate.score(reference: "a b c", hypothesis: "")
            t.expectEqual(s.deletions, 3, "all deleted")
            t.expectEqual(s.rate, 1.0, "100% WER")
        }

        t.test("character score catches near-miss words") { t in
            // "kinaxis" vs "kinaxus": 1 word error but only 1 char error in 7.
            let wer = WordErrorRate.score(reference: "kinaxis", hypothesis: "kinaxus")
            t.expectEqual(wer.rate, 1.0, "whole word wrong")
            let cer = WordErrorRate.characterScore(reference: "kinaxis", hypothesis: "kinaxus")
            t.expectEqual(cer.substitutions, 1, "one character substituted")
            t.expect(cer.rate < 0.2, "CER far below WER")
        }

        t.test("percent label is deterministic") { t in
            t.expectEqual(WordErrorRate.percent(0.25), "25.0%", "quarter")
            t.expectEqual(WordErrorRate.percent(0), "0.0%", "zero")
            t.expectEqual(WordErrorRate.percent(0.11239), "11.2%", "one decimal")
        }
    }
}
