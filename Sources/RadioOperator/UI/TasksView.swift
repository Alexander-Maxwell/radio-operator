import SwiftUI

// MARK: - Tasks (Console)

/// Cross-meeting task manager. Aggregates the action items parsed from every
/// meeting note (plus the manual `Tasks.md` inbox) via `TaskIndex`, grouped by
/// smart date (Overdue / Today / This week / Later / No date) with summary
/// counts. Toggling a checkbox rewrites the exact source line in the canonical
/// note — the markdown notes stay the source of truth (and stay Obsidian-Tasks
/// compatible, so the same tasks show in the vault). Manual add (Unit 4),
/// filter/sort controls, reminders (Unit 6), and recurrence (Unit 7) follow.
/// How the Tasks list is grouped.
enum TaskGroupMode: String, CaseIterable, Sendable {
    case meeting, date, project
    var label: String {
        switch self {
        case .meeting: "Meeting"
        case .date:    "Due date"
        case .project: "Project"
        }
    }
}

struct TasksView: View {
    @State private var tasks: [RadioTask] = []
    @State private var newText = ""
    @State private var newDue: TaskDuePreset?
    @State private var newPriority: TaskPriority?
    @State private var groupMode: TaskGroupMode = .meeting
    @State private var selected: RadioTask?
    @State private var detailSubtasks: [Subtask] = []
    @State private var detailNotes: String?
    @State private var newSubtask = ""

    private var open: [RadioTask] { tasks.filter { !$0.done } }
    private var done: [RadioTask] { tasks.filter { $0.done } }

    /// Group ALL tasks (open + done) by a key. Items sort open-first then by the
    /// usual order, so a completed task stays in its group (struck through) — an
    /// accidental check is one tap to undo, not a hunt in a separate pile.
    /// Groups with any open task sort ahead of fully-completed ones.
    private func groups(by key: (RadioTask) -> String) -> [(key: String, items: [RadioTask])] {
        Dictionary(grouping: tasks, by: key)
            .map { (key: $0.key, items: $0.value.sorted(by: Self.rowOrder)) }
            .sorted { a, b in
                let ao = a.items.contains { !$0.done }, bo = b.items.contains { !$0.done }
                if ao != bo { return ao }
                return a.key.localizedCaseInsensitiveCompare(b.key) == .orderedAscending
            }
    }

    private func meetingKey(_ t: RadioTask) -> String {
        switch t.source { case .meeting(let title): title; case .manual: "Manual" }
    }

    private func openIn(_ items: [RadioTask]) -> Int { items.filter { !$0.done }.count }

    private var subtaskFraction: Double {
        guard !detailSubtasks.isEmpty else { return 0 }
        return Double(detailSubtasks.filter { $0.done }.count) / Double(detailSubtasks.count)
    }

    private func bucket(_ t: RadioTask) -> TaskBucket { TaskBucket.of(due: t.due, now: Date()) }
    private func count(_ b: TaskBucket) -> Int { open.filter { bucket($0) == b }.count }

    var body: some View {
        VStack(spacing: 0) {
            header
            addBar
            if tasks.isEmpty { emptyState } else { content }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Theme.bgApp)
        .onAppear(perform: reload)
        .overlay { detailOverlay }
    }

    // MARK: Header + metrics

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 9) {
                Text("Tasks")
                    .font(Theme.display(20, .semibold))
                    .foregroundStyle(Theme.textMax)
                if !open.isEmpty {
                    Text("\(open.count)")
                        .font(Theme.mono(11.5))
                        .foregroundStyle(Theme.green)
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(Capsule().fill(Theme.green.opacity(0.12)))
                }
                Spacer()
            }
            HStack(spacing: 6) {
                Image(systemName: "mic").font(.system(size: 10))
                Text("Collected from your meetings — same markdown, editable in your vault.")
                    .font(Theme.display(11.5))
            }
            .foregroundStyle(Theme.textMeta)
        }
        .padding(.horizontal, 22).padding(.top, 16).padding(.bottom, 12)
    }

    private var metricsRow: some View {
        HStack(spacing: 8) {
            metric("Open", open.count, Theme.textHi)
            metric("Overdue", count(.overdue), Theme.recRed)
            metric("Today", count(.today), Theme.amber)
            metric("This week", count(.thisWeek), Theme.textHi)
        }
        .padding(.horizontal, 14).padding(.bottom, 6)
    }

    private func metric(_ label: String, _ value: Int, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(Theme.display(11)).foregroundStyle(Theme.textMeta)
            Text("\(value)").font(Theme.display(20, .semibold)).foregroundStyle(color)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 11).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.lift(0.05)))
    }

    // MARK: Quick add

    private var addBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "plus").font(.system(size: 12)).foregroundStyle(Theme.textFaint)
            TextField("Add a task", text: $newText)
                .textFieldStyle(.plain)
                .font(Theme.display(13))
                .foregroundStyle(Theme.textHi)
                .onSubmit(addTask)
            Menu {
                Button("No date") { newDue = nil }
                ForEach(TaskDuePreset.allCases, id: \.self) { p in
                    Button(p.label) { newDue = p }
                }
            } label: {
                addChip(icon: "calendar", text: newDue?.label ?? "Due")
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            Menu {
                Button("None") { newPriority = nil }
                Button("High") { newPriority = .high }
                Button("Medium") { newPriority = .medium }
                Button("Low") { newPriority = .low }
            } label: {
                addChip(icon: "flag", text: newPriority.map(Self.priorityLabel) ?? "Priority")
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            Button(action: addTask) {
                Text("Add")
                    .font(Theme.display(12, .medium))
                    .foregroundStyle(canAdd ? Theme.green : Theme.textMeta)
            }
            .buttonStyle(.plain)
            .disabled(!canAdd)
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: 9).fill(Theme.lift(0.05)))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Theme.hairline(0.08)))
        .padding(.horizontal, 14).padding(.bottom, 8)
    }

    private var canAdd: Bool { !newText.trimmingCharacters(in: .whitespaces).isEmpty }

    private func addChip(icon: String, text: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon).font(.system(size: 9))
            Text(text)
            Image(systemName: "chevron.down").font(.system(size: 7))
        }
        .font(Theme.display(11)).foregroundStyle(Theme.textDim)
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(Capsule().fill(Theme.lift(0.06)))
    }

    private func addTask() {
        let text = newText.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        let id = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(6)).lowercased()
        let line = TaskLine.format(text: text, done: false,
                                   due: newDue?.iso(now: Date()),
                                   priority: newPriority, id: id)
        let inbox = SettingsStore.shared.notesFolderURL.appendingPathComponent("Tasks.md")
        let existing = (try? String(contentsOf: inbox, encoding: .utf8)) ?? ""
        try? TaskEdit.appendedInbox(to: existing, line: line)
            .write(to: inbox, atomically: true, encoding: .utf8)
        newText = ""; newDue = nil; newPriority = nil
        reload()
    }

    // MARK: Content

    private var content: some View {
        ScrollView {
            metricsRow
            controlsRow
            LazyVStack(alignment: .leading, spacing: 0) {
                switch groupMode {
                case .meeting:
                    ForEach(groups(by: meetingKey), id: \.key) { g in
                        sectionHeader(g.key, openIn(g.items), Theme.speakerRemote)
                        ForEach(g.items) { row($0) }
                    }
                case .project:
                    ForEach(groups(by: { $0.project ?? "No project" }), id: \.key) { g in
                        sectionHeader(g.key == "No project" ? g.key : "#\(g.key)", openIn(g.items), Theme.speakerRemote)
                        ForEach(g.items) { row($0) }
                    }
                case .date:
                    ForEach(TaskBucket.allCases, id: \.self) { b in
                        let items = open.filter { bucket($0) == b }.sorted(by: Self.openBefore)
                        if !items.isEmpty {
                            sectionHeader(b.title, items.count, Self.bucketColor(b))
                            ForEach(items) { row($0) }
                        }
                    }
                    if !done.isEmpty {
                        sectionHeader("Completed", done.count, Theme.textMeta).padding(.top, 12)
                        ForEach(done) { row($0) }
                    }
                }
            }
            .padding(.horizontal, 14).padding(.bottom, 24)
            .animation(.easeInOut(duration: 0.18), value: tasks)
        }
    }

    private var controlsRow: some View {
        HStack(spacing: 8) {
            Menu {
                ForEach(TaskGroupMode.allCases, id: \.self) { m in
                    Button(m.label) { groupMode = m }
                }
            } label: {
                addChip(icon: "square.stack.3d.up", text: "Group: \(groupMode.label)")
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            Spacer()
        }
        .padding(.horizontal, 14).padding(.bottom, 4)
    }

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

    private func sectionHeader(_ label: String, _ n: Int, _ dot: Color) -> some View {
        HStack(spacing: 7) {
            Circle().fill(dot).frame(width: 7, height: 7)
            Text(label).font(Theme.display(12, .medium)).foregroundStyle(Theme.textBright)
            Text("\(n)").font(Theme.mono(11)).foregroundStyle(Theme.textMeta)
        }
        .padding(.horizontal, 6).padding(.top, 12).padding(.bottom, 4)
    }

    private func row(_ task: RadioTask) -> some View {
        HStack(alignment: .top, spacing: 11) {
            Button { toggle(task) } label: {
                Image(systemName: task.done ? "checkmark.square.fill" : "square")
                    .font(.system(size: 15))
                    .foregroundStyle(task.done ? Theme.green : Theme.textFaint)
                    .frame(width: 26, height: 24, alignment: .topLeading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Text(task.text)
                        .font(Theme.display(13.5))
                        .foregroundStyle(task.done ? Theme.textMeta : Theme.textHi)
                        .strikethrough(task.done, color: Theme.textMeta)
                    if let project = task.project { tagPill(project) }
                }
                HStack(spacing: 12) {
                    if let due = task.due { dueChip(due) }
                    if let p = task.priority { priorityChip(p) }
                    sourceChip(task)
                    if task.recurrence != nil {
                        Image(systemName: "repeat").font(.system(size: 9)).foregroundStyle(Theme.textFaint)
                    }
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { open(task) }
            Spacer(minLength: 0)
            rowMenu(task)
        }
        .padding(.horizontal, 6).padding(.vertical, 8)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.hairline(0.05)).frame(height: 1)
        }
    }

    // MARK: Chips

    private func tagPill(_ project: String) -> some View {
        Text("#\(project)")
            .font(Theme.mono(10))
            .foregroundStyle(Theme.speakerRemote)
            .padding(.horizontal, 6).padding(.vertical, 1)
            .background(Capsule().fill(Theme.speakerRemote.opacity(0.12)))
    }

    private func dueChip(_ due: Date) -> some View {
        let b = TaskBucket.of(due: due, now: Date())
        let color: Color = b == .overdue ? Theme.recRed : (b == .today ? Theme.amber : Theme.textDim)
        return HStack(spacing: 3) {
            Image(systemName: "calendar").font(.system(size: 8.5))
            Text(b == .today ? "Today" : Self.dueFormatter.string(from: due))
        }
        .font(Theme.display(11)).foregroundStyle(color)
    }

    private func priorityChip(_ p: TaskPriority) -> some View {
        let (label, color): (String, Color)
        switch p {
        case .high:   (label, color) = ("High", Theme.amber)
        case .medium: (label, color) = ("Med", Theme.textDim)
        case .low:    (label, color) = ("Low", Theme.textMeta)
        }
        return HStack(spacing: 3) {
            Image(systemName: "flag").font(.system(size: 8.5))
            Text(label)
        }
        .font(Theme.display(11)).foregroundStyle(color)
    }

    @ViewBuilder private func sourceChip(_ task: RadioTask) -> some View {
        switch task.source {
        case .meeting(let title):
            Button { openSource(task) } label: {
                HStack(spacing: 3) {
                    Image(systemName: "mic").font(.system(size: 8.5))
                    Text(title).lineLimit(1)
                }
                .font(Theme.display(11)).foregroundStyle(Theme.speakerRemote)
            }
            .buttonStyle(.plain)
        case .manual:
            HStack(spacing: 3) {
                Image(systemName: "pencil").font(.system(size: 8.5))
                Text("Manual")
            }
            .font(Theme.display(11)).foregroundStyle(Theme.textMeta)
        }
    }

    // MARK: Actions

    private func reload() {
        let notes = SettingsStore.shared.notesFolderURL
        let meetings = notes.appendingPathComponent("Meetings", isDirectory: true)
        Task {
            let loaded = await Task.detached(priority: .userInitiated) {
                TaskIndex.rebuild(notesFolder: notes, meetingsFolder: meetings)
            }.value
            await MainActor.run {
                self.tasks = loaded
                if let s = self.selected, let fresh = loaded.first(where: { $0.id == s.id }) {
                    self.selected = fresh
                    self.loadChildren(fresh)
                }
            }
        }
    }

    private func toggle(_ task: RadioTask) {
        guard let content = try? String(contentsOf: task.sourceFile, encoding: .utf8),
              let updated = MeetingNoteParser.togglingCheckbox(in: content, sourceLine: task.sourceLine)
        else { return }
        try? updated.write(to: task.sourceFile, atomically: true, encoding: .utf8)
        // Optimistic: flip in memory immediately so the checkbox is instantly
        // consistent and a fast re-tap can't act on a stale line while the
        // background rescan is still in flight (that window made undo feel stuck).
        if let i = tasks.firstIndex(where: { $0.id == task.id && $0.sourceLine == task.sourceLine }),
           let flipped = MeetingNoteParser.togglingCheckbox(in: task.sourceLine, sourceLine: task.sourceLine) {
            withAnimation(.easeInOut(duration: 0.18)) {
                tasks[i].sourceLine = flipped
                tasks[i].done.toggle()
            }
        }
        reload()
    }

    private func openSource(_ task: RadioTask) {
        guard case .meeting = task.source else { return }
        HubState.shared.pendingMeetingID = task.sourceFile.lastPathComponent
        HubState.shared.section = .meetings
    }

    private func rowMenu(_ task: RadioTask) -> some View {
        Menu {
            Menu("Set due") {
                ForEach(TaskDuePreset.allCases, id: \.self) { p in
                    Button(p.label) { applyEdit(task) { $0.due = TaskIndex.parseDueDate(p.iso(now: Date())) } }
                }
                if task.due != nil { Button("Clear due") { applyEdit(task) { $0.due = nil } } }
            }
            Menu("Priority") {
                Button("High") { applyEdit(task) { $0.priority = .high } }
                Button("Medium") { applyEdit(task) { $0.priority = .medium } }
                Button("Low") { applyEdit(task) { $0.priority = .low } }
                if task.priority != nil { Button("Clear") { applyEdit(task) { $0.priority = nil } } }
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 12))
                .foregroundStyle(Theme.textFaint)
                .frame(width: 20, height: 20)
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
    }

    /// Apply an edit to a task by re-rendering its canonical line and replacing
    /// it in the source note in place. Works for meeting notes and the inbox.
    private func applyEdit(_ task: RadioTask, _ transform: (inout RadioTask) -> Void) {
        var edited = task
        transform(&edited)
        let newLine = edited.canonicalLine()
        guard newLine != task.sourceLine,
              let content = try? String(contentsOf: task.sourceFile, encoding: .utf8),
              let updated = TaskEdit.replacingLine(in: content, oldLine: task.sourceLine, with: newLine)
        else { return }
        try? updated.write(to: task.sourceFile, atomically: true, encoding: .utf8)
        reload()
    }

    // MARK: Detail panel

    @ViewBuilder private var detailOverlay: some View {
        if let task = selected {
            Color.black.opacity(0.25)
                .ignoresSafeArea()
                .onTapGesture { closeDetail() }
                .transition(.opacity)
            HStack(spacing: 0) {
                Spacer(minLength: 0)
                detailPanel(task)
                    .frame(width: 344)
                    .frame(maxHeight: .infinity)
                    .background(Theme.bgSidebar)
                    .overlay(alignment: .leading) { Rectangle().fill(Theme.hairline(0.12)).frame(width: 1) }
                    .transition(.move(edge: .trailing))
            }
        }
    }

    private func detailPanel(_ task: RadioTask) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Button { closeDetail() } label: {
                        Image(systemName: "xmark").font(.system(size: 12)).foregroundStyle(Theme.textDim)
                    }.buttonStyle(.plain)
                    Spacer()
                    if isMeeting(task) {
                        Button { openSource(task); closeDetail() } label: {
                            Image(systemName: "arrow.up.forward.square").font(.system(size: 13)).foregroundStyle(Theme.textDim)
                        }.buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 8)

                HStack(alignment: .top, spacing: 11) {
                    Button { toggle(task) } label: {
                        Image(systemName: task.done ? "checkmark.square.fill" : "square")
                            .font(.system(size: 18)).foregroundStyle(task.done ? Theme.green : Theme.textFaint)
                    }.buttonStyle(.plain)
                    Text(task.text)
                        .font(Theme.display(16, .medium))
                        .foregroundStyle(task.done ? Theme.textMeta : Theme.textMax)
                        .strikethrough(task.done, color: Theme.textMeta)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 14).padding(.bottom, 12)

                fieldRow("Status", "circle.dashed") { statusPill(task) }
                fieldRow("Due date", "calendar") { dueField(task) }
                fieldRow("Priority", "flag") { priorityField(task) }
                if let project = task.project { fieldRow("Project", "tag") { tagPill(project) } }
                fieldRow("From", "mic") { sourceChip(task) }

                subtasksSection(task)

                if let notes = detailNotes {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 8) {
                            Image(systemName: "note.text").font(.system(size: 12))
                            Text("Notes").font(Theme.display(12.5))
                        }
                        .foregroundStyle(Theme.textDim)
                        Text(notes).font(Theme.display(13)).foregroundStyle(Theme.textBody)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(14)
                    .overlay(alignment: .top) { Rectangle().fill(Theme.hairline(0.06)).frame(height: 1) }
                }
            }
        }
    }

    private func fieldRow<V: View>(_ label: String, _ icon: String, @ViewBuilder value: () -> V) -> some View {
        HStack(spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: icon).font(.system(size: 12))
                Text(label).font(Theme.display(12.5))
            }
            .foregroundStyle(Theme.textDim)
            .frame(width: 96, alignment: .leading)
            value()
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
        .overlay(alignment: .top) { Rectangle().fill(Theme.hairline(0.06)).frame(height: 1) }
    }

    private func statusPill(_ task: RadioTask) -> some View {
        Button { toggle(task) } label: {
            Text(task.done ? "Done" : "Open")
                .font(Theme.mono(10.5))
                .foregroundStyle(task.done ? Theme.green : Theme.textDim)
                .padding(.horizontal, 9).padding(.vertical, 2)
                .background(Capsule().fill((task.done ? Theme.green : Theme.textDim).opacity(0.14)))
        }.buttonStyle(.plain)
    }

    private func dueField(_ task: RadioTask) -> some View {
        Menu {
            ForEach(TaskDuePreset.allCases, id: \.self) { p in
                Button(p.label) { applyEdit(task) { $0.due = TaskIndex.parseDueDate(p.iso(now: Date())) } }
            }
            if task.due != nil { Button("Clear") { applyEdit(task) { $0.due = nil } } }
        } label: {
            if let due = task.due { dueChip(due) } else { addValueLabel("Add date") }
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
    }

    private func priorityField(_ task: RadioTask) -> some View {
        Menu {
            Button("High") { applyEdit(task) { $0.priority = .high } }
            Button("Medium") { applyEdit(task) { $0.priority = .medium } }
            Button("Low") { applyEdit(task) { $0.priority = .low } }
            if task.priority != nil { Button("Clear") { applyEdit(task) { $0.priority = nil } } }
        } label: {
            if let p = task.priority { priorityChip(p) } else { addValueLabel("Add") }
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
    }

    private func addValueLabel(_ text: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "plus").font(.system(size: 9))
            Text(text)
        }
        .font(Theme.display(12)).foregroundStyle(Theme.textMeta)
    }

    private func subtasksSection(_ task: RadioTask) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                HStack(spacing: 8) {
                    Image(systemName: "checklist").font(.system(size: 12))
                    Text("Subtasks").font(Theme.display(12.5))
                }
                .foregroundStyle(Theme.textDim)
                Spacer()
                if !detailSubtasks.isEmpty {
                    Text("\(detailSubtasks.filter { $0.done }.count) / \(detailSubtasks.count)")
                        .font(Theme.mono(11)).foregroundStyle(Theme.textMeta)
                }
            }
            if !detailSubtasks.isEmpty {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Theme.lift(0.12))
                        Capsule().fill(Theme.green).frame(width: geo.size.width * subtaskFraction)
                    }
                }
                .frame(height: 5)
            }
            ForEach(detailSubtasks, id: \.sourceLine) { sub in
                Button { toggleSubtask(sub, in: task) } label: {
                    HStack(spacing: 9) {
                        Image(systemName: sub.done ? "checkmark.square.fill" : "square")
                            .font(.system(size: 14)).foregroundStyle(sub.done ? Theme.green : Theme.textFaint)
                        Text(sub.text).font(Theme.display(13))
                            .foregroundStyle(sub.done ? Theme.textMeta : Theme.textBody)
                            .strikethrough(sub.done, color: Theme.textMeta)
                        Spacer(minLength: 0)
                    }
                }.buttonStyle(.plain)
            }
            HStack(spacing: 8) {
                Image(systemName: "plus").font(.system(size: 11)).foregroundStyle(Theme.textFaint)
                TextField("Add subtask", text: $newSubtask)
                    .textFieldStyle(.plain).font(Theme.display(13)).foregroundStyle(Theme.textHi)
                    .onSubmit { addSubtask(to: task) }
            }
            .padding(.top, 2)
        }
        .padding(14)
        .overlay(alignment: .top) { Rectangle().fill(Theme.hairline(0.06)).frame(height: 1) }
    }

    private func isMeeting(_ t: RadioTask) -> Bool {
        if case .meeting = t.source { return true }
        return false
    }

    private func open(_ task: RadioTask) {
        loadChildren(task)
        newSubtask = ""
        withAnimation(.easeOut(duration: 0.22)) { selected = task }
    }

    private func closeDetail() {
        withAnimation(.easeOut(duration: 0.2)) { selected = nil }
    }

    private func loadChildren(_ task: RadioTask) {
        guard let content = try? String(contentsOf: task.sourceFile, encoding: .utf8) else {
            detailSubtasks = []; detailNotes = nil; return
        }
        let c = TaskDetail.children(in: content, parentLine: task.sourceLine)
        detailSubtasks = c.subtasks
        detailNotes = c.notes
    }

    private func toggleSubtask(_ sub: Subtask, in task: RadioTask) {
        guard let content = try? String(contentsOf: task.sourceFile, encoding: .utf8),
              let updated = MeetingNoteParser.togglingCheckbox(in: content, sourceLine: sub.sourceLine)
        else { return }
        try? updated.write(to: task.sourceFile, atomically: true, encoding: .utf8)
        withAnimation(.easeInOut(duration: 0.18)) { loadChildren(task) }
    }

    private func addSubtask(to task: RadioTask) {
        let text = newSubtask.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty,
              let content = try? String(contentsOf: task.sourceFile, encoding: .utf8),
              let updated = TaskDetail.addingSubtask(text, to: content, parentLine: task.sourceLine)
        else { return }
        try? updated.write(to: task.sourceFile, atomically: true, encoding: .utf8)
        newSubtask = ""
        withAnimation(.easeInOut(duration: 0.18)) { loadChildren(task) }
    }

    // MARK: Sort / color

    /// Order within a group: open tasks before completed, then the open order.
    private static func rowOrder(_ a: RadioTask, _ b: RadioTask) -> Bool {
        if a.done != b.done { return !a.done }
        return openBefore(a, b)
    }

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

    private static func priorityLabel(_ p: TaskPriority) -> String {
        switch p { case .high: "High"; case .medium: "Med"; case .low: "Low" }
    }

    private static func bucketColor(_ b: TaskBucket) -> Color {
        switch b {
        case .overdue:  Theme.recRed
        case .today:    Theme.amber
        case .thisWeek: Theme.speakerRemote
        case .later:    Theme.textDim
        case .noDate:   Theme.textMeta
        }
    }

    private static let dueFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d"
        return f
    }()
}
