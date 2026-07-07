import Foundation

/// AttributionMetrics (spec §1.2–1.3): alignment pairs, per-track WER with
/// scored:false exclusion, 2-party attribution, collapse, bleed windows.
enum EvalAlignmentTestCases {
    static func run(_ t: TestContext) {
        t.test("alignmentPairs: pure deletion") { t in
            let pairs = AttributionMetrics.alignmentPairs(ref: ["a", "b", "c"], hyp: ["a", "c"])
            t.expectEqual(fmt(pairs), "0:0 1:- 2:1", "b deleted, a/c matched")
            t.expectEqual(fmt(AttributionMetrics.alignmentPairs(ref: [], hyp: [])), "", "both empty")
            t.expectEqual(fmt(AttributionMetrics.alignmentPairs(ref: ["x", "y"], hyp: [])),
                          "0:- 1:-", "empty hyp is all deletions")
        }
        t.test("alignmentPairs: insertion and substitution") { t in
            let ins = AttributionMetrics.alignmentPairs(ref: ["a", "b"], hyp: ["a", "x", "b"])
            t.expectEqual(fmt(ins), "0:0 -:1 1:2", "x inserted between matches")
            let sub = AttributionMetrics.alignmentPairs(ref: ["a", "b"], hyp: ["a", "x"])
            t.expectEqual(fmt(sub), "0:0 1:1", "b→x substitution pairs indices")
            t.expectEqual(fmt(AttributionMetrics.alignmentPairs(ref: [], hyp: ["p", "q"])),
                          "-:0 -:1", "empty ref is all insertions")
        }
        t.test("alignmentPairs: S/D/I agrees with WordErrorRate.align") { t in
            let ref = WordErrorRate.normalize("the quick brown fox jumps over the lazy dog")
            let hyp = WordErrorRate.normalize("the quack fox jumps over a lazy dog now")
            let expected = WordErrorRate.align(ref: ref, hyp: hyp)
            let got = sdi(ref: ref, hyp: hyp)
            t.expectEqual(got.s, expected.substitutions, "substitutions")
            t.expectEqual(got.d, expected.deletions, "deletions")
            t.expectEqual(got.i, expected.insertions, "insertions")
        }

        t.test("perTrackWER: clean me track scores zero") { t in
            let r = ref([seg(1, "me", 0, 3, "we need the budget numbers")])
            let n = note([line("Me", 0, "we need the budget numbers")])
            let w = AttributionMetrics.perTrackWER(reference: r, hyp: n, track: "me")
            t.expect(w.notApplicableReason == nil, "applicable")
            t.expectEqual(w.score?.referenceCount ?? -1, 5, "N counts ref tokens")
            t.expectEqual(w.score?.errors ?? -1, 0, "no errors")
        }
        t.test("perTrackWER: Not Applicable without scored segments") { t in
            let r = ref([seg(1, "me", 0, 2, "inaudible mumbling", scored: false),
                         seg(2, "them", 3, 5, "clear speech")])
            let w = AttributionMetrics.perTrackWER(reference: r, hyp: note([line("Me", 0, "hello")]),
                                                   track: "me")
            t.expect(w.score == nil, "score nil when track has no scored segments")
            t.expect(w.notApplicableReason?.isEmpty == false, "reason stated")
        }
        t.test("perTrackWER: scored segments that normalize to zero tokens are N/A") { t in
            // Regression: all-filler scored text used to reach Score.rate with
            // referenceCount 0, surfacing a raw insertion count.
            let r = ref([seg(1, "me", 0, 2, "uh um hmm")])
            let n = note([line("Me", 0, "actual words here")])
            let w = AttributionMetrics.perTrackWER(reference: r, hyp: n, track: "me")
            t.expect(w.score == nil, "score nil when scored ref normalizes to empty")
            t.expect(w.notApplicableReason?.contains("zero tokens") == true,
                     "reason states the empty normalization: \(w.notApplicableReason ?? "nil")")
        }
        t.test("perTrackWER: non-scored ±2s region forgives insertions") { t in
            let r = ref([seg(1, "me", 0, 2, "alpha bravo charlie"),
                         seg(2, "me", 10, 12, "overlap mumble", scored: false)])
            let n = note([line("Me", 0, "alpha bravo charlie"),
                          line("Me", 10.5, "some stray words")])
            let w = AttributionMetrics.perTrackWER(reference: r, hyp: n, track: "me")
            t.expectEqual(w.score?.referenceCount ?? -1, 3, "N excludes non-scored text")
            t.expectEqual(w.score?.insertions ?? -1, 0, "insertions near non-scored forgiven")
            t.expectEqual(w.score?.errors ?? -1, 0, "rate zero overall")
        }
        t.test("perTrackWER: insertions outside the window still count") { t in
            let r = ref([seg(1, "me", 0, 2, "alpha bravo charlie"),
                         seg(2, "me", 10, 12, "overlap mumble", scored: false)])
            let n = note([line("Me", 0, "alpha bravo charlie"),
                          line("Me", 30, "some stray words")])
            let w = AttributionMetrics.perTrackWER(reference: r, hyp: n, track: "me")
            t.expectEqual(w.score?.insertions ?? -1, 3, "far line's tokens are insertions")
        }
        t.test("perTrackWER: non-Me speaker token lands on them track") { t in
            let r = ref([seg(1, "them", 0, 2, "status update complete")])
            let n = note([line("Sarah", 0, "status update complete")])
            let them = AttributionMetrics.perTrackWER(reference: r, hyp: n, track: "them")
            t.expectEqual(them.score?.errors ?? -1, 0, "Sarah line grades the them track")
            t.expectEqual(them.score?.referenceCount ?? -1, 3, "them N")
            let me = AttributionMetrics.perTrackWER(reference: r, hyp: n, track: "me")
            t.expect(me.score == nil, "me track Not Applicable in them-only reference")
        }

        t.test("attribution: perfect 2-party") { t in
            let r = ref([seg(1, "me", 0, 2, "we need the budget"),
                         seg(2, "them", 6, 8, "sounds good to me")])
            let n = note([line("Me", 0, "we need the budget"),
                          line("Them", 6, "sounds good to me")])
            let a = AttributionMetrics.attribution(reference: r, hyp: n, roster: roster)
            t.expect(approx(a.accuracy, 1.0), "accuracy 1.0, got \(String(describing: a.accuracy))")
            t.expectEqual(a.alignedTokens, 8, "all tokens aligned")
            t.expectEqual(a.correctTokens, 8, "all labels correct")
            t.expect(!a.collapseFlag, "no collapse")
        }
        t.test("attribution: bleed fixture halves accuracy and sets bleedThem") { t in
            // Me speech duplicated onto the Them track (D1-A shape).
            let r = ref([seg(1, "me", 0, 2, "we need the budget"),
                         seg(2, "them", 6, 8, "sounds good to me")])
            let n = note([line("Them", 0, "we need the budget"),
                          line("Them", 6, "sounds good to me")])
            let a = AttributionMetrics.attribution(reference: r, hyp: n, roster: roster)
            t.expect(approx(a.accuracy, 0.5), "half the aligned tokens mislabeled")
            t.expectEqual(a.alignedTokens, 8, "aligned")
            t.expectEqual(a.correctTokens, 4, "correct")
            t.expect(approx(a.bleedRateThem, 0.5), "4 of 8 them tokens duplicate me speech")
            t.expect(a.bleedRateMe == nil, "no me hyp tokens → me bleed undefined")
        }
        t.test("attribution: collapse fires at ≥50 me tokens with 0 Me lines") { t in
            let fifty2 = words26 + " " + words26                     // 52 tokens
            let r = ref([seg(1, "me", 0, 30, fifty2)])
            let n = note([line("Them", 0, fifty2)])                  // all-Them failure
            let a = AttributionMetrics.attribution(reference: r, hyp: n, roster: roster)
            t.expect(a.collapseFlag, "collapse flagged")
            t.expect(a.collapseDetail?.isEmpty == false, "detail present")
            t.expect(approx(a.accuracy, 0.0), "every aligned token mislabeled")
        }
        t.test("attribution: no collapse under 50 me tokens") { t in
            let r = ref([seg(1, "me", 0, 15, words26)])              // 26 tokens
            let n = note([line("Them", 0, words26)])
            let a = AttributionMetrics.attribution(reference: r, hyp: n, roster: roster)
            t.expect(!a.collapseFlag, "26 < 50 gate: mislabeled but not collapse")
            t.expect(a.collapseDetail == nil, "no detail without flag")
        }
        t.test("attribution: bleed obeys the ±3s window") { t in
            let r = ref([seg(1, "me", 0, 2, "hello there friend"),
                         seg(2, "them", 10, 12, "the quarterly forecast numbers")])
            let inWindow = note([line("Me", 0, "hello there friend"),
                                 line("Me", 11, "the quarterly forecast numbers")])
            let a = AttributionMetrics.attribution(reference: r, hyp: inWindow, roster: roster)
            t.expect(approx(a.bleedRateMe, 4.0 / 7.0), "duplicated line at 11s inside [7,15] bleeds")
            let outWindow = note([line("Me", 0, "hello there friend"),
                                  line("Me", 25, "the quarterly forecast numbers")])
            let b = AttributionMetrics.attribution(reference: r, hyp: outWindow, roster: roster)
            t.expect(approx(b.bleedRateMe, 0.0), "same duplicate at 25s outside window: no bleed")
        }
        t.test("attribution: bleed containment catches a short fully-bled line") { t in
            // Regression: whole-set Jaccard scored a fully-contained 3-token
            // line inside a 26-token segment at ~0.12 and missed it.
            let r = ref([seg(1, "me", 0, 2, "hello there friend"),
                         seg(2, "them", 10, 12, words26)])
            let bled = note([line("Me", 0, "hello there friend"),
                             line("Me", 11, "alpha bravo charlie")])
            let a = AttributionMetrics.attribution(reference: r, hyp: bled, roster: roster)
            t.expect(approx(a.bleedRateMe, 3.0 / 6.0), "contained 3-token line bleeds, got \(String(describing: a.bleedRateMe))")
            let clean = note([line("Me", 0, "hello there friend"),
                              line("Me", 11, "totally unrelated words")])
            let b = AttributionMetrics.attribution(reference: r, hyp: clean, roster: roster)
            t.expect(approx(b.bleedRateMe, 0.0), "genuinely different line does not fire")
            let partial = note([line("Me", 0, "hello there friend"),
                                line("Me", 11, "alpha bravo unrelated")])
            let c = AttributionMetrics.attribution(reference: r, hyp: partial, roster: roster)
            t.expect(approx(c.bleedRateMe, 0.0), "2/3 containment stays under the 0.8 bar")
        }
        t.test("attribution: not gradeable without scored reference tokens") { t in
            let r = ref([seg(1, "me", 0, 2, "crosstalk", scored: false),
                         seg(2, "them", 3, 5, "crosstalk", scored: false)])
            let n = note([line("Me", 0, "unrelated words here")])
            let a = AttributionMetrics.attribution(reference: r, hyp: n, roster: roster)
            t.expect(a.accuracy == nil, "accuracy nil")
            t.expectEqual(a.alignedTokens, 0, "nothing aligned")
            t.expect(!a.collapseFlag, "no collapse without scored me tokens")
        }
    }

    // MARK: - Fixtures

    private static let words26 = "alpha bravo charlie delta echo foxtrot golf hotel india"
        + " juliett kilo lima mike november oscar papa quebec romeo sierra tango uniform"
        + " victor whiskey xray yankee zulu"

    private static func seg(_ id: Int, _ track: String, _ start: Double, _ end: Double,
                            _ text: String, scored: Bool = true) -> GoldenReference.Segment {
        GoldenReference.Segment(id: id, track: track, speaker: track == "me" ? "S1" : "S2",
                                start_s: start, end_s: end, text: text, score: scored, terms: nil)
    }

    private static func ref(_ segments: [GoldenReference.Segment]) -> GoldenReference {
        GoldenReference(schema_version: "1", meeting_id: "m-test", segments: segments,
                        reference_summary: nil,
                        provenance: .init(transcript_draft_source: nil, human_passes: nil,
                                          summary_authored_blind: nil))
    }

    private static func line(_ speaker: String, _ tRel: Double, _ text: String) -> HypNote.Line {
        HypNote.Line(speaker: speaker, timestamp: "00:00:00", tRel: tRel, text: text)
    }

    private static func note(_ lines: [HypNote.Line]) -> HypNote {
        HypNote(frontmatter: ["source": "Radio Operator"], hasFrontmatter: true,
                headings: ["Transcript"], transcript: lines, summaryBullets: [],
                decisions: [], actionItems: [], isMeetingNote: true)
    }

    private static var roster: RosterMap {
        RosterMap(meta: GoldenMeta(
            meeting_id: "m-test", strata: ["clean"], environment: nil, noise: nil,
            duration_seconds: 60,
            participants: [
                .init(id: "S1", track: "me", display: "Maxwell", aliases: ["Me", "Alex"]),
                .init(id: "S2", track: "them", display: "Jordan", aliases: ["Them"]),
            ],
            hypothesis_note: nil))
    }

    // MARK: - Helpers

    private static func fmt(_ pairs: [(r: Int?, h: Int?)]) -> String {
        pairs.map { "\($0.r.map(String.init) ?? "-"):\($0.h.map(String.init) ?? "-")" }
            .joined(separator: " ")
    }

    private static func sdi(ref: [String], hyp: [String]) -> (s: Int, d: Int, i: Int) {
        var s = 0, d = 0, ins = 0
        for p in AttributionMetrics.alignmentPairs(ref: ref, hyp: hyp) {
            switch (p.r, p.h) {
            case let (ri?, hi?): if ref[ri] != hyp[hi] { s += 1 }
            case (.some, nil): d += 1
            case (nil, .some): ins += 1
            case (nil, nil): break
            }
        }
        return (s, d, ins)
    }

    private static func approx(_ a: Double?, _ b: Double) -> Bool {
        guard let a else { return false }
        return abs(a - b) < 1e-9
    }
}
