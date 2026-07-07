import Foundation

/// One indented child checkbox under a task — a subtask.
struct Subtask: Equatable, Sendable {
    let text: String
    let done: Bool
    let sourceLine: String
}

/// Reads/writes a task's indented children in the note markdown. A child is any
/// line indented more than the parent (block ends at a blank line, a dedent, or
/// EOF). Checkbox children are subtasks; a plain indented line is notes. Pure —
/// the detail panel does the file I/O and reuses `togglingCheckbox` for toggles.
enum TaskDetail {
    static func indentWidth(_ line: String) -> Int {
        line.prefix { $0 == " " || $0 == "\t" }.count
    }

    /// Subtasks + a joined notes string found directly under `parentLine`.
    static func children(in content: String, parentLine: String) -> (subtasks: [Subtask], notes: String?) {
        let lines = content.components(separatedBy: "\n")
        guard let p = lines.firstIndex(of: parentLine) else { return ([], nil) }
        let base = indentWidth(parentLine)
        var subs: [Subtask] = []
        var notes: [String] = []
        var i = p + 1
        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { break }
            if indentWidth(line) <= base { break }
            if trimmed.hasPrefix("- [ ]") {
                subs.append(Subtask(text: String(trimmed.dropFirst(5)).trimmingCharacters(in: .whitespaces),
                                    done: false, sourceLine: line))
            } else if trimmed.hasPrefix("- [x]") || trimmed.hasPrefix("- [X]") {
                subs.append(Subtask(text: String(trimmed.dropFirst(5)).trimmingCharacters(in: .whitespaces),
                                    done: true, sourceLine: line))
            } else if trimmed.hasPrefix("- ") {
                notes.append(String(trimmed.dropFirst(2)))
            } else {
                notes.append(trimmed)
            }
            i += 1
        }
        return (subs, notes.isEmpty ? nil : notes.joined(separator: " "))
    }

    /// Insert a new subtask indented under the parent, after its existing
    /// children. Nil if the parent line isn't found.
    static func addingSubtask(_ text: String, to content: String, parentLine: String) -> String? {
        var lines = content.components(separatedBy: "\n")
        guard let p = lines.firstIndex(of: parentLine) else { return nil }
        let base = indentWidth(parentLine)
        var insertAt = p + 1
        while insertAt < lines.count {
            let line = lines[insertAt]
            if line.trimmingCharacters(in: .whitespaces).isEmpty { break }
            if indentWidth(line) <= base { break }
            insertAt += 1
        }
        let childIndent = String(repeating: " ", count: base + 2)
        lines.insert("\(childIndent)- [ ] \(text)", at: insertAt)
        return lines.joined(separator: "\n")
    }
}
