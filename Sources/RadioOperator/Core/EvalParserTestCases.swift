import Foundation

/// EvalNoteParser: spec §0 grammar against miniatures of the live corpus
/// (fixtures mirror the app's real note grammar; entities synthetic).
enum EvalParserTestCases {

    /// Minimal valid meeting-note shell; body appended after the H1.
    private static func meeting(_ body: String) -> String {
        "---\ntitle: T\ndate: 2026-07-06T18:00:00Z\nduration_seconds: 60\n"
            + "summary: done\nsource: Radio Operator\ntags: [meeting]\n---\n\n# T\n\n"
            + body
    }

    private static func items(_ lines: String) -> [HypNote.ActionItem] {
        EvalNoteParser.parse(markdown: meeting("## Action Items\n\n" + lines + "\n")).actionItems
    }

    static func run(_ t: TestContext) {
        t.test("frontmatter scalars parsed, bracket lists kept raw") { t in
            let md = """
            ---
            title: Quarterly Vendor Sync
            date: 2026-07-06T18:00:48Z
            duration_seconds: 1532
            summary: done
            source: Radio Operator
            tags: [meeting]
            attendees: ["Jordan Reyes <jordan.reyes@partnerco.example>", "Sam Owner <sam.owner@company.example> (self, organizer)"]
            ---

            # Quarterly Vendor Sync
            """
            let note = EvalNoteParser.parse(markdown: md)
            t.expect(note.hasFrontmatter, "frontmatter detected")
            t.expect(note.isMeetingNote, "source == Radio Operator")
            t.expectEqual(note.frontmatter["title"] ?? "", "Quarterly Vendor Sync", "title")
            t.expectEqual(note.frontmatter["date"] ?? "", "2026-07-06T18:00:48Z", "date raw")
            t.expectEqual(note.frontmatter["duration_seconds"] ?? "", "1532", "duration")
            t.expectEqual(note.frontmatter["tags"] ?? "", "[meeting]", "tags bracket list raw")
            t.expectEqual(note.frontmatter["attendees"] ?? "",
                          "[\"Jordan Reyes <jordan.reyes@partnerco.example>\", \"Sam Owner <sam.owner@company.example> (self, organizer)\"]",
                          "attendees bracket list raw incl. quotes")
        }

        t.test("quoted scalar loses exactly one quote level") { t in
            let note = EvalNoteParser.parse(
                markdown: "---\ntitle: \"Budget Sync\"\nsource: Radio Operator\n---\nbody")
            t.expectEqual(note.frontmatter["title"] ?? "", "Budget Sync", "quotes stripped")
        }

        t.test("foreign note without frontmatter is not a meeting note") { t in
            let md = "# Radio Operator Library System Overview\n\nProse.\n\n## Summary\n\n- point one\n"
            let note = EvalNoteParser.parse(markdown: md)
            t.expect(!note.hasFrontmatter, "no frontmatter")
            t.expect(!note.isMeetingNote, "foreign file excluded from grading")
            t.expectEqual(note.headings, ["Summary"], "structure still parsed")
            t.expectEqual(note.summaryBullets, ["point one"], "bullets still parsed")
        }

        t.test("frontmatter with wrong source is not a meeting note") { t in
            let note = EvalNoteParser.parse(
                markdown: "---\ntitle: X\nsource: Obsidian Importer\n---\nbody")
            t.expect(note.hasFrontmatter, "frontmatter present")
            t.expect(!note.isMeetingNote, "wrong source")
        }

        t.test("H2 headings collected in order") { t in
            let note = EvalNoteParser.parse(markdown: meeting(
                "## Summary\n\n- s\n\n## Decisions\n\n- d\n\n## Action Items\n\n- [ ] a\n\n## Transcript\n"))
            t.expectEqual(note.headings, ["Summary", "Decisions", "Action Items", "Transcript"], "order")
            t.expectEqual(note.summaryBullets, ["s"], "summary bullet stripped of dash")
            t.expectEqual(note.decisions, ["d"], "decision bullet stripped of dash")
        }

        t.test("transcript turn regex: speaker verbatim, timestamp as written, tRel") { t in
            let note = EvalNoteParser.parse(markdown: meeting("""
            ## Transcript

            **Them** _(13:00:57)_: Hey.

            **Them** _(13:01:01)_: Yeah, can you hear me?

            **Me** _(13:01:04)_: How you doing, man?
            """))
            t.expectEqual(note.transcript.count, 3, "three turns")
            guard note.transcript.count == 3 else { return }
            t.expectEqual(note.transcript[0].speaker, "Them", "speaker token")
            t.expectEqual(note.transcript[0].timestamp, "13:00:57", "timestamp as written")
            t.expectEqual(note.transcript[0].tRel, 0.0, "first line anchors tRel")
            t.expectEqual(note.transcript[0].text, "Hey.", "text")
            t.expectEqual(note.transcript[1].tRel, 4.0, "tRel from first line")
            t.expectEqual(note.transcript[2].speaker, "Me", "second speaker")
            t.expectEqual(note.transcript[2].tRel, 7.0, "tRel third line")
        }

        t.test("continuation line appends to previous turn") { t in
            let note = EvalNoteParser.parse(markdown: meeting("""
            ## Transcript

            **Them** _(13:01:01)_: Yeah, can you hear me?
            This wrapped onto a second line.

            **Me** _(13:01:04)_: Fine.
            """))
            t.expectEqual(note.transcript.count, 2, "continuation is not a new turn")
            t.expectEqual(note.transcript.first?.text ?? "",
                          "Yeah, can you hear me? This wrapped onto a second line.",
                          "appended with a space")
        }

        t.test("midnight rollover adds 24h once") { t in
            let note = EvalNoteParser.parse(markdown: meeting("""
            ## Transcript

            **Me** _(23:59:50)_: a

            **Them** _(00:00:10)_: b

            **Me** _(00:01:00)_: c
            """))
            guard note.transcript.count == 3 else {
                t.expect(false, "expected 3 turns"); return
            }
            t.expectEqual(note.transcript[0].tRel, 0.0, "anchor")
            t.expectEqual(note.transcript[1].tRel, 20.0, "rollover applied")
            t.expectEqual(note.transcript[2].tRel, 70.0, "rollover persists, not re-applied")
        }

        t.test("small backwards jitter is not a rollover") { t in
            // Live corpus: Me 12:08:24 written after Them 12:08:25 (D1-A bleed).
            let note = EvalNoteParser.parse(markdown: meeting("""
            ## Transcript

            **Them** _(12:08:25)_: three hundred thousand

            **Me** _(12:08:24)_: one thousand
            """))
            t.expectEqual(note.transcript.last?.tRel ?? 99, -1.0, "1s backwards stays negative")
        }

        t.test("owner form: trailing em-dash") { t in
            let parsed = items("- [ ] Send confirmed state and distributor list \u{2014} Them")
            t.expectEqual(parsed.count, 1, "one item")
            t.expectEqual(parsed.first?.task ?? "", "Send confirmed state and distributor list", "task")
            t.expectEqual(parsed.first?.owner ?? "", "Them", "owner")
            t.expect(parsed.first?.due == nil, "no due")
        }

        t.test("owner form: em-dash with due suffix") { t in
            let parsed = items("- [ ] Build wrap deck \u{2014} Maxwell, due Thursday")
            t.expectEqual(parsed.first?.task ?? "", "Build wrap deck", "task")
            t.expectEqual(parsed.first?.owner ?? "", "Maxwell", "owner before due")
            t.expectEqual(parsed.first?.due ?? "", "Thursday", "due")
        }

        t.test("owner form: leading Name to verb") { t in
            let parsed = items("""
            - [ ] Maxwell (Me) to advise on recommended sample count
            - [ ] Them to send confirmed state and distributor list for Lit
            - [ ] Circulate notes broadly
            """)
            t.expectEqual(parsed.count, 3, "three items")
            guard parsed.count == 3 else { return }
            t.expectEqual(parsed[0].owner ?? "", "Maxwell", "parenthetical alias dropped")
            t.expectEqual(parsed[0].task, "to advise on recommended sample count", "task keeps to-verb")
            t.expectEqual(parsed[1].owner ?? "", "Them", "Them as leading name")
            t.expect(parsed[2].owner == nil, "no owner pattern -> unowned")
            t.expectEqual(parsed[2].task, "Circulate notes broadly", "task untouched")
        }

        t.test("None placeholders dropped, checked state kept") { t in
            let parsed = items("""
            - [ ] None
            - None
            - [x] Close out contract \u{2014} Them
            - [X] Ping legal
            - [ ] Draft recap
            """)
            t.expectEqual(parsed.count, 3, "both None forms dropped")
            guard parsed.count == 3 else { return }
            t.expect(parsed[0].checked, "[x] checked")
            t.expectEqual(parsed[0].owner ?? "", "Them", "owner on checked item")
            t.expect(parsed[1].checked, "[X] uppercase checked")
            t.expect(!parsed[2].checked, "[ ] unchecked")
            t.expectEqual(parsed[2].raw, "- [ ] Draft recap", "raw preserves checkbox line")
        }

        t.test("single hyphen split requires capitalized owner") { t in
            let parsed = items("""
            - [ ] follow up - maybe next week
            - [ ] send deck - Justin
            """)
            guard parsed.count == 2 else {
                t.expect(false, "expected 2 items"); return
            }
            t.expect(parsed[0].owner == nil, "lowercase after hyphen: no owner")
            t.expectEqual(parsed[0].task, "follow up - maybe next week", "task intact")
            t.expectEqual(parsed[1].owner ?? "", "Justin", "capitalized after hyphen: owner")
            t.expectEqual(parsed[1].task, "send deck", "task before hyphen")
        }
    }
}
