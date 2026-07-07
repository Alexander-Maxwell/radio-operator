import Foundation

/// Fixtures for the shared eval normalizer (spec §1.1). Includes the live-
/// money-magnitude failure class ($500,000 vs $1000/$50,000, the D2 case).
enum EvalNormalizerTestCases {
    static func run(_ t: TestContext) {
        t.test("$500,000 canonicalizes to amount plus dollars") { t in
            t.expectEqual(EvalNormalizer.tokens("$500,000"), ["500000", "dollars"], "tokens")
            t.expectEqual(EvalNormalizer.normalizedString("$500,000"), "500000 dollars", "joined")
            t.expectEqual(EvalNormalizer.moneyValue("$500,000") ?? -1, 500_000, "money value")
        }

        t.test("money magnitudes stay distinct (D2 corpus failure)") { t in
            let big = EvalNormalizer.moneyValue("$500,000")
            t.expectEqual(EvalNormalizer.moneyValue("$50,000") ?? -1, 50_000, "$50,000 parses")
            t.expectEqual(EvalNormalizer.moneyValue("$1000") ?? -1, 1_000, "$1000 parses")
            t.expect(big != EvalNormalizer.moneyValue("$50,000"), "$500,000 != $50,000")
            t.expect(big != EvalNormalizer.moneyValue("$1000"), "$500,000 != $1000")
        }

        t.test("spelled cardinals become digits") { t in
            t.expectEqual(EvalNormalizer.normalizedString("five hundred thousand"), "500000", "300k spelled")
            t.expectEqual(EvalNormalizer.tokens("twenty-five"), ["25"], "hyphenated tens+unit")
            t.expectEqual(EvalNormalizer.tokens("two hundred five"), ["205"], "hundred then unit")
            t.expectEqual(EvalNormalizer.tokens("three hundred twenty thousand"), ["320000"], "compound group")
            t.expectEqual(EvalNormalizer.tokens("one million"), ["1000000"], "million scale")
            t.expectEqual(EvalNormalizer.tokens("zero"), ["0"], "zero alone")
        }

        t.test("same amount across surface forms") { t in
            t.expectEqual(EvalNormalizer.moneyValue("$75K") ?? -1, 75_000, "$75K")
            t.expectEqual(EvalNormalizer.tokens("$75K"), ["75000", "dollars"], "$75K tokens")
            t.expectEqual(EvalNormalizer.moneyValue("75000 dollars") ?? -1, 75_000, "digits + dollars")
            t.expectEqual(EvalNormalizer.moneyValue("$75,000") ?? -1, 75_000, "comma group")
            t.expectEqual(EvalNormalizer.moneyValue("five hundred thousand dollars") ?? -1,
                          EvalNormalizer.moneyValue("$500,000") ?? -2, "spelled == symbolic")
        }

        t.test("$ before a scaled amount merges before dollars attaches") { t in
            // Regression: the dollars token used to land between "1.5" and
            // "million", splitting the cardinal/scale merge.
            t.expectEqual(EvalNormalizer.tokens("$1.5 million"), ["1500000", "dollars"], "$1.5 million tokens")
            t.expectEqual(EvalNormalizer.moneyValue("$1.5 million") ?? -1, 1_500_000, "$1.5 million value")
            t.expectEqual(EvalNormalizer.tokens("$500 thousand"), ["500000", "dollars"], "$500 thousand tokens")
            t.expectEqual(EvalNormalizer.moneyValue("$500 thousand") ?? -1, 500_000, "$500 thousand value")
            t.expectEqual(EvalNormalizer.tokens("$five hundred thousand"),
                          ["500000", "dollars"], "spelled amount after $ merges too")
            t.expectEqual(EvalNormalizer.moneyValue("$ 300") ?? -1, 300, "lone $ still emits nothing")
        }

        t.test("cents scale to fractional dollars") { t in
            t.expectEqual(EvalNormalizer.moneyValue("50 cents") ?? -1, 0.5, "50 cents")
            t.expectEqual(EvalNormalizer.moneyValue("1 cent") ?? -1, 0.01, "singular cent")
        }

        t.test("non-money strings return nil") { t in
            t.expect(EvalNormalizer.moneyValue("hello there") == nil, "words")
            t.expect(EvalNormalizer.moneyValue("") == nil, "empty")
            t.expect(EvalNormalizer.moneyValue("uh") == nil, "filler only")
            t.expect(EvalNormalizer.moneyValue("50 percent") == nil, "percent is not money")
            t.expect(EvalNormalizer.moneyValue("dollars") == nil, "unit without amount")
        }

        t.test("plain numbers parse as values") { t in
            t.expectEqual(EvalNormalizer.moneyValue("500000") ?? -1, 500_000, "bare integer")
            t.expectEqual(EvalNormalizer.moneyValue("12.5") ?? -1, 12.5, "bare decimal")
            t.expectEqual(EvalNormalizer.tokens("75K"), ["75000"], "k-suffix without $, no dollars token")
        }

        t.test("ampersand and possessive: Ben & Jerry's") { t in
            t.expectEqual(EvalNormalizer.tokens("Ben & Jerry's"), ["ben", "and", "jerrys"], "brand fixture")
        }

        t.test("fillers dropped") { t in
            t.expectEqual(EvalNormalizer.tokens("uh um so yeah mm-hmm erm hmm mm"),
                          ["so", "yeah"], "all six filler forms removed")
        }

        t.test("percent sign becomes percent token") { t in
            t.expectEqual(EvalNormalizer.tokens("50%"), ["50", "percent"], "attached")
            t.expectEqual(EvalNormalizer.tokens("rate is 12.5%"), ["rate", "is", "12.5", "percent"], "decimal")
            t.expectEqual(EvalNormalizer.tokens("%"), ["percent"], "bare sign")
        }

        t.test("NFKC compatibility fold plus case fold") { t in
            t.expectEqual(EvalNormalizer.tokens("ＫＥＬＢＯ ＦＩＺＺ"), ["kelbo", "fizz"], "fullwidth letters")
            t.expectEqual(EvalNormalizer.tokens("ﬁnal ﬁgures"), ["final", "figures"], "fi ligature")
            t.expectEqual(EvalNormalizer.tokens("LOUD Noise"), ["loud", "noise"], "case folds")
        }

        t.test("hyphen/slash split parity with WordErrorRate.normalize") { t in
            // No numerals/fillers/apostrophes: the two normalizers must agree.
            let a = "state-of-the-art and/or check-in"
            t.expectEqual(EvalNormalizer.tokens(a), WordErrorRate.normalize(a), "compound words")
            let b = "Wrap-up, then follow-up."
            t.expectEqual(EvalNormalizer.tokens(b), WordErrorRate.normalize(b), "edge punctuation")
        }

        t.test("apostrophes deleted in place, not separators") { t in
            t.expectEqual(EvalNormalizer.tokens("don't stop"), ["dont", "stop"], "ascii apostrophe")
            t.expectEqual(EvalNormalizer.tokens("don\u{2019}t stop"), ["dont", "stop"], "curly apostrophe")
        }

        t.test("digit-group commas removed; version pinned") { t in
            t.expectEqual(EvalNormalizer.tokens("500,000"), ["500000"], "one group")
            t.expectEqual(EvalNormalizer.tokens("1,234,567"), ["1234567"], "two groups")
            // 1.0 -> 1.1: "$<amount> <scale>" now merges before the dollars
            // token attaches (module contract: behavior change bumps version).
            t.expectEqual(EvalNormalizer.version, "1.1", "normalizer version")
            t.expectEqual(EvalNormalizer.normalizedString("Hello,  World"), "hello world", "join + collapse")
        }
    }
}
