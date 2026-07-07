import Foundation

/// Tests for TaskLine — the pure Obsidian-Tasks line parser/formatter behind
/// the Tasks feature. Deterministic and offline.
enum TaskLineTestCases {
    static func run(_ t: TestContext) {
        t.test("parses a full Obsidian-Tasks line") { t in
            let p = TaskLine.parse("- [ ] Follow up with BevMo #sip 📅 2026-07-10 ⏫ 🔁 every week 🆔 a1b2c3")
            t.expect(p != nil, "should parse")
            guard let p else { return }
            t.expectEqual(p.text, "Follow up with BevMo #sip", "text keeps #tag, strips metadata")
            t.expectEqual(p.done, false, "open")
            t.expectEqual(p.due ?? "", "2026-07-10", "due")
            t.expectEqual(p.priority, .high, "⏫ → high")
            t.expectEqual(p.recurrence ?? "", "every week", "recurrence phrase")
            t.expectEqual(p.project ?? "", "sip", "project from #tag")
            t.expectEqual(p.id ?? "", "a1b2c3", "id")
        }

        t.test("done checkbox with no metadata") { t in
            let p = TaskLine.parse("- [x] Ship the deck")
            t.expectEqual(p?.done, true, "done")
            t.expectEqual(p?.text ?? "", "Ship the deck", "text")
            t.expect(p?.due == nil && p?.priority == nil && p?.id == nil, "no metadata")
        }

        t.test("non-checkbox lines are not tasks") { t in
            t.expect(TaskLine.parse("- just a bullet") == nil, "plain bullet → nil")
            t.expect(TaskLine.parse("some prose") == nil, "prose → nil")
            t.expect(TaskLine.parse("## Action Items") == nil, "heading → nil")
        }

        t.test("priority glyphs map to levels") { t in
            t.expectEqual(TaskLine.parse("- [ ] a 🔼")?.priority, .medium, "🔼 → medium")
            t.expectEqual(TaskLine.parse("- [ ] b 🔽")?.priority, .low, "🔽 → low")
            t.expectEqual(TaskLine.parse("- [ ] c 🔺")?.priority, .high, "🔺 → high")
            t.expect(TaskLine.parse("- [ ] d")?.priority == nil, "no glyph → nil")
        }

        t.test("due only, text preserved") { t in
            let p = TaskLine.parse("- [ ] Call Alex 📅 2026-01-02")
            t.expectEqual(p?.text ?? "", "Call Alex", "text")
            t.expectEqual(p?.due ?? "", "2026-01-02", "due")
            t.expect(p?.recurrence == nil, "no recurrence")
        }

        t.test("recurrence phrase stops at a trailing tag") { t in
            let p = TaskLine.parse("- [ ] Weekly sync 🔁 every week #ops")
            t.expectEqual(p?.recurrence ?? "", "every week", "recurrence excludes the tag")
            t.expectEqual(p?.project ?? "", "ops", "tag still becomes project")
            t.expectEqual(p?.text ?? "", "Weekly sync #ops", "tag stays in text")
        }

        t.test("format omits absent fields") { t in
            t.expectEqual(TaskLine.format(text: "bare", done: false), "- [ ] bare", "minimal open")
            t.expectEqual(TaskLine.format(text: "bare", done: true), "- [x] bare", "minimal done")
        }

        t.test("format then parse round-trips the fields") { t in
            let line = TaskLine.format(text: "Do the thing #proj", done: false,
                                       due: "2026-03-04", priority: .high,
                                       recurrence: "every week", id: "zz99")
            let p = TaskLine.parse(line)
            t.expect(p != nil, "reparsed")
            guard let p else { return }
            t.expectEqual(p.text, "Do the thing #proj", "text round-trips")
            t.expectEqual(p.due ?? "", "2026-03-04", "due round-trips")
            t.expectEqual(p.priority, .high, "priority round-trips")
            t.expectEqual(p.recurrence ?? "", "every week", "recurrence round-trips")
            t.expectEqual(p.id ?? "", "zz99", "id round-trips")
            t.expectEqual(p.project ?? "", "proj", "project round-trips")
        }
    }
}
