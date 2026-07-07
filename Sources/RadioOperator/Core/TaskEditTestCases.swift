import Foundation

/// Tests for TaskEdit + TaskDuePreset — the pure compose/date logic behind
/// manual quick-add. Deterministic: fixed "now", UTC calendar.
enum TaskEditTestCases {
    private static var utc: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    static func run(_ t: TestContext) {
        let cal = utc
        let now = cal.date(from: DateComponents(year: 2026, month: 7, day: 7, hour: 12))!  // Tue
        let today = cal.startOfDay(for: now)

        t.test("isoString formats zero-padded") { t in
            let d = cal.date(from: DateComponents(year: 2026, month: 7, day: 3))!
            t.expectEqual(TaskEdit.isoString(from: d, calendar: cal), "2026-07-03")
        }

        t.test("today / tomorrow presets") { t in
            t.expectEqual(TaskDuePreset.today.iso(now: now, calendar: cal),
                          TaskEdit.isoString(from: today, calendar: cal), "today = start of today")
            let tomorrow = cal.date(byAdding: .day, value: 1, to: today)!
            t.expectEqual(TaskDuePreset.tomorrow.iso(now: now, calendar: cal),
                          TaskEdit.isoString(from: tomorrow, calendar: cal), "tomorrow = +1")
        }

        t.test("this Friday resolves to a Friday on/after today, within the week") { t in
            let iso = TaskDuePreset.thisFriday.iso(now: now, calendar: cal)
            let d = TaskIndex.parseDueDate(iso, calendar: cal)!
            t.expectEqual(cal.component(.weekday, from: d), 6, "weekday is Friday")
            t.expect(cal.startOfDay(for: d) >= today, "on or after today")
            t.expect(cal.startOfDay(for: d) < cal.date(byAdding: .day, value: 7, to: today)!, "within this week")
        }

        t.test("next Monday resolves to a Monday strictly after today") { t in
            let iso = TaskDuePreset.nextMonday.iso(now: now, calendar: cal)
            let d = TaskIndex.parseDueDate(iso, calendar: cal)!
            t.expectEqual(cal.component(.weekday, from: d), 2, "weekday is Monday")
            t.expect(cal.startOfDay(for: d) > today, "strictly after today")
        }

        t.test("appendedInbox seeds a heading when empty") { t in
            let out = TaskEdit.appendedInbox(to: "", line: "- [ ] Email Alex")
            t.expect(out.hasPrefix("# Tasks"), "heading seeded")
            t.expect(out.contains("- [ ] Email Alex"), "line present")
            t.expect(out.hasSuffix("\n"), "one trailing newline")
        }

        t.test("appendedInbox appends after existing content") { t in
            let out = TaskEdit.appendedInbox(to: "# Tasks\n\n- [ ] A", line: "- [ ] B")
            t.expect(out.contains("- [ ] A\n- [ ] B"), "B follows A on its own line")
            t.expect(!out.contains("\n\n\n"), "no triple newline")
        }
    }
}
