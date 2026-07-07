import Foundation

/// TermMetrics (§1.4) fixtures: exact rule (no Kelbow Fizz fuzzy credit),
/// alias credit, money equivalence incl. the D2 $500,000 catch, inclusive
/// window edges, track gating, per-category counts, miss reporting.
enum EvalTermsTestCases {

    // MARK: fixture builders

    private static func seg(_ id: Int, track: String, _ start: Double, _ end: Double,
                            terms: [(String, String)]) -> GoldenReference.Segment {
        GoldenReference.Segment(
            id: id, track: track, speaker: track == "me" ? "S1" : "S2",
            start_s: start, end_s: end, text: "", score: true,
            terms: terms.map { GoldenReference.TermTag(term: $0.0, category: $0.1) })
    }

    private static func ref(_ segments: [GoldenReference.Segment]) -> GoldenReference {
        GoldenReference(
            schema_version: "1", meeting_id: "m-terms", segments: segments,
            reference_summary: nil,
            provenance: .init(transcript_draft_source: nil, human_passes: nil,
                              summary_authored_blind: nil))
    }

    private static func line(_ speaker: String, _ tRel: Double, _ text: String) -> HypNote.Line {
        HypNote.Line(speaker: speaker, timestamp: "00:00:00", tRel: tRel, text: text)
    }

    private static func note(_ lines: [HypNote.Line]) -> HypNote {
        HypNote(frontmatter: ["source": "Radio Operator"], hasFrontmatter: true,
                headings: [], transcript: lines, summaryBullets: [], decisions: [],
                actionItems: [], isMeetingNote: true)
    }

    private static func term(_ canonical: String, _ category: String,
                             aliases: [String] = [], match: String? = nil) -> TermsFile.Term {
        TermsFile.Term(canonical: canonical, category: category, aliases: aliases, match: match)
    }

    private static func file(_ terms: [TermsFile.Term]) -> TermsFile {
        TermsFile(version: 1, terms: terms)
    }

    static func run(_ t: TestContext) {
        // "Kelbo Fizz" tagged on a them segment 20-30s -> window [15, 35].
        let topoRef = ref([seg(1, track: "them", 20, 30, terms: [("Kelbo Fizz", "brand")])])
        let topoTerms = file([term("Kelbo Fizz", "brand")])
        // "$500,000" tagged on a me segment 10-20s -> window [5, 25].
        let moneyRef = ref([seg(3, track: "me", 10, 20, terms: [("$500,000", "money")])])
        let moneyTerms = file([term("$500,000", "money", match: "money")])

        t.test("exact canonical hit credits the occurrence") { t in
            let r = TermMetrics.score(
                reference: topoRef,
                hyp: note([line("Them", 22, "we stocked Kelbo Fizz this week")]),
                terms: topoTerms)
            t.expectEqual(r.total, 1, "one tagged occurrence")
            t.expectEqual(r.correct, 1, "credited")
            t.expect(r.misses.isEmpty, "no misses")
            t.expectEqual(r.accuracy ?? -1, 1.0, "accuracy 1.0")
        }

        t.test("Kelbow Fizz mishearing gets no fuzzy credit") { t in
            let r = TermMetrics.score(
                reference: topoRef,
                hyp: note([line("Them", 22, "we stocked Kelbow Fizz this week")]),
                terms: topoTerms)
            t.expectEqual(r.correct, 0, "exact rule, no fuzzy credit")
            t.expectEqual(r.misses, ["Kelbo Fizz @ 1"], "miss carries canonical @ segment-id")
        }

        t.test("alias earns credit") { t in
            let r = TermMetrics.score(
                reference: ref([seg(2, track: "them", 0, 10, terms: [("MoonBalls", "brand")])]),
                hyp: note([line("Them", 4, "the Moon Balls order shipped")]),
                terms: file([term("MoonBalls", "brand", aliases: ["Moon Balls"])]))
            t.expectEqual(r.correct, 1, "alias match")
        }

        t.test("money equivalence across surface forms") { t in
            for text in ["the budget is $500,000 firm",
                         "the budget is 500000 dollars firm",
                         "the budget is $500K firm"] {
                let r = TermMetrics.score(reference: moneyRef,
                                          hyp: note([line("Me", 12, text)]),
                                          terms: moneyTerms)
                t.expectEqual(r.correct, 1, "should credit: \(text)")
            }
        }

        t.test("D2 catch: $50,000 is not $500,000") { t in
            let r = TermMetrics.score(reference: moneyRef,
                                      hyp: note([line("Me", 12, "the budget is $50,000 firm")]),
                                      terms: moneyTerms)
            t.expectEqual(r.correct, 0, "magnitude must match exactly")
            t.expectEqual(r.misses, ["$500,000 @ 3"], "money miss recorded")
        }

        t.test("money route credits a bare figure without currency word") { t in
            let r = TermMetrics.score(reference: moneyRef,
                                      hyp: note([line("Me", 12, "we said 500000 flat")]),
                                      terms: moneyTerms)
            t.expectEqual(r.correct, 1, "plain 500000 parses to the same value")
        }

        t.test("window edges are inclusive") { t in
            let atStart = TermMetrics.score(reference: topoRef,
                                            hyp: note([line("Them", 15.0, "kelbo fizz")]),
                                            terms: topoTerms)
            t.expectEqual(atStart.correct, 1, "tRel == start_s - 5 counts")
            let atEnd = TermMetrics.score(reference: topoRef,
                                          hyp: note([line("Them", 35.0, "kelbo fizz")]),
                                          terms: topoTerms)
            t.expectEqual(atEnd.correct, 1, "tRel == end_s + 5 counts")
        }

        t.test("lines outside the window earn nothing") { t in
            // The early line's interval is bounded by its successor at 14.9,
            // so it ends before the window opens at 15. (Under the pre-overlap
            // rule this fixture was a single line at 14.9; a lone line now
            // rightly extends into the window, which the next test asserts.)
            let early = TermMetrics.score(reference: topoRef,
                                          hyp: note([line("Them", 5, "kelbo fizz"),
                                                     line("Them", 14.9, "moving on now")]),
                                          terms: topoTerms)
            t.expectEqual(early.correct, 0, "turn over before start_s - 5")
            let late = TermMetrics.score(reference: topoRef,
                                         hyp: note([line("Them", 35.1, "kelbo fizz")]),
                                         terms: topoTerms)
            t.expectEqual(late.correct, 0, "starts after end_s + 5")
        }

        t.test("long turn overlapping the window from before is credited") { t in
            // Starts 20s before the tagged segment (tRel 0, segment at 20-30)
            // but the turn interval [0, 30) runs into the window [15, 35].
            // Regression: the start-point rule called this a miss.
            let r = TermMetrics.score(
                reference: topoRef,
                hyp: note([line("Them", 0,
                                "long update that eventually mentions Kelbo Fizz stock")]),
                terms: topoTerms)
            t.expectEqual(r.correct, 1, "overlapping turn carries the term")
            // Same start, but a successor line ends the turn before the window.
            let bounded = TermMetrics.score(
                reference: topoRef,
                hyp: note([line("Them", 0, "mentions Kelbo Fizz early"),
                           line("Them", 12, "different topic in the window")]),
                terms: topoTerms)
            t.expectEqual(bounded.correct, 0, "turn truncated at 12s never reaches 15s")
        }

        t.test("wrong-track occurrence not credited") { t in
            let r = TermMetrics.score(reference: topoRef,
                                      hyp: note([line("Me", 22, "kelbo fizz")]),
                                      terms: topoTerms)
            t.expectEqual(r.correct, 0, "them-tagged segment needs a them line")
            t.expectEqual(r.misses, ["Kelbo Fizz @ 1"])
        }

        t.test("any line inside the window can carry the term") { t in
            let r = TermMetrics.score(
                reference: topoRef,
                hyp: note([line("Them", 21, "let me check the list"),
                           line("Them", 28, "yes, Kelbo Fizz is on it")]),
                terms: topoTerms)
            t.expectEqual(r.correct, 1, "second window line hits")
        }

        t.test("containment is token-boundary, not raw substring") { t in
            let r = TermMetrics.score(
                reference: ref([seg(4, track: "them", 0, 10, terms: [("EMO", "org")])]),
                hyp: note([line("Them", 3, "the memory display is up")]),
                terms: file([term("EMO", "org")]))
            t.expectEqual(r.correct, 0, "\"emo\" inside \"memory\" is not a hit")
        }

        t.test("perCategory splits totals and misses name segments") { t in
            let r = TermMetrics.score(
                reference: ref([
                    seg(1, track: "them", 0, 10, terms: [("Kelbo Fizz", "brand")]),
                    seg(2, track: "them", 20, 30, terms: [("MoonBalls", "brand")]),
                    seg(3, track: "me", 40, 50, terms: [("$500,000", "money")]),
                ]),
                hyp: note([line("Them", 2, "kelbo fizz on shelf"),
                           line("Them", 25, "the turbo balls arrived"),
                           line("Me", 44, "about 500000 dollars")]),
                terms: file([term("Kelbo Fizz", "brand"),
                             term("MoonBalls", "brand", aliases: ["Moon Balls"]),
                             term("$500,000", "money", match: "money")]))
            t.expectEqual(r.total, 3)
            t.expectEqual(r.correct, 2)
            t.expectEqual(r.perCategory["brand"]?.total ?? -1, 2, "brand total")
            t.expectEqual(r.perCategory["brand"]?.correct ?? -1, 1, "brand correct")
            t.expectEqual(r.perCategory["money"]?.total ?? -1, 1, "money total")
            t.expectEqual(r.perCategory["money"]?.correct ?? -1, 1, "money correct")
            t.expectEqual(r.misses, ["MoonBalls @ 2"], "only the miss listed")
        }

        t.test("tag missing from terms file falls back to exact on the tag text") { t in
            let r = TermMetrics.score(
                reference: ref([seg(6, track: "me", 0, 10, terms: [("Coupa", "org")])]),
                hyp: note([line("Me", 5, "log it in Coupa today")]),
                terms: file([]))
            t.expectEqual(r.correct, 1, "unlisted tag still graded")
            t.expectEqual(r.perCategory["org"]?.total ?? -1, 1, "category from the tag")
        }

        t.test("no tagged occurrences means accuracy N/A, not zero") { t in
            let r = TermMetrics.score(
                reference: ref([seg(5, track: "them", 0, 5, terms: [])]),
                hyp: note([]),
                terms: topoTerms)
            t.expectEqual(r.total, 0)
            t.expect(r.accuracy == nil, "nil accuracy when nothing is tagged")
            t.expect(r.perCategory.isEmpty, "no category buckets")
        }
    }
}
