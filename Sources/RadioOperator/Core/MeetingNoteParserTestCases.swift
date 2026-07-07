import Foundation

/// MeetingNoteParser: structured-section extraction, transcript parsing,
/// checkbox toggling (byte-preserving), and timecode → player offsets.
enum MeetingNoteParserTestCases {

    static let sampleNote = """
    ---
    title: Acme sync
    date: 2026-07-06T14:00:00Z
    duration_seconds: 2820
    summary: done
    source: Radio Operator
    tags: [meeting]
    ---

    # Acme sync

    ## Summary

    - Aligned on a **70/30 revenue split** for year one.
    - Legal reviews the MSA this week.

    ## Decisions

    - 70/30 revenue share in Acme's favor.
    - None

    ## Action Items

    - [ ] Send revised rev-share model — You, Fri
    - [x] Book the follow-up
    - None

    ## Follow-ups

    - Confirm co-marketing budget
    - None

    ## My Notes

    ask about procurement timeline

    ## Transcript

    **Me** _(14:00:42)_: Thanks for making time.

    **Them** _(14:01:05)_: Happy to be here.
    """

    static func run(_ t: TestContext) {
        t.test("full summarized note parses every section") { t in
            let n = MeetingNoteParser.parse(sampleNote)
            t.expectEqual(n.summaryLines.count, 2, "two summary bullets")
            t.expect(n.summaryText.contains("**70/30 revenue split**"),
                     "summary keeps inline markdown")
            t.expectEqual(n.decisions, ["70/30 revenue share in Acme's favor."],
                          "decisions parsed, None filtered")
            t.expectEqual(n.followUps, ["Confirm co-marketing budget"],
                          "follow-ups parsed, None filtered")
            t.expectEqual(n.myNotes ?? "", "ask about procurement timeline", "my notes body")
            t.expect(!n.pending, "done note is not pending")
            t.expect(!n.micOnly, "no degradation marker")
        }

        t.test("action items: done flag, owner/due meta, None filtered") { t in
            let items = MeetingNoteParser.parse(sampleNote).actionItems
            t.expectEqual(items.count, 2, "two real tasks")
            t.expectEqual(items[0].text, "Send revised rev-share model", "meta stripped from text")
            t.expectEqual(items[0].meta ?? "", "You, Fri", "trailing owner/due tag")
            t.expect(!items[0].done, "unchecked box")
            t.expect(items[1].done, "checked box")
            t.expect(items[1].meta == nil, "no tag when none written")
            t.expectEqual(items[0].sourceLine, "- [ ] Send revised rev-share model — You, Fri",
                          "source line kept verbatim for toggling")
        }

        t.test("transcript turns: speaker, wall-clock time, text") { t in
            let n = MeetingNoteParser.parse(sampleNote)
            t.expectEqual(n.turns.count, 2, "two turns")
            t.expectEqual(n.turns[0].speaker, Speaker.me, "Me first")
            t.expectEqual(n.turns[0].time, "14:00:42", "wall-clock kept as written")
            t.expectEqual(n.turns[1].speaker, Speaker.them, "Them second")
            t.expectEqual(n.turns[1].text, "Happy to be here.", "text after the colon")
            t.expect(n.hasThem, "remote side present")
            t.expectEqual(n.speakerCount, 2, "two speakers")
        }

        t.test("excerpt is plain text on one line") { t in
            let e = MeetingNoteParser.parse(sampleNote).excerpt
            t.expect(e.contains("70/30 revenue split"), "content survives")
            t.expect(!e.contains("**"), "bold markers stripped")
            t.expect(!e.contains("\n"), "single line")
        }

        t.test("pending note: marker detected, summary empty, mic-only flagged") { t in
            let note = """
            ---
            title: Meeting
            summary: pending
            ---

            # Meeting

            > ⏳ Summary pending — open Radio Operator Library to retry.

            ## Transcript

            > ⚠️ System audio capture was unavailable — this transcript is microphone-only.

            **Me** _(09:03:22)_: hello
            """
            let n = MeetingNoteParser.parse(note)
            t.expect(n.pending, "pending marker found")
            t.expect(n.micOnly, "degradation marker found")
            t.expectEqual(n.summaryText, "", "marker is not a summary")
            t.expectEqual(n.turns.count, 1, "turn under the marker still parses")
            t.expect(!n.hasThem, "mic-only note has no Them turns")
        }

        t.test("prelude paragraph (no ## Summary heading) becomes the summary") { t in
            let note = "# T\n\nShort recap paragraph.\n\n## Transcript\n\n**Me** _(10:00:00)_: hi"
            let n = MeetingNoteParser.parse(note)
            t.expectEqual(n.summaryText, "Short recap paragraph.", "prelude wins")
        }

        t.test("headings match case-insensitively and by keyword") { t in
            let note = """
            # T

            ## KEY DECISIONS
            - Ship it

            ## action items
            - [ ] Do the thing

            ## Follow-Ups
            - Ping legal
            """
            let n = MeetingNoteParser.parse(note)
            t.expectEqual(n.decisions, ["Ship it"], "renamed decisions heading")
            t.expectEqual(n.actionItems.first?.text ?? "", "Do the thing", "lowercase heading")
            t.expectEqual(n.followUps, ["Ping legal"], "hyphen-case heading")
        }

        t.test("togglingCheckbox flips exactly one line, byte-preserving") { t in
            let line = "- [ ] Send revised rev-share model — You, Fri"
            guard let toggled = MeetingNoteParser.togglingCheckbox(
                in: sampleNote, sourceLine: line) else {
                t.expect(false, "toggle must succeed"); return
            }
            t.expect(toggled.contains("- [x] Send revised rev-share model — You, Fri"),
                     "unchecked → checked")
            t.expectEqual(
                toggled.replacingOccurrences(
                    of: "- [x] Send revised rev-share model — You, Fri", with: line),
                sampleNote, "every other byte untouched")
            let back = MeetingNoteParser.togglingCheckbox(
                in: toggled, sourceLine: "- [x] Send revised rev-share model — You, Fri")
            t.expectEqual(back ?? "", sampleNote, "round-trip restores the original")
        }

        t.test("togglingCheckbox refuses missing and non-checkbox lines") { t in
            t.expect(MeetingNoteParser.togglingCheckbox(
                in: sampleNote, sourceLine: "- [ ] not in the note") == nil,
                     "missing line → nil")
            t.expect(MeetingNoteParser.togglingCheckbox(
                in: sampleNote, sourceLine: "- Confirm co-marketing budget") == nil,
                     "plain bullet → nil")
        }

        t.test("timeOffset: wall-clock minus note start, clamped and midnight-safe") { t in
            var cal = Calendar(identifier: .gregorian)
            cal.timeZone = TimeZone(identifier: "UTC")!
            let twoPM = cal.date(from: DateComponents(
                year: 2026, month: 7, day: 6, hour: 14, minute: 0, second: 0))!
            t.expectEqual(MeetingNoteParser.timeOffset(
                clock: "14:00:42", noteStart: twoPM, calendar: cal) ?? -1, 42, "simple offset")
            t.expectEqual(MeetingNoteParser.timeOffset(
                clock: "13:59:30", noteStart: twoPM, calendar: cal) ?? -1, 0,
                          "small clock skew clamps to 0")
            let lateNight = cal.date(from: DateComponents(
                year: 2026, month: 7, day: 6, hour: 23, minute: 50, second: 0))!
            t.expectEqual(MeetingNoteParser.timeOffset(
                clock: "00:05:00", noteStart: lateNight, calendar: cal) ?? -1, 900,
                          "crossing midnight adds a day")
            t.expect(MeetingNoteParser.timeOffset(
                clock: "not a time", noteStart: twoPM, calendar: cal) == nil,
                     "garbage → nil")
        }

        t.test("parseTurn edges: single-digit hour, empty text, non-turns") { t in
            let turn = MeetingNoteParser.parseTurn("**Me** _(9:03:22)_: hi")
            t.expectEqual(turn?.time ?? "", "9:03:22", "single-digit hour accepted")
            let empty = MeetingNoteParser.parseTurn("**Them** _(14:03:22)_:")
            t.expectEqual(empty?.text ?? "missing", "", "empty text still a turn")
            t.expect(MeetingNoteParser.parseTurn("**Bold** not a turn") == nil,
                     "unknown speaker rejected")
            t.expect(MeetingNoteParser.parseTurn("**Me** _(99:99:99)_: x") == nil,
                     "invalid clock rejected")
        }

        t.test("summary falls back to ## Summary section when prelude is empty") { t in
            let note = "# T\n\n## Summary\n\nOne paragraph, no bullets.\n\n## Decisions\n- None"
            let n = MeetingNoteParser.parse(note)
            t.expectEqual(n.summaryText, "One paragraph, no bullets.", "section body used")
            t.expect(n.decisions.isEmpty, "None-only section is empty")
        }
    }
}
