import Foundation

/// Tests for TaskBucket.of — the smart-date grouping behind the Tasks view.
/// Deterministic: a fixed "now" and a UTC calendar.
enum TaskBucketTestCases {
    private static var utc: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    static func run(_ t: TestContext) {
        let cal = utc
        // Fixed "now": 2026-07-07 15:00 UTC (mid-afternoon, so start-of-day math is exercised).
        let now = cal.date(from: DateComponents(year: 2026, month: 7, day: 7, hour: 15))!
        func day(_ offset: Int) -> Date {
            cal.date(byAdding: .day, value: offset, to: cal.startOfDay(for: now))!
        }

        t.test("nil due → noDate") { t in
            t.expectEqual(TaskBucket.of(due: nil, now: now, calendar: cal), .noDate)
        }
        t.test("yesterday → overdue") { t in
            t.expectEqual(TaskBucket.of(due: day(-1), now: now, calendar: cal), .overdue)
        }
        t.test("earlier today (before now) → today, not overdue") { t in
            let earlier = cal.date(from: DateComponents(year: 2026, month: 7, day: 7, hour: 9))!
            t.expectEqual(TaskBucket.of(due: earlier, now: now, calendar: cal), .today)
        }
        t.test("today (start of day) → today") { t in
            t.expectEqual(TaskBucket.of(due: day(0), now: now, calendar: cal), .today)
        }
        t.test("in 3 days → thisWeek") { t in
            t.expectEqual(TaskBucket.of(due: day(3), now: now, calendar: cal), .thisWeek)
        }
        t.test("in 6 days → thisWeek (last day of the window)") { t in
            t.expectEqual(TaskBucket.of(due: day(6), now: now, calendar: cal), .thisWeek)
        }
        t.test("in 7 days → later (window is exclusive at day seven)") { t in
            t.expectEqual(TaskBucket.of(due: day(7), now: now, calendar: cal), .later)
        }
        t.test("in 30 days → later") { t in
            t.expectEqual(TaskBucket.of(due: day(30), now: now, calendar: cal), .later)
        }
    }
}
