import Foundation

/// ValidityChecks (V1-V5) unit tests. Fixtures are hard-coded miniatures of
/// the live-corpus failure shapes (doubled-summary overview note, foreign
/// file, pending marker). The fixture parser below fills ONLY the HypNote
/// fields ValidityChecks reads, so this suite does not depend on
/// EvalNoteParser's behavior.
enum EvalValidityTestCases {

    static func run(_ t: TestContext) {

        t.test("valid done note passes all V1-V5") { t in
            let r = grade(validNote)
            t.expect(r.pass, "overall pass")
            t.expectEqual(r.checks.count, 5, "five checks")
            t.expectEqual(r.checks.map { $0.id }, ["V1", "V2", "V3", "V4", "V5"], "check ids")
            for c in r.checks {
                t.expect(c.applicable, "\(c.id) applicable")
                t.expect(c.pass, "\(c.id) failed: \(c.detail)")
            }
        }

        t.test("done with no rendered sections fails V2") { t in
            let md = """
            \(frontmatter(summary: "done"))

            # Budget Sync

            ## Transcript

            **Me** _(12:00:00)_: hello
            """
            let r = grade(md)
            let v2 = check(r, "V2")
            t.expect(v2.applicable, "V2 applicable")
            t.expect(!v2.pass, "V2 must fail: \(v2.detail)")
            t.expect(!r.pass, "overall fail")
        }

        t.test("doubled ## Summary fails V3") { t in
            let md = validNote.replacingOccurrences(
                of: "## Transcript",
                with: "## Summary\n\n- duplicated overview block\n\n## Transcript")
            let r = grade(md)
            t.expect(!check(r, "V3").pass, "V3 must fail on duplicate")
            t.expect(check(r, "V2").pass, "V2 unaffected: \(check(r, "V2").detail)")
        }

        t.test("out-of-order sections fail V3") { t in
            let md = validNote
                .replacingOccurrences(of: "## Summary", with: "## HOLD-S")
                .replacingOccurrences(of: "## Decisions", with: "## Summary")
                .replacingOccurrences(of: "## HOLD-S", with: "## Decisions")
            let r = grade(md)
            let v3 = check(r, "V3")
            t.expect(!v3.pass, "V3 must fail on order")
            t.expect(v3.detail.contains("out of order"), "detail names order: \(v3.detail)")
            t.expect(check(r, "V2").pass, "V2 unaffected")
        }

        t.test("bad transcript line fails V4") { t in
            let md = validNote + "\nThem said something without turn markup\n"
            let r = grade(md)
            let v4 = check(r, "V4")
            t.expect(!v4.pass, "V4 must fail: \(v4.detail)")
            t.expect(v4.detail.contains("bad turn line"), "detail names the line")
            for id in ["V1", "V2", "V3", "V5"] {
                t.expect(check(r, id).pass, "\(id) unaffected")
            }
        }

        t.test("non-Me/Them speaker token fails V4") { t in
            // v1 stream labels only; roster display names come with 3+-party.
            let md = validNote + "\n**Bob** _(12:00:00)_: hi"
            let r = grade(md)
            let v4 = check(r, "V4")
            t.expect(!v4.pass, "Bob is not a v1 stream label")
            t.expect(v4.detail.contains("unknown speaker"), "detail names the token: \(v4.detail)")
            for id in ["V1", "V2", "V3", "V5"] {
                t.expect(check(r, id).pass, "\(id) unaffected")
            }
            // Me/Them turn lines (the validNote transcript) still pass.
            t.expect(check(grade(validNote), "V4").pass, "Me/Them speaker tokens pass")
        }

        t.test("italic and blockquote marker lines exempt from V4") { t in
            let md = validNote.replacingOccurrences(
                of: "**Me** _(12:00:00)_: morning, ready to start",
                with: """
                > ⏳ Summary pending — open Radio Operator Library to retry.
                > ⚠️ System audio capture was unavailable — this transcript is microphone-only.
                _No speech captured._
                **Me** _(12:00:00)_: morning, ready to start
                """)
            let r = grade(md)
            t.expect(check(r, "V4").pass, "markers exempt: \(check(r, "V4").detail)")
        }

        t.test("non-monotonic timestamps fail V4") { t in
            let md = validNote.replacingOccurrences(of: "_(12:00:04)_", with: "_(11:59:59)_")
            let r = grade(md)
            let v4 = check(r, "V4")
            t.expect(!v4.pass, "backward 5s is not a rollover")
            t.expect(v4.detail.contains("non-monotonic"), "detail: \(v4.detail)")
        }

        t.test("one midnight rollover allowed, second fails") { t in
            let one = transcriptOnly(times: ["23:59:58", "00:00:03", "00:00:10"])
            t.expect(check(grade(one), "V4").pass, "single rollover passes")
            let two = transcriptOnly(times: ["13:00:00", "00:30:00", "13:00:00", "00:30:00"])
            t.expect(!check(grade(two), "V4").pass, "second rollover fails")
        }

        t.test("non-checkbox action item fails V5") { t in
            let md = validNote.replacingOccurrences(
                of: "- [ ] Alex to send the deck, due Friday",
                with: "- Alex to send the deck")
            let r = grade(md)
            t.expect(!check(r, "V5").pass, "plain bullet is not a checkbox")
            t.expect(check(r, "V2").pass, "V2 still sees a bullet")
        }

        t.test("exactly - None passes V5, variants fail") { t in
            let noneOnly = validNote.replacingOccurrences(
                of: "- [ ] Alex to send the deck, due Friday\n- [x] Maxwell to book the review",
                with: "- None")
            let r = grade(noneOnly)
            t.expect(check(r, "V5").pass, "explicit None: \(check(r, "V5").detail)")
            t.expect(check(r, "V2").pass, "None satisfies done semantics")
            let variant = noneOnly.replacingOccurrences(of: "- None", with: "- None planned")
            t.expect(!check(grade(variant), "V5").pass, "only the exact placeholder passes")
        }

        t.test("foreign note: all checks not applicable, passes overall") { t in
            let md = """
            # Radio Operator Library System Overview

            ## Summary

            - overview copy

            ## Summary

            - the doubled block

            not a transcript line at all
            """
            let r = grade(md)
            t.expect(r.pass, "excluded file cannot fail validity")
            for c in r.checks {
                t.expect(!c.applicable, "\(c.id) must be not-applicable")
            }
            // Frontmatter present but source is not Radio Operator: still foreign.
            let other = validNote.replacingOccurrences(of: "source: Radio Operator",
                                                       with: "source: Obsidian")
            t.expect(grade(other).checks.allSatisfy { !$0.applicable }, "wrong source is foreign")
        }

        t.test("V1 catches bad frontmatter fields") { t in
            let cases: [(String, String)] = [
                ("date: 2026-07-06T12:00:00Z", "date: 2026-07-06T12:00:00"),  // zone required
                ("duration_seconds: 300", "duration_seconds: 0"),
                ("summary: done", "summary: oops"),
                ("tags: [meeting]", "tags: [sales]"),
                ("title: Budget Sync", "title:"),
            ]
            for (good, bad) in cases {
                let r = grade(validNote.replacingOccurrences(of: good, with: bad))
                t.expect(!check(r, "V1").pass, "must fail V1: \(bad)")
            }
            let offset = grade(validNote.replacingOccurrences(
                of: "date: 2026-07-06T12:00:00Z", with: "date: 2026-07-06T07:00:00-05:00"))
            t.expect(check(offset, "V1").pass, "numeric offset is valid ISO-8601")
        }

        t.test("pending note without summary passes all") { t in
            let md = """
            \(frontmatter(summary: "pending"))

            # Budget Sync

            > ⏳ Summary pending — open Radio Operator Library to retry.

            ## Transcript

            **Me** _(12:00:00)_: hello
            **Them** _(12:00:03)_: hi
            """
            let r = grade(md)
            t.expect(r.pass, "pending note is valid")
            t.expect(check(r, "V2").pass, "V2: \(check(r, "V2").detail)")
            t.expect(check(r, "V3").pass, "absent trio allowed while pending: \(check(r, "V3").detail)")
        }

        t.test("pending with rendered bullets fails V2") { t in
            let md = validNote.replacingOccurrences(of: "summary: done", with: "summary: pending")
            let r = grade(md)
            let v2 = check(r, "V2")
            t.expect(!v2.pass, "pending must not have rendered bullets")
            t.expect(v2.detail.contains("pending"), "detail names status: \(v2.detail)")
        }
    }

    // MARK: - Fixtures

    private static let validNote = """
    \(frontmatter(summary: "done"))

    # Budget Sync

    ## Summary

    - Reviewed the Q3 sampling budget

    ## Decisions

    - Ship the revised tier

    ## Action Items

    - [ ] Alex to send the deck, due Friday
    - [x] Maxwell to book the review

    ## Transcript

    *Participants: Me, Them*

    **Me** _(12:00:00)_: morning, ready to start
    **Them** _(12:00:04)_: yes, budget first
    **Me** _(12:00:09)_: three hundred thousand for H2
    """

    private static func frontmatter(summary: String) -> String {
        """
        ---
        title: Budget Sync
        date: 2026-07-06T12:00:00Z
        duration_seconds: 300
        summary: \(summary)
        source: Radio Operator
        tags: [meeting]
        ---
        """
    }

    private static func transcriptOnly(times: [String]) -> String {
        let turns = times.map { "**Me** _(\($0))_: tick" }.joined(separator: "\n")
        return """
        \(frontmatter(summary: "pending"))

        # Budget Sync

        > ⏳ Summary pending — open Radio Operator Library to retry.

        ## Transcript

        \(turns)
        """
    }

    private static func grade(_ md: String) -> ValidityResult {
        ValidityChecks.check(markdown: md, note: fixtureNote(md))
    }

    private static func check(_ r: ValidityResult, _ id: String) -> ValidityResult.Check {
        r.checks.first { $0.id == id }
            ?? ValidityResult.Check(id: id, applicable: true, pass: false, detail: "check \(id) missing")
    }

    /// Minimal parse of the fields ValidityChecks reads (frontmatter scalars,
    /// H2 headings, meeting-note gate). Transcript/bullet fields stay empty:
    /// the module scans those from raw markdown by design.
    private static func fixtureNote(_ md: String) -> HypNote {
        var fm: [String: String] = [:]
        var hasFM = false
        var body = md
        if md.hasPrefix("---\n"),
           let end = md.range(of: "\n---", range: md.index(md.startIndex, offsetBy: 4)..<md.endIndex) {
            hasFM = true
            let block = md[md.index(md.startIndex, offsetBy: 4)..<end.lowerBound]
            for line in block.components(separatedBy: "\n") {
                guard let colon = line.firstIndex(of: ":") else { continue }
                let key = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
                var value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
                if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") {
                    value = String(value.dropFirst().dropLast())
                }
                fm[key] = value
            }
            body = String(md[end.upperBound...])
        }
        let headings = body.components(separatedBy: "\n")
            .filter { $0.hasPrefix("## ") }
            .map { String($0.dropFirst(3)).trimmingCharacters(in: .whitespaces) }
        return HypNote(frontmatter: fm, hasFrontmatter: hasFM, headings: headings,
                       transcript: [], summaryBullets: [], decisions: [], actionItems: [],
                       isMeetingNote: hasFM && fm["source"] == "Radio Operator")
    }
}
