import Foundation

/// Tests for TaskIndex aggregation — the pure per-content extraction behind the
/// Tasks view. Deterministic (calendar injected); no filesystem.
enum TaskIndexTestCases {
    private static var utc: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    static func run(_ t: TestContext) {
        let inbox = URL(fileURLWithPath: "/tmp/Tasks.md")

        t.test("inbox: every checkbox line becomes a manual task") { t in
            let md = """
            # Tasks

            - [ ] Email the vendor 📅 2026-05-06 ⏫
            - [x] Booked the room
            just a note, not a task
            - [ ] Ping #ops about pricing
            """
            let tasks = TaskIndex.tasksFromInbox(url: inbox, content: md, calendar: utc)
            t.expectEqual(tasks.count, 3, "3 checkbox lines")
            t.expect(tasks.allSatisfy { $0.source == .manual }, "all manual")
            t.expectEqual(tasks.first?.text ?? "", "Email the vendor", "first text")
            t.expectEqual(tasks.first?.priority, .high, "first priority")
            t.expect(tasks.first?.due != nil, "first has due date")
            t.expect(tasks.contains { $0.done && $0.text == "Booked the room" }, "done task present")
            t.expect(tasks.contains { $0.project == "ops" }, "project parsed")
        }

        t.test("meeting: only Action Items checkboxes become tasks, not transcript") { t in
            let md = """
            ---
            title: SIP Sync
            date: 2026-07-07T10:00:00Z
            ---
            # SIP Sync

            ## Summary
            - Talked about pricing

            ## Action Items
            - [ ] Follow up with BevMo 📅 2026-07-10 ⏫ 🆔 t1
            - [x] Send the deck

            ## Transcript
            **Me** _(10:00:01)_: this is speech, - [ ] not a task
            """
            let url = URL(fileURLWithPath: "/tmp/Meetings/sip.md")
            let tasks = TaskIndex.tasksFromMeeting(url: url, title: "SIP Sync",
                                                   content: md, calendar: utc)
            t.expectEqual(tasks.count, 2, "two action items, transcript excluded")
            t.expect(tasks.allSatisfy { $0.source == .meeting(title: "SIP Sync") }, "sourced to meeting")
            t.expect(tasks.contains { $0.text == "Follow up with BevMo" && !$0.done && $0.id == "t1" }, "open item w/ id")
            t.expect(tasks.contains { $0.text == "Send the deck" && $0.done }, "done item")
            t.expect(!tasks.contains { $0.text.contains("speech") }, "no transcript line")
        }

        t.test("meeting with no action items yields no tasks") { t in
            let md = "---\ntitle: X\n---\n# X\n\n## Summary\n- nothing actionable\n"
            let tasks = TaskIndex.tasksFromMeeting(url: inbox, title: "X", content: md, calendar: utc)
            t.expectEqual(tasks.count, 0, "none")
        }

        t.test("parseDueDate: valid ISO → that calendar day; malformed → nil") { t in
            guard let d = TaskIndex.parseDueDate("2026-07-10", calendar: utc) else {
                t.expect(false, "should parse 2026-07-10"); return
            }
            let c = utc.dateComponents([.year, .month, .day], from: d)
            t.expectEqual(c.year ?? 0, 2026, "year")
            t.expectEqual(c.month ?? 0, 7, "month")
            t.expectEqual(c.day ?? 0, 10, "day")
            t.expect(TaskIndex.parseDueDate("not-a-date", calendar: utc) == nil, "malformed → nil")
            t.expect(TaskIndex.parseDueDate("2026-07", calendar: utc) == nil, "partial → nil")
        }
    }
}
