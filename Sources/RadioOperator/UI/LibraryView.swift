import SwiftUI
import AppKit

/// Browsable capture history: dictations (SQLite) and meeting notes (markdown
/// on disk), with a read-in-place detail pane for notes.
struct LibraryView: View {
    @EnvironmentObject var settings: SettingsStore

    private enum Tab: String, CaseIterable {
        case dictations = "Dictations"
        case meetings = "Meetings"
    }

    @State private var tab: Tab = .dictations

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("", selection: $tab) {
                    ForEach(Tab.allCases, id: \.self) { Text($0.rawValue) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 280)
                Spacer()
            }
            .padding(12)
            Divider()
            switch tab {
            case .dictations: DictationHistoryList()
            case .meetings: MeetingLibrary()
            }
        }
        .frame(minWidth: 640, minHeight: 440)
    }
}

// MARK: - Dictations

private struct DictationHistoryList: View {
    @EnvironmentObject var settings: SettingsStore
    @State private var records: [DictationRecord] = []
    @State private var selection: DictationRecord.ID?
    @State private var expanded: Set<Int64> = []

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("\(records.count) dictations")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    reload()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Refresh")
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            if records.isEmpty {
                emptyState
            } else {
                list
            }
        }
        .onAppear(perform: reload)
    }

    private var list: some View {
        List(selection: $selection) {
            ForEach(dayGroups, id: \.title) { group in
                Section(group.title) {
                    ForEach(group.items) { record in
                        DictationRow(
                            record: record,
                            isExpanded: expanded.contains(record.id),
                            onToggleExpand: {
                                if expanded.contains(record.id) {
                                    expanded.remove(record.id)
                                } else {
                                    expanded.insert(record.id)
                                }
                            },
                            onCopy: { copyToPasteboard(record.cleanedText) },
                            onDelete: {
                                HistoryStore.shared.delete(id: record.id)
                                reload()
                            })
                    }
                }
            }
        }
        // Cmd+C copies the arrow-key-selected row's cleaned text.
        .onCopyCommand {
            guard let selection,
                  let record = records.first(where: { $0.id == selection }) else { return [] }
            return [NSItemProvider(object: record.cleanedText as NSString)]
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "mic")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("No dictations yet. Hold \(hotkeyName) anywhere and speak — it lands at your cursor and here.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 380)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    private var hotkeyName: String {
        settings.data.holdHotkey.displayName.replacingOccurrences(of: "Hold ", with: "")
    }

    private func reload() {
        records = HistoryStore.shared.recent()
    }

    private struct DayGroup {
        let title: String
        let items: [DictationRecord]
    }

    private var dayGroups: [DayGroup] {
        let cal = Calendar.current
        let byDay = Dictionary(grouping: records) { cal.startOfDay(for: $0.timestamp) }
        return byDay.keys.sorted(by: >).map { day in
            DayGroup(title: Self.dayTitle(day), items: byDay[day] ?? [])
        }
    }

    private static func dayTitle(_ day: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(day) { return "Today" }
        if cal.isDateInYesterday(day) { return "Yesterday" }
        let df = DateFormatter()
        df.dateStyle = .medium
        return df.string(from: day)
    }
}

private struct DictationRow: View {
    let record: DictationRecord
    let isExpanded: Bool
    let onToggleExpand: () -> Void
    let onCopy: () -> Void
    let onDelete: () -> Void

    @State private var showRaw = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(record.cleanedText)
                .lineLimit(isExpanded ? nil : 2)
                .onTapGesture(perform: onToggleExpand)
            HStack(spacing: 8) {
                Text(record.timestamp.formatted(date: .omitted, time: .shortened))
                if let app = record.appBundleID {
                    Text(app)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                if !record.pasteOK {
                    Text("not pasted")
                        .font(.caption2)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(.orange.opacity(0.2), in: Capsule())
                        .foregroundStyle(.orange)
                }
                Spacer()
                Button(action: onCopy) {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .help("Copy")
                Button(action: onDelete) {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help("Delete")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            if record.rawText != record.cleanedText {
                DisclosureGroup(isExpanded: $showRaw) {
                    Text(record.rawText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                } label: {
                    Text("raw")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
        .contextMenu {
            Button("Copy", action: onCopy)
            Button("Delete", role: .destructive, action: onDelete)
        }
    }
}

// MARK: - Meetings

private struct MeetingLibrary: View {
    @State private var metas: [MeetingNoteMeta] = []
    @State private var selectedID: MeetingNoteMeta.ID?
    @State private var detailContent: String?
    @State private var inFlight: Set<String> = []

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("\(metas.count) meetings")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    reload()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Refresh")
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            if metas.isEmpty {
                emptyState
            } else {
                HSplitView {
                    list
                        .frame(minWidth: 280, idealWidth: 320)
                    detail
                        .frame(minWidth: 260, maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .onAppear(perform: reload)
        .onChange(of: selectedID) { loadDetail() }
    }

    private var list: some View {
        List(metas, selection: $selectedID) { meta in
            row(meta)
        }
    }

    private func row(_ meta: MeetingNoteMeta) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(meta.title)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(meta.date.formatted(date: .abbreviated, time: .shortened))
                    Text(durationText(meta.durationSeconds))
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            if !meta.hasSummary {
                Text("summary pending")
                    .font(.caption2)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(.orange.opacity(0.2), in: Capsule())
                    .foregroundStyle(.orange)
                if inFlight.contains(meta.id) {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Button("Retry") { retry(meta) }
                        .buttonStyle(.borderless)
                        .controlSize(.small)
                }
            }
        }
        .contextMenu {
            Button("Open") { NSWorkspace.shared.open(meta.url) }
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([meta.url]) }
        }
    }

    private var detail: some View {
        Group {
            if let content = detailContent {
                ScrollView {
                    Text(content)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                }
            } else {
                Text("Select a meeting to read it.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "person.2.wave.2")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("No meetings yet.")
                .foregroundStyle(.secondary)
            Button("Start a Meeting") {
                NotificationCenter.default.post(name: Notification.Name("radiooperator.startMeeting"), object: nil)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    private func reload() {
        metas = NotesStore.shared.listMeetings()
        inFlight = Set(metas
            .filter { ClaudeService.shared.isSummaryInFlight(notePath: $0.url.path) }
            .map(\.id))
        loadDetail()
    }

    private func loadDetail() {
        guard let selectedID, let meta = metas.first(where: { $0.id == selectedID }) else {
            detailContent = nil
            return
        }
        detailContent = NotesStore.shared.read(noteURL: meta.url)
    }

    /// Kicks off a retry, then polls the store until the summary lands (or
    /// gives up) so the pending badge and detail pane refresh themselves.
    private func retry(_ meta: MeetingNoteMeta) {
        MeetingController.shared.retrySummary(noteURL: meta.url)
        inFlight.insert(meta.id)
        Task {
            for _ in 0..<60 {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                reload()
                if !ClaudeService.shared.isSummaryInFlight(notePath: meta.url.path) { break }
            }
            reload()
        }
    }

    private func durationText(_ seconds: Int) -> String {
        if seconds < 60 { return "<1 min" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes) min" }
        return String(format: "%d:%02d", minutes / 60, minutes % 60)
    }
}

private func copyToPasteboard(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
}
