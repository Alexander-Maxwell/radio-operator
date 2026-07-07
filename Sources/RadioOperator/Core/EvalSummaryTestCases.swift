import Foundation

/// SummaryMetrics: action-item F1 (spec §1.5) + hallucinated owners (§1.6).
/// Micro-averaged pooling across meetings is caller-side and untested here
/// by design — the API under test is strictly per-meeting.
enum EvalSummaryTestCases {

    private static func twoParty() -> RosterMap {
        RosterMap(meta: GoldenMeta(
            meeting_id: "eval-2p", strata: ["clean"], environment: nil, noise: nil,
            duration_seconds: 600,
            participants: [
                .init(id: "S1", track: "me", display: "Maxwell", aliases: ["Alex"]),
                .init(id: "S2", track: "them", display: "Jordan Lee", aliases: ["Jordan"]),
            ],
            hypothesis_note: nil))
    }

    private static func threeParty() -> RosterMap {
        RosterMap(meta: GoldenMeta(
            meeting_id: "eval-3p", strata: ["clean"], environment: nil, noise: nil,
            duration_seconds: 600,
            participants: [
                .init(id: "S1", track: "me", display: "Maxwell", aliases: ["Alex"]),
                .init(id: "S2", track: "them", display: "Jordan Lee", aliases: ["Jordan"]),
                .init(id: "S3", track: "them", display: "Sam Woo", aliases: ["Sam"]),
            ],
            hypothesis_note: nil))
    }

    private static func refItem(_ task: String, _ owner: String? = nil) -> GoldenReference.ActionItem {
        .init(task: task, owner: owner, due: nil)
    }

    private static func hypItem(_ task: String, _ owner: String? = nil) -> HypNote.ActionItem {
        .init(raw: task, task: task, owner: owner, due: nil, checked: false)
    }

    static func run(_ t: TestContext) {
        t.test("exact match scores F1 1.0") { t in
            let r = SummaryMetrics.actionItemF1(
                refItems: [refItem("send pricing deck", "Maxwell"),
                           refItem("book venue tour", "Jordan")],
                hypItems: [hypItem("send pricing deck", "Maxwell"),
                           hypItem("book venue tour", "Jordan")],
                roster: twoParty())
            t.expectEqual(r.matched, 2, "matched")
            t.expectEqual(r.precision, 1.0, "precision")
            t.expectEqual(r.recall, 1.0, "recall")
            t.expectEqual(r.f1, 1.0, "f1")
            t.expectEqual(r.sensitivity["0.5"], 1.0, "sens 0.5")
            t.expectEqual(r.sensitivity["0.7"], 1.0, "sens 0.7")
        }

        t.test("stopwords do not block a match") { t in
            let r = SummaryMetrics.actionItemF1(
                refItems: [refItem("Send the deck to Jordan")],
                hypItems: [hypItem("send deck Jordan")],
                roster: twoParty())
            t.expectEqual(r.matched, 1, "stopword-stripped tasks identical")
            t.expectEqual(r.f1, 1.0, "f1")
        }

        t.test("owner mismatch blocks an otherwise identical pair") { t in
            let r = SummaryMetrics.actionItemF1(
                refItems: [refItem("send pricing deck", "Maxwell")],
                hypItems: [hypItem("send pricing deck", "Jordan")],
                roster: twoParty())
            t.expectEqual(r.matched, 0, "sim 1.0 but owners differ")
            t.expectEqual(r.f1, 0.0, "f1 zero, not N/A")
            t.expectEqual(r.sensitivity["0.5"], 0.0, "owner gate holds at every threshold")
        }

        t.test("nil owner pairs only with nil owner") { t in
            let roster = twoParty()
            let blocked = SummaryMetrics.actionItemF1(
                refItems: [refItem("circulate meeting recap")],
                hypItems: [hypItem("circulate meeting recap", "Maxwell")],
                roster: roster)
            t.expectEqual(blocked.matched, 0, "unowned ref vs owned hyp")
            let ok = SummaryMetrics.actionItemF1(
                refItems: [refItem("circulate meeting recap")],
                hypItems: [hypItem("circulate meeting recap")],
                roster: roster)
            t.expectEqual(ok.matched, 1, "unowned vs unowned")
        }

        t.test("optimal assignment beats greedy on crafted 2x2") { t in
            // Jaccards: (r0,h0)=9/10 greedy bait, (r0,h1)=6/9, (r1,h0)=7/11,
            // (r1,h1)=3/11 (never eligible). Greedy takes 0.90 and strands
            // r1 -> 1 match; optimal takes both cross pairs (1.303 > 0.90).
            let r = SummaryMetrics.actionItemF1(
                refItems: [
                    refItem("alpha bravo canyon delta ember falcon garnet harbor indigo"),
                    refItem("delta ember falcon garnet harbor indigo juniper kestrel"),
                ],
                hypItems: [
                    hypItem("alpha bravo canyon delta ember falcon garnet harbor indigo juniper"),
                    hypItem("alpha bravo canyon delta ember falcon"),
                ],
                roster: twoParty())
            t.expectEqual(r.matched, 2, "optimal keeps both cross pairs")
            t.expectEqual(r.f1, 1.0, "f1")
            t.expectEqual(r.sensitivity["0.5"], 1.0, "cross pairs survive 0.5")
            t.expectEqual(r.sensitivity["0.7"], 0.5, "only the bait pair survives 0.7")
        }

        t.test("sensitivity 0.5 vs 0.7 split a borderline pair") { t in
            // Jaccard 5/9 = 0.556: below the 0.60 gate, above 0.5, below 0.7.
            let r = SummaryMetrics.actionItemF1(
                refItems: [refItem("planet quartz ridge stone tunnel umber violet walnut xenon")],
                hypItems: [hypItem("planet quartz ridge stone tunnel")],
                roster: twoParty())
            t.expectEqual(r.matched, 0, "not matched at 0.60")
            t.expectEqual(r.f1, 0.0, "f1 at main threshold")
            t.expectEqual(r.sensitivity["0.5"], 1.0, "matched at 0.5")
            t.expectEqual(r.sensitivity["0.7"], 0.0, "unmatched at 0.7")
        }

        t.test("empty sides are N/A, not zero") { t in
            let roster = twoParty()
            let noHyp = SummaryMetrics.actionItemF1(
                refItems: [refItem("send report")], hypItems: [], roster: roster)
            t.expect(noHyp.precision == nil, "precision undefined with no hyp items")
            t.expectEqual(noHyp.recall, 0.0, "recall defined: 0 of 1 found")
            t.expect(noHyp.f1 == nil, "f1 undefined")
            t.expect(noHyp.sensitivity.isEmpty, "sensitivity undefined")
            let noRef = SummaryMetrics.actionItemF1(
                refItems: [], hypItems: [hypItem("send report")], roster: roster)
            t.expect(noRef.recall == nil, "recall undefined with no ref items")
            t.expectEqual(noRef.precision, 0.0, "precision defined: 0 of 1 correct")
        }

        t.test("Them resolves to counterparty in 2-party") { t in
            let r = SummaryMetrics.actionItemF1(
                refItems: [refItem("share revised timeline", "Jordan")],
                hypItems: [hypItem("share revised timeline", "Them")],
                roster: twoParty())
            t.expectEqual(r.matched, 1, "Them == Jordan == S2")
        }

        t.test("Them is unresolvable in 3-party") { t in
            let roster = threeParty()
            let f1 = SummaryMetrics.actionItemF1(
                refItems: [refItem("share revised timeline", "Jordan")],
                hypItems: [hypItem("share revised timeline", "Them")],
                roster: roster)
            t.expectEqual(f1.matched, 0, "ambiguous Them blocks the pair")
            let h = SummaryMetrics.hallucinatedOwners(
                hypActionItems: [hypItem("share revised timeline", "Them")],
                hypDecisions: [], refSummary: nil, roster: roster)
            t.expectEqual(h.tier1Phantom, 1, "Them is phantom without a sole counterparty")
        }

        t.test("tier 1 phantom owner outside roster") { t in
            let h = SummaryMetrics.hallucinatedOwners(
                hypActionItems: [hypItem("order booth supplies", "Pam")],
                hypDecisions: [], refSummary: nil, roster: twoParty())
            t.expectEqual(h.tier1Phantom, 1, "Pam not in roster")
            t.expectEqual(h.tier2Misassigned, 0, "no tier 2")
            t.expectEqual(h.hypItemsWithOwner, 1, "denominator")
            t.expectEqual(h.rate, 1.0, "rate")
            t.expect(h.offenders.contains { $0.contains("Pam") }, "offender names the phantom")
        }

        t.test("tier 2 matched task with swapped owner") { t in
            // Control pair must sit below the gate or the test proves nothing.
            t.expect(SummaryMetrics.taskSimilarity(
                "scout portland venues", "send the pricing deck") < 0.6,
                "control task is dissimilar")
            let refSummary = GoldenReference.RefSummary(
                summary_points: [],
                decisions: [],
                action_items: [.init(task: "send the pricing deck", owner: "Maxwell", due: nil)])
            let h = SummaryMetrics.hallucinatedOwners(
                hypActionItems: [
                    hypItem("send the pricing deck", "Jordan"),   // swapped -> tier 2
                    hypItem("send the pricing deck", "Alex"),     // alias of Maxwell -> clean
                    hypItem("scout portland venues", "Jordan"),   // no ref match -> clean
                ],
                hypDecisions: [], refSummary: refSummary, roster: twoParty())
            t.expectEqual(h.tier2Misassigned, 1, "only the swap counts")
            t.expectEqual(h.tier1Phantom, 0, "all owners resolvable")
            t.expectEqual(h.hypItemsWithOwner, 3, "denominator")
            if let rate = h.rate {
                t.expect(abs(rate - 1.0 / 3.0) < 1e-9, "rate 1/3")
            } else {
                t.expect(false, "rate defined")
            }
        }

        t.test("decision owner: trailing spaced em dash only") { t in
            let h = SummaryMetrics.hallucinatedOwners(
                hypActionItems: [],
                hypDecisions: [
                    "Ship the beta — Pam",          // owned, phantom
                    "Proceed with the rollout",     // unowned
                    "Choose vendor B - Jordan",     // hyphen is not a separator
                ],
                refSummary: nil, roster: twoParty())
            t.expectEqual(h.hypItemsWithOwner, 1, "only the em-dash decision counts")
            t.expectEqual(h.tier1Phantom, 1, "Pam is phantom")
        }

        t.test("tier 2 on decisions vs reference decisions") { t in
            let refSummary = GoldenReference.RefSummary(
                summary_points: [],
                decisions: [.init(text: "ship the beta next week", owner: "Maxwell")],
                action_items: [])
            let h = SummaryMetrics.hallucinatedOwners(
                hypActionItems: [],
                hypDecisions: ["Ship the beta next week — Jordan"],
                refSummary: refSummary, roster: twoParty())
            t.expectEqual(h.tier2Misassigned, 1, "decision owner swapped")
            t.expectEqual(h.tier1Phantom, 0, "Jordan resolves")
            t.expectEqual(h.hypItemsWithOwner, 1, "denominator")
        }

        t.test("Me and roster alias canonicalize to the same id") { t in
            let r = SummaryMetrics.actionItemF1(
                refItems: [refItem("draft the kickoff email", "Alex")],
                hypItems: [hypItem("draft the kickoff email", "Me")],
                roster: twoParty())
            t.expectEqual(r.matched, 1, "Me == Alex == Maxwell == S1")
        }

        t.test("rate undefined with no owned items") { t in
            let h = SummaryMetrics.hallucinatedOwners(
                hypActionItems: [hypItem("circulate recap")],
                hypDecisions: ["Proceed with the rollout"],
                refSummary: nil, roster: twoParty())
            t.expectEqual(h.hypItemsWithOwner, 0, "no owners anywhere")
            t.expect(h.rate == nil, "no denominator, no rate")
        }
    }
}
