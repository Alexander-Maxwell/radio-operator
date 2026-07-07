import Foundation

/// Smart-date bucket for a task, relative to "now". Drives the grouped sections
/// and the summary counts in the Tasks view (Overdue / Today / This week /
/// Later / No date). Pure so it can be unit-tested with an injected clock.
enum TaskBucket: String, CaseIterable, Sendable {
    case overdue, today, thisWeek, later, noDate

    var title: String {
        switch self {
        case .overdue:  "Overdue"
        case .today:    "Today"
        case .thisWeek: "This week"
        case .later:    "Later"
        case .noDate:   "No date"
        }
    }

    /// Which bucket a due date falls in. `thisWeek` is the next six days after
    /// today; day seven and beyond is `later`. A nil due date is `noDate`.
    static func of(due: Date?, now: Date, calendar: Calendar = .current) -> TaskBucket {
        guard let due else { return .noDate }
        let today = calendar.startOfDay(for: now)
        let dueDay = calendar.startOfDay(for: due)
        if dueDay < today { return .overdue }
        if dueDay == today { return .today }
        if let weekEnd = calendar.date(byAdding: .day, value: 7, to: today), dueDay < weekEnd {
            return .thisWeek
        }
        return .later
    }
}
