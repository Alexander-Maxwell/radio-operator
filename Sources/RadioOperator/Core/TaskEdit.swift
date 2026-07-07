import Foundation

/// Quick due-date presets for the add bar (avoids a fiddly in-menu date picker
/// for the common cases). Resolves to an ISO `yyyy-MM-dd` string.
enum TaskDuePreset: String, CaseIterable, Sendable {
    case today, tomorrow, thisFriday, nextMonday

    var label: String {
        switch self {
        case .today:      "Today"
        case .tomorrow:   "Tomorrow"
        case .thisFriday: "This Friday"
        case .nextMonday: "Next Monday"
        }
    }

    func iso(now: Date, calendar: Calendar = .current) -> String {
        let today = calendar.startOfDay(for: now)
        let date: Date
        switch self {
        case .today:      date = today
        case .tomorrow:   date = calendar.date(byAdding: .day, value: 1, to: today)!
        case .thisFriday: date = TaskEdit.nextWeekday(6, onOrAfter: true, from: today, calendar: calendar)
        case .nextMonday: date = TaskEdit.nextWeekday(2, onOrAfter: false, from: today, calendar: calendar)
        }
        return TaskEdit.isoString(from: date, calendar: calendar)
    }
}

/// Pure helpers for composing/writing task markdown. File I/O lives in the view;
/// these are the testable string transforms.
enum TaskEdit {
    /// A Date → `yyyy-MM-dd`, calendar-injected for determinism.
    static func isoString(from date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// The next date with the given weekday (1=Sun … 7=Sat). `onOrAfter` keeps
    /// `day` itself if it already matches; otherwise the next occurrence.
    static func nextWeekday(_ weekday: Int, onOrAfter: Bool, from day: Date,
                            calendar: Calendar) -> Date {
        let wd = calendar.component(.weekday, from: day)
        var delta = ((weekday - wd) % 7 + 7) % 7
        if !onOrAfter && delta == 0 { delta = 7 }
        return calendar.date(byAdding: .day, value: delta, to: day)!
    }

    /// Append a task line to the manual `Tasks.md` content, seeding a heading
    /// when the file is empty. Always leaves exactly one trailing newline.
    static func appendedInbox(to content: String, line: String) -> String {
        if content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "# Tasks\n\n\(line)\n"
        }
        var body = content
        while body.hasSuffix("\n") { body.removeLast() }
        return body + "\n" + line + "\n"
    }
}
