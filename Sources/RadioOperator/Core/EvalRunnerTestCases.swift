import Foundation

/// End-to-end EvalRunner.run() tests against throwaway golden dirs. Each test
/// gets a hermetic temp "repo root" (own eval/gates.json) and chdirs into it so
/// repoRoot() can never touch the real repo's baseline.
enum EvalRunnerTestCases {
    static func run(_ t: TestContext) {
        t.test("draft run refuses --write-baseline and never gates") { t in
            inTempRoot { root, golden in
                writeMeeting(golden, id: "m1", verified: false)
                let code = EvalRunner.run(goldenDir: golden, allowDraft: true, reportDir: nil,
                                          subset: nil, writeBaseline: true)
                t.expectEqual(code, 0, "draft diagnostic run exits 0")
                let baseline = root.appendingPathComponent("eval/baseline.json")
                t.expect(!FileManager.default.fileExists(atPath: baseline.path),
                         "draft run must not write a baseline")
            }
        }

        t.test("unverified reference without --allow-draft is integrity exit 4") { t in
            inTempRoot { _, golden in
                writeMeeting(golden, id: "m1", verified: false)
                let code = EvalRunner.run(goldenDir: golden, allowDraft: false, reportDir: nil,
                                          subset: nil, writeBaseline: false)
                t.expectEqual(code, 4, "anti-circularity gate")
            }
        }

        t.test("summary not authored blind blocks gradeability") { t in
            inTempRoot { _, golden in
                writeMeeting(golden, id: "m1", verified: true, blind: false)
                let code = EvalRunner.run(goldenDir: golden, allowDraft: false, reportDir: nil,
                                          subset: nil, writeBaseline: false)
                t.expectEqual(code, 4, "full_listen alone is not enough when a summary exists")
            }
        }

        t.test("corrupt meta.json is exit 4 even with --allow-draft-references") { t in
            inTempRoot { _, golden in
                writeMeeting(golden, id: "m1", verified: true)
                let bad = golden.appendingPathComponent("golden/m2")
                try? FileManager.default.createDirectory(at: bad, withIntermediateDirectories: true)
                try? "{not json".write(to: bad.appendingPathComponent("meta.json"),
                                       atomically: true, encoding: .utf8)
                let code = EvalRunner.run(goldenDir: golden, allowDraft: true, reportDir: nil,
                                          subset: nil, writeBaseline: false)
                t.expectEqual(code, 4, "corrupt inputs never silently vanish")
            }
        }

        t.test("pooled F1 is 0 (band F), not N/A, when nothing matches") { t in
            inTempRoot { _, golden in
                writeMeeting(golden, id: "m1", verified: true,
                             refActionItems: [["task": "renew the contract", "owner": "S2"]])
                let report = runAndLoadReport(golden, t: t)
                let f1 = metricValue(report, "action_item_f1")
                t.expectEqual(f1 ?? -1, 0, "items on both sides, zero matches -> 0.0")
                t.expectEqual(metricBand(report, "action_item_f1") ?? "", "F", "zero F1 bands F")
            }
        }

        t.test("term accuracy grades brand+money+number pool only") { t in
            inTempRoot { _, golden in
                let terms = """
                {"version": 1, "terms": [
                  {"canonical": "Acme", "category": "brand", "aliases": [], "match": "exact"},
                  {"canonical": "Zorg", "category": "org", "aliases": [], "match": "exact"}]}
                """
                try? terms.write(to: golden.appendingPathComponent("terms.json"),
                                 atomically: true, encoding: .utf8)
                // Them line says "acme" (hit); nothing says "zorg" (org-pool miss).
                writeMeeting(golden, id: "m1", verified: true,
                             themText: "we signed with acme yesterday",
                             refTerms: [["term": "Acme", "category": "brand"],
                                        ["term": "Zorg", "category": "org"]])
                let report = runAndLoadReport(golden, t: t)
                t.expectEqual(metricValue(report, "term_accuracy") ?? -1, 1.0,
                              "graded pool ignores the org miss")
                t.expectEqual(metricValue(report, "term_accuracy_all") ?? -1, 0.5,
                              "all-category pool is report-only")
            }
        }

        t.test("stub audio makes that track's WER N/A instead of polluting the aggregate") { t in
            inTempRoot { _, golden in
                writeMeeting(golden, id: "m1", verified: true, stubMeAudio: true)
                let report = runAndLoadReport(golden, t: t)
                let pm = (report["per_meeting"] as? [[String: Any]])?.first
                t.expect(pm?["wer_me"] == nil || pm?["wer_me"] is NSNull, "stub track WER is null")
                t.expect((pm?["notes"] as? String ?? "").contains("CAPTURE LOSS"),
                         "diagnostic note carries the loss")
            }
        }

        t.test("baseline normalizer-version mismatch is a hard gate (exit 2)") { t in
            inTempRoot { root, golden in
                writeMeeting(golden, id: "m1", verified: true)
                let stale = """
                {"metrics": {"attribution_2party": 0.5}, "run_id": "old",
                 "normalizer_version": "0.0-stale", "terms_version": 0, "draft": false}
                """
                try? stale.write(to: root.appendingPathComponent("eval/baseline.json"),
                                 atomically: true, encoding: .utf8)
                let code = EvalRunner.run(goldenDir: golden, allowDraft: false, reportDir: nil,
                                          subset: nil, writeBaseline: false)
                t.expectEqual(code, 2, "goalpost move forces re-baseline in the same PR")
            }
        }

        t.test("--subset with no match is an argument error (exit 3), not integrity") { t in
            inTempRoot { _, golden in
                writeMeeting(golden, id: "m1", verified: true)
                let code = EvalRunner.run(goldenDir: golden, allowDraft: false, reportDir: nil,
                                          subset: "nope", writeBaseline: false)
                t.expectEqual(code, 3)
            }
        }

        t.test("manifest sha256 mismatch is exit 4") { t in
            inTempRoot { _, golden in
                writeMeeting(golden, id: "m1", verified: true, stubMeAudio: true)
                let manifest = """
                {"complete": false, "meetings": [
                  {"id": "m1", "sha256_me": "sha256:deadbeef"}]}
                """
                try? manifest.write(to: golden.appendingPathComponent("golden/manifest.json"),
                                    atomically: true, encoding: .utf8)
                let code = EvalRunner.run(goldenDir: golden, allowDraft: false, reportDir: nil,
                                          subset: nil, writeBaseline: false)
                t.expectEqual(code, 4)
            }
        }
    }

    // MARK: - Fixtures

    /// Temp root layout: <root>/eval/gates.json (hermetic repoRoot anchor) and
    /// <root>/goldenset/{terms.json?, golden/<id>/...}. Chdir in, always restore.
    private static func inTempRoot(_ body: (URL, URL) -> Void) {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(
            "eval-runner-test-\(UUID().uuidString)", isDirectory: true)
        let golden = root.appendingPathComponent("goldenset")
        try? fm.createDirectory(at: root.appendingPathComponent("eval"), withIntermediateDirectories: true)
        try? fm.createDirectory(at: golden.appendingPathComponent("golden"), withIntermediateDirectories: true)
        try? #"{"egress_posture": "declared-egress", "epsilons": {"attribution_2party": 0.005}, "hard_gates": {}}"#
            .write(to: root.appendingPathComponent("eval/gates.json"), atomically: true, encoding: .utf8)
        let prevCWD = fm.currentDirectoryPath
        fm.changeCurrentDirectoryPath(root.path)
        defer {
            fm.changeCurrentDirectoryPath(prevCWD)
            try? fm.removeItem(at: root)
        }
        body(root, golden)
    }

    private static func writeMeeting(_ golden: URL, id: String, verified: Bool,
                                     blind: Bool = true,
                                     themText: String = "hi maxwell good morning",
                                     refActionItems: [[String: String]] = [],
                                     refTerms: [[String: String]] = [],
                                     stubMeAudio: Bool = false) {
        let fm = FileManager.default
        let dir = golden.appendingPathComponent("golden/\(id)")
        try? fm.createDirectory(at: dir.appendingPathComponent("audio"), withIntermediateDirectories: true)

        let note = """
        ---
        title: Fixture Meeting
        date: 2026-07-06T17:00:00Z
        duration_seconds: 60
        summary: done
        source: Radio Operator
        tags: [meeting]
        ---

        # Fixture Meeting

        ## Summary
        - covered fixture things

        ## Decisions
        - None

        ## Action Items
        - [ ] send the deck — Maxwell

        ## Transcript

        **Me** _(12:00:00)_: hello there partner
        **Them** _(12:00:05)_: \(themText)
        """
        try? note.write(to: dir.appendingPathComponent("hypothesis.md"), atomically: true, encoding: .utf8)

        let meta = """
        {"meeting_id": "\(id)", "strata": ["two_party"], "duration_seconds": 60,
         "hypothesis_note": "hypothesis.md",
         "participants": [
           {"id": "S1", "track": "me", "display": "Maxwell", "aliases": ["Me", "Maxwell"]},
           {"id": "S2", "track": "them", "display": "Pat", "aliases": ["Them", "Pat"]}]}
        """
        try? meta.write(to: dir.appendingPathComponent("meta.json"), atomically: true, encoding: .utf8)

        if stubMeAudio {
            fm.createFile(atPath: dir.appendingPathComponent("audio/me.m4a").path,
                          contents: Data([0x66, 0x74, 0x79, 0x70]))
        }

        var ref: [String: Any] = [
            "schema_version": "1.0",
            "meeting_id": id,
            "segments": [
                ["id": 1, "track": "me", "speaker": "S1", "start_s": 0.0, "end_s": 4.0,
                 "text": "hello there partner", "score": true, "terms": []],
                ["id": 2, "track": "them", "speaker": "S2", "start_s": 5.0, "end_s": 9.0,
                 "text": themText, "score": true, "terms": refTerms],
            ],
            "provenance": verified
                ? ["transcript_draft_source": "scratch",
                   "human_passes": [["annotator": "maxwell", "date": "2026-07-06", "full_listen": true]],
                   "summary_authored_blind": blind]
                : ["transcript_draft_source": "app-output", "human_passes": []],
        ]
        if stubMeAudio { ref["audio"] = ["me": "audio/me.m4a"] }
        if !refActionItems.isEmpty || verified {
            ref["reference_summary"] = ["summary_points": ["fixture"],
                                        "decisions": [],
                                        "action_items": refActionItems]
        }
        if let data = try? JSONSerialization.data(withJSONObject: ref, options: [.sortedKeys]) {
            try? data.write(to: dir.appendingPathComponent("reference.json"))
        }
    }

    private static func runAndLoadReport(_ golden: URL, t: TestContext) -> [String: Any] {
        let out = golden.appendingPathComponent("report-out")
        let code = EvalRunner.run(goldenDir: golden, allowDraft: false, reportDir: out,
                                  subset: nil, writeBaseline: false)
        t.expect(code == 0 || code == 1, "gradeable run completes (got exit \(code))")
        guard let data = try? Data(contentsOf: out.appendingPathComponent("report.json")),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            t.expect(false, "report.json written and parseable")
            return [:]
        }
        return obj
    }

    private static func metricValue(_ report: [String: Any], _ key: String) -> Double? {
        ((report["metrics"] as? [String: Any])?[key] as? [String: Any])?["value"] as? Double
    }

    private static func metricBand(_ report: [String: Any], _ key: String) -> String? {
        ((report["metrics"] as? [String: Any])?[key] as? [String: Any])?["band"] as? String
    }
}
