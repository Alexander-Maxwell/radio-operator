import SwiftUI

// MARK: - Tasks (Console)

/// Cross-meeting task list. Aggregates the action items already parsed from
/// every meeting note (plus the manual `Tasks.md` inbox) into one view via
/// `TaskIndex`. Toggling a checkbox rewrites the exact source line in the
/// canonical note — the notes stay the source of truth. (Unit 3: aggregation +
/// done-toggle + source deep-link. Manual add, due/priority sorting, reminders,
/// and recurrence layer on in later units.)
struct TasksView: View {
    @State private var tasks: [RadioTask] = []

    private var openTasks: [RadioTask] { tasks.filter { !$0.done }.sorted(by: Self.openBefore) }
    private var doneTasks: [RadioTask] { tasks.filter { $0.done } }

    var body: some View {
        VStack(spacing: 0) {
            header
            if tasks.isEmpty { emptyState } else { list }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Theme.bgApp)
        .onAppear(perform: reload)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 9) {
            Text("Tasks")
                .font(Theme.display(20, .semibold))
                .foregroundStyle(Theme.textMax)
            if !openTasks.isEmpty {
                Text("\(openTasks.count)")
                    .font(Theme.mono(11.5))
                    .foregroundStyle(Theme.green)
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(Capsule().fill(Theme.green.opacity(0.12)))
            }
            Spacer()
        }
        .padding(.horizontal, 22).padding(.vertical, 16)
    }

    // MARK: Empty state

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 32, weight: .light))
                .foregroundStyle(Theme.textMeta)
            Text("No open tasks")
                .font(Theme.display(15, .medium))
                .foregroundStyle(Theme.textBody)
            Text("Action items from your meetings show up here automatically.")
                .font(Theme.display(12.5))
                .foregroundStyle(Theme.textFaint)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }

    // MARK: List

    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if !openTasks.isEmpty {
                    sectionHeader("OPEN", openTasks.count)
                    ForEach(openTasks) { row($0) }
                }
                if !doneTasks.isEmpty {
                    sectionHeader("DONE", doneTasks.count).padding(.top, 14)
                    ForEach(doneTasks) { row($0) }
                }
            }
            .padding(.horizontal, 14).padding(.bottom, 24)
        }
    }

    private func sectionHeader(_ label: String, _ count: Int) -> some View {
        Text("\(label) · \(count)")
            .font(Theme.mono(10)).tracking(1.6)
            .foregroundStyle(Theme.textMono)
            .padding(.horizontal, 10).padding(.vertical, 8)
    }

    private func row(_ task: RadioTask) -> some View {
        HStack(alignment: .top, spacing: 11) {
            Button { toggle(task) } label: {
                Image(systemName: task.done ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 16))
                    .foregroundStyle(task.done ? Theme.green : Theme.textFaint)
            }
            .buttonStyle(.plain)
            .padding(.top, 1)

            VStack(alignment: .leading, spacing: 4) {
                Text(task.text)
                    .font(Theme.display(13.5))
                    .foregroundStyle(task.done ? Theme.textMeta : Theme.textHi)
                    .strikethrough(task.done, color: Theme.textMeta)
                HStack(spacing: 8) {
                    sourceChip(task)
                    if let due = task.due { dueChip(due) }
                    if let p = task.priority { priorityChip(p) }
                    if task.recurrence != nil {
                        Image(systemName: "repeat")
                            .font(.system(size: 9))
                            .foregroundStyle(Theme.textFaint)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.hairline(0.05)).frame(height: 1)
        }
    }

    // MARK: Chips

    @ViewBuilder private func sourceChip(_ task: RadioTask) -> some View {
        switch task.source {
        case .meeting(let title):
            Button { openSource(task) } label: {
                HStack(spacing: 3) {
                    Image(systemName: "arrow.uturn.backward").font(.system(size: 8.5))
                    Text(title).lineLimit(1)
                }
                .font(Theme.display(11))
                .foregroundStyle(Theme.textDim)
            }
            .buttonStyle(.plain)
        case .manual:
            Text("Manual").font(Theme.display(11)).foregroundStyle(Theme.textMeta)
        }
    }

    private func dueChip(_ due: Date) -> some View {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let dueDay = cal.startOfDay(for: due)
        let overdue = dueDay < today
        let color: Color = overdue ? Color(red: 0.94, green: 0.31, blue: 0.24)
            : (dueDay == today ? Theme.amber : Theme.textDim)
        return HStack(spacing: 3) {
            Image(systemName: "calendar").font(.system(size: 8.5))
            Text(Self.dueFormatter.string(from: due))
        }
        .font(Theme.display(11))
        .foregroundStyle(color)
    }

    private func priorityChip(_ p: TaskPriority) -> some View {
        let (label, color): (String, Color)
        switch p {
        case .high:   (label, color) = ("High", Theme.amber)
        case .medium: (label, color) = ("Med", Theme.textDim)
        case .low:    (label, color) = ("Low", Theme.textMeta)
        }
        return Text(label)
            .font(Theme.mono(9.5)).tracking(0.5)
            .foregroundStyle(color)
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(RoundedRectangle(cornerRadius: 4).fill(color.opacity(0.12)))
    }

    // MARK: Actions

    private func reload() {
        let notes = SettingsStore.shared.notesFolderURL
        let meetings = notes.appendingPathComponent("Meetings", isDirectory: true)
        Task {
            let loaded = await Task.detached(priority: .userInitiated) {
                TaskIndex.rebuild(notesFolder: notes, meetingsFolder: meetings)
            }.value
            await MainActor.run { self.tasks = loaded }
        }
    }

    /// Flip the checkbox in the canonical note (byte-preserving), then rescan.
    private func toggle(_ task: RadioTask) {
        guard let content = try? String(contentsOf: task.sourceFile, encoding: .utf8),
              let updated = MeetingNoteParser.togglingCheckbox(in: content, sourceLine: task.sourceLine)
        else { return }
        try? updated.write(to: task.sourceFile, atomically: true, encoding: .utf8)
        reload()
    }

    private func openSource(_ task: RadioTask) {
        guard case .meeting = task.source else { return }
        HubState.shared.pendingMeetingID = task.sourceFile.lastPathComponent
        HubState.shared.section = .meetings
    }

    // MARK: Sort

    /// Open tasks: earliest due first (undated last), then higher priority,
    /// then alphabetical. Smart-date grouping + filters arrive in Unit 5.
    private static func openBefore(_ a: RadioTask, _ b: RadioTask) -> Bool {
        switch (a.due, b.due) {
        case let (x?, y?) where x != y: return x < y
        case (nil, _?): return false
        case (_?, nil): return true
        default: break
        }
        let pa = a.priority?.weight ?? 0, pb = b.priority?.weight ?? 0
        if pa != pb { return pa > pb }
        return a.text.localizedCaseInsensitiveCompare(b.text) == .orderedAscending
    }

    private static let dueFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d"
        return f
    }()
}
