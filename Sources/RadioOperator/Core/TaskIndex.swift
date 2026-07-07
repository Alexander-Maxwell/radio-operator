import Foundation

/// A single task in the aggregated view. Built from a `ParsedTaskLine` plus its
/// origin. Notes remain the source of truth; a `RadioTask` is the in-memory,
/// query-friendly projection. `sourceFile` + `sourceLine` locate the exact
/// markdown line for in-place rewrites (toggle/edit).
struct RadioTask: Identifiable, Equatable, Sendable {
    enum Source: Equatable, Sendable {
        case meeting(title: String)
        case manual
    }

    let id: String
    var text: String
    var done: Bool
    var due: Date?
    var priority: TaskPriority?
    var project: String?
    var recurrence: String?
    let source: Source
    let sourceFile: URL
    var sourceLine: String
}

extension RadioTask {
    /// Project a parsed line into a task. Synthesizes a stable id from file+text
    /// when the line has no 🆔 yet (an id is stamped lazily on first interaction).
    init(parsed p: ParsedTaskLine, source: Source, file: URL, calendar: Calendar) {
        self.init(
            id: p.id ?? "\(file.lastPathComponent)#\(p.text)",
            text: p.text,
            done: p.done,
            due: p.due.flatMap { TaskIndex.parseDueDate($0, calendar: calendar) },
            priority: p.priority,
            project: p.project,
            recurrence: p.recurrence,
            source: source,
            sourceFile: file,
            sourceLine: p.sourceLine)
    }
}

/// Aggregates tasks across meeting notes + the manual inbox into one list. The
/// per-content extraction is pure and unit-tested; `rebuild` is the thin I/O
/// wrapper. This is a rebuildable cache — the markdown notes stay canonical.
enum TaskIndex {

    /// Tasks from ONE meeting note: only checkbox lines in the Action Items
    /// section (reuses MeetingNoteParser's section detection, so transcript
    /// checkboxes never leak in). Plain-bullet action items are not tasks.
    static func tasksFromMeeting(url: URL, title: String, content: String,
                                 calendar: Calendar = .current) -> [RadioTask] {
        MeetingNoteParser.parse(content).actionItems.compactMap { item in
            TaskLine.parse(item.sourceLine).map {
                RadioTask(parsed: $0, source: .meeting(title: title), file: url, calendar: calendar)
            }
        }
    }

    /// Tasks from the manual `Tasks.md` inbox: every checkbox line is a task.
    static func tasksFromInbox(url: URL, content: String,
                               calendar: Calendar = .current) -> [RadioTask] {
        content.components(separatedBy: "\n").compactMap { line in
            TaskLine.parse(line).map {
                RadioTask(parsed: $0, source: .manual, file: url, calendar: calendar)
            }
        }
    }

    /// ISO `yyyy-MM-dd` → a Date at the start of that day in `calendar`. Nil if
    /// malformed. Calendar is injected so this is deterministic under test.
    static func parseDueDate(_ iso: String, calendar: Calendar = .current) -> Date? {
        let p = iso.split(separator: "-")
        guard p.count == 3, let y = Int(p[0]), let m = Int(p[1]), let d = Int(p[2]) else { return nil }
        return calendar.date(from: DateComponents(year: y, month: m, day: d))
    }

    /// I/O: scan every meeting note + the inbox → the full task list.
    static func rebuild(notesFolder: URL, meetingsFolder: URL,
                        calendar: Calendar = .current) -> [RadioTask] {
        var out: [RadioTask] = []
        for meta in NotesStore.listMeetings(in: meetingsFolder) {
            guard let content = try? String(contentsOf: meta.url, encoding: .utf8) else { continue }
            out += tasksFromMeeting(url: meta.url, title: meta.title,
                                    content: content, calendar: calendar)
        }
        let inbox = notesFolder.appendingPathComponent("Tasks.md")
        if let content = try? String(contentsOf: inbox, encoding: .utf8) {
            out += tasksFromInbox(url: inbox, content: content, calendar: calendar)
        }
        return out
    }
}
