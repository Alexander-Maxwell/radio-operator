import SwiftUI
import AppKit

// MARK: - Dictations (Console)

/// Library / Dictations — the day's captured voice notes as a fast, scannable
/// log. Rows lead with the transcript; bundle IDs are humanized into app
/// icons + names; state chips label real concepts (CLEANED / RAW / NOT
/// PASTED). HistoryStore decrypts rows, so every read runs off the MainActor.
struct DictationsView: View {
    @EnvironmentObject var settings: SettingsStore
    @EnvironmentObject var health: PermissionHealth

    @State private var records: [DictationRecord] = []
    @State private var query = ""
    @State private var appFilter: String?
    @State private var timeFilter: TimeFilter = .any
    @State private var expanded: Set<Int64> = []
    @State private var lastExpanded: Int64?
    @State private var selectMode = false
    @State private var selectedIDs: Set<Int64> = []
    @State private var confirmBulkDelete = false
    @State private var searchTask: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            filterBar
            content
        }
        .onAppear(perform: reload)
        .onChange(of: query) { _, _ in reloadDebounced() }
        // Cmd+C: selected rows in bulk mode, else the last-expanded row.
        .onCopyCommand { copyCommandItems() }
        .confirmationDialog("Delete \(selectedIDs.count) dictation\(selectedIDs.count == 1 ? "" : "s")?",
                            isPresented: $confirmBulkDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                delete(ids: Array(selectedIDs))
                selectMode = false
                selectedIDs = []
            }
        } message: {
            Text("Removes them from this Mac. This can't be undone.")
        }
        .safeAreaInset(edge: .bottom) {
            if selectMode { bulkBar }
        }
    }

    // MARK: Toolbar

    private var toolbar: some View {
        HStack {
            if settings.data.holdHotkey != .off {
                hotkeyHint
            }
            Spacer()
            StatusPill(health: health)
        }
        .padding(.horizontal, 22).padding(.vertical, 16)
    }

    /// Dashed hint chip showing the real dictation hotkey.
    private var hotkeyHint: some View {
        HStack(spacing: 8) {
            Keycap(text: hotkeyLabel)
            Text("hold to dictate")
                .font(Theme.display(12))
                .foregroundStyle(Theme.textFaint)
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .overlay(RoundedRectangle(cornerRadius: 9)
            .strokeBorder(Theme.lift(0.14),
                          style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
    }

    private var hotkeyLabel: String {
        settings.data.holdHotkey.displayName
            .replacingOccurrences(of: "Hold ", with: "")
            .replacingOccurrences(of: " (Globe)", with: "")
    }

    // MARK: Filter bar

    private var filterBar: some View {
        HStack(spacing: 10) {
            searchField
            FilterChipMenu(label: appFilterLabel) {
                Button("All apps") { appFilter = nil }
                if !appOptions.isEmpty { Divider() }
                ForEach(appOptions, id: \.id) { option in
                    Button(option.name) { appFilter = option.id }
                }
            }
            FilterChipMenu(label: timeFilter.label) {
                ForEach(TimeFilter.allCases, id: \.self) { filter in
                    Button(filter.label) { timeFilter = filter }
                }
            }
            Spacer()
            BorderedIconButton(systemName: "arrow.clockwise", help: "Refresh") { reload() }
            selectToggle
        }
        .padding(.horizontal, 22).padding(.top, 2).padding(.bottom, 14)
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.textMeta)
            TextField("Search dictations…", text: $query)
                .textFieldStyle(.plain)
                .font(Theme.display(13))
                .foregroundStyle(Theme.textHi)
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textMeta)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
        .background(Theme.lift(0.04), in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9)
            .strokeBorder(Theme.hairline(0.07), lineWidth: 1))
        .frame(width: 280)
    }

    private var appFilterLabel: String {
        guard let appFilter else { return "All apps" }
        return AppIconCache.info(for: appFilter).name
    }

    /// Distinct apps present in the loaded records, by display name.
    private var appOptions: [(id: String, name: String)] {
        var seen = Set<String>()
        var out: [(id: String, name: String)] = []
        for record in records {
            guard let bundleID = record.appBundleID, seen.insert(bundleID).inserted else { continue }
            out.append((bundleID, AppIconCache.info(for: bundleID).name))
        }
        return out.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private var selectToggle: some View {
        Button {
            selectMode.toggle()
            if !selectMode { selectedIDs = [] }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "checkmark.square")
                    .font(.system(size: 11.5, weight: .medium))
                Text("Select")
                    .font(Theme.display(12.5))
            }
            .foregroundStyle(selectMode ? Theme.textMax : Theme.sidebarIdle)
            .padding(.horizontal, 11).padding(.vertical, 7)
            .background(Theme.lift(selectMode ? 0.1 : 0.03),
                        in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Theme.hairline(selectMode ? 0.14 : 0.07), lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Select multiple dictations")
    }

    // MARK: Content

    @ViewBuilder private var content: some View {
        let visible = filteredRecords
        if records.isEmpty && trimmedQuery.isEmpty {
            emptyState
        } else if visible.isEmpty {
            noMatches
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(dayGroups(visible), id: \.day) { group in
                        dayHeader(group)
                        VStack(spacing: 0) {
                            ForEach(group.items) { record in
                                row(record)
                            }
                        }
                        .padding(.horizontal, 14).padding(.top, 4).padding(.bottom, 8)
                    }
                }
                .padding(.bottom, 12)
            }
        }
    }

    private func dayHeader(_ group: DayGroup) -> some View {
        HStack(spacing: 10) {
            Text(group.title)
                .font(Theme.mono(11, .medium))
                .tracking(1.8)
                .foregroundStyle(Theme.textFaint)
            Text("· \(group.items.count)")
                .font(Theme.mono(11))
                .foregroundStyle(Theme.textMono)
            Rectangle().fill(Theme.hairline(0.05)).frame(height: 1)
        }
        .padding(.horizontal, 22).padding(.top, 6).padding(.bottom, 4)
    }

    private func row(_ record: DictationRecord) -> some View {
        DictationRowView(
            record: record,
            expanded: expanded.contains(record.id),
            selectMode: selectMode,
            selected: selectedIDs.contains(record.id),
            onTap: {
                if selectMode {
                    toggleSelection(record.id)
                } else if expanded.contains(record.id) {
                    expanded.remove(record.id)
                    if lastExpanded == record.id { lastExpanded = nil }
                } else {
                    expanded.insert(record.id)
                    lastExpanded = record.id
                }
            },
            onToggleSelect: { toggleSelection(record.id) },
            onCopy: { copyToPasteboard($0) },
            onDelete: { delete(ids: [record.id]) })
    }

    private func toggleSelection(_ id: Int64) {
        if selectedIDs.contains(id) { selectedIDs.remove(id) } else { selectedIDs.insert(id) }
    }

    // MARK: Bulk action bar

    private var bulkBar: some View {
        HStack(spacing: 8) {
            Text("\(selectedIDs.count) selected")
                .font(Theme.display(12.5))
                .foregroundStyle(Theme.textFaint)
            Spacer()
            Button("Copy \(selectedIDs.count)") { copySelected() }
                .buttonStyle(DimButtonStyle())
                .disabled(selectedIDs.isEmpty)
            Button("Delete \(selectedIDs.count)") { confirmBulkDelete = true }
                .buttonStyle(.plain)
                .font(Theme.display(12.5, .medium))
                .foregroundStyle(Theme.alertRed)
                .padding(.horizontal, 12).padding(.vertical, 6.5)
                .background(Theme.alertRed.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Theme.alertRed.opacity(0.3), lineWidth: 1))
                .disabled(selectedIDs.isEmpty)
            Button("Cancel") {
                selectMode = false
                selectedIDs = []
            }
            .buttonStyle(DimButtonStyle())
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(Theme.surfacePop, in: RoundedRectangle(cornerRadius: 11))
        .overlay(RoundedRectangle(cornerRadius: 11)
            .strokeBorder(Theme.hairline(0.1), lineWidth: 1))
        .shadow(color: .black.opacity(0.5), radius: 18, y: 8)
        .padding(.horizontal, 22).padding(.bottom, 14)
    }

    private func copySelected() {
        let texts = filteredRecords
            .filter { selectedIDs.contains($0.id) }
            .map(\.cleanedText)
        guard !texts.isEmpty else { return }
        copyToPasteboard(texts.joined(separator: "\n\n"))
    }

    private func copyCommandItems() -> [NSItemProvider] {
        if selectMode {
            let texts = filteredRecords
                .filter { selectedIDs.contains($0.id) }
                .map(\.cleanedText)
            guard !texts.isEmpty else { return [] }
            return [NSItemProvider(object: texts.joined(separator: "\n\n") as NSString)]
        }
        guard let lastExpanded,
              let record = records.first(where: { $0.id == lastExpanded }) else { return [] }
        return [NSItemProvider(object: record.cleanedText as NSString)]
    }

    // MARK: Empty states

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "mic")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(Theme.textMono)
            Text(settings.data.holdHotkey == .off
                 ? "No dictations yet. Set a dictation hotkey in Settings → Dictation, then hold it anywhere and speak."
                 : "No dictations yet. Hold \(hotkeyLabel) anywhere and speak — it lands at your cursor and here.")
                .font(Theme.display(13.5))
                .foregroundStyle(Theme.textDim)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
                .frame(maxWidth: 400)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    private var noMatches: some View {
        VStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 22, weight: .light))
                .foregroundStyle(Theme.textMono)
            Text(trimmedQuery.isEmpty
                 ? "No dictations match your filters."
                 : "No dictations match \u{201C}\(trimmedQuery)\u{201D}")
                .font(Theme.display(13))
                .foregroundStyle(Theme.textDim)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    // MARK: Filtering & grouping

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// App + time filters run in memory; the text query runs at the store.
    private var filteredRecords: [DictationRecord] {
        records.filter { record in
            (appFilter == nil || record.appBundleID == appFilter)
                && timeFilter.contains(record.timestamp)
        }
    }

    private struct DayGroup {
        let day: Date
        let title: String
        let items: [DictationRecord]
    }

    private func dayGroups(_ rows: [DictationRecord]) -> [DayGroup] {
        let cal = Calendar.current
        let byDay = Dictionary(grouping: rows) { cal.startOfDay(for: $0.timestamp) }
        return byDay.keys.sorted(by: >).map { day in
            DayGroup(day: day,
                     title: Self.dayTitle(day),
                     items: (byDay[day] ?? []).sorted { $0.timestamp > $1.timestamp })
        }
    }

    private static let dayFormatter: DateFormatter = {
        let df = DateFormatter()
        df.dateFormat = "EEEE, MMM d"
        return df
    }()

    private static func dayTitle(_ day: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(day) { return "TODAY" }
        if cal.isDateInYesterday(day) { return "YESTERDAY" }
        return dayFormatter.string(from: day).uppercased()
    }

    // MARK: Data (all HistoryStore reads run off the MainActor)

    /// Reload off the MainActor. The first touch of HistoryStore.shared can run
    /// the Keychain read + one-time encryption migration + VACUUM, so even the
    /// non-search path must not run synchronously on the main thread. Results
    /// publish back on the main actor.
    private func reload() {
        searchTask?.cancel()
        let q = trimmedQuery
        searchTask = Task {
            let rows = await Task.detached(priority: .userInitiated) {
                q.isEmpty ? HistoryStore.shared.recent() : HistoryStore.shared.search(query: q)
            }.value
            if Task.isCancelled { return }
            records = rows
        }
    }

    /// Debounced, off-main reload for typing. search() AES-decrypts rows until
    /// it fills its cap, so on a large history it must not block the main
    /// thread per keystroke. Coalesce mid-word keystrokes, run the scan on a
    /// background task (HistoryStore is its own serialized queue;
    /// DictationRecord is Sendable), then publish back on the main actor.
    private func reloadDebounced() {
        searchTask?.cancel()
        let q = trimmedQuery
        if q.isEmpty {
            // Clearing should feel instant (no debounce), but the recent()
            // decrypt still must not run on the MainActor.
            searchTask = Task {
                let rows = await Task.detached(priority: .userInitiated) {
                    HistoryStore.shared.recent()
                }.value
                if !Task.isCancelled { records = rows }
            }
            return
        }
        searchTask = Task {
            try? await Task.sleep(nanoseconds: 180_000_000)
            if Task.isCancelled { return }
            let hits = await Task.detached(priority: .userInitiated) {
                HistoryStore.shared.search(query: q)
            }.value
            if Task.isCancelled { return }
            records = hits
        }
    }

    private func delete(ids: [Int64]) {
        searchTask?.cancel()
        let q = trimmedQuery
        searchTask = Task {
            let rows = await Task.detached(priority: .userInitiated) {
                for id in ids { HistoryStore.shared.delete(id: id) }
                return q.isEmpty ? HistoryStore.shared.recent() : HistoryStore.shared.search(query: q)
            }.value
            if Task.isCancelled { return }
            records = rows
            selectedIDs.subtract(ids)
            expanded.subtract(ids)
        }
    }
}

// MARK: - Row

private struct DictationRowView: View {
    let record: DictationRecord
    let expanded: Bool
    let selectMode: Bool
    let selected: Bool
    let onTap: () -> Void
    let onToggleSelect: () -> Void
    let onCopy: (String) -> Void
    let onDelete: () -> Void

    var body: some View {
        HoverRow(radius: 11) { hovering in
            HStack(alignment: .top, spacing: 13) {
                if selectMode { checkbox }
                AppIconTile(bundleID: record.appBundleID)
                    .padding(.top, 1)
                rowContent
                actions(hovering)
            }
            .padding(.horizontal, 18).padding(.vertical, 17)
        }
        .contextMenu {
            Button("Copy") { onCopy(record.cleanedText) }
            if record.rawText != record.cleanedText {
                Button("Copy raw transcript") { onCopy(record.rawText) }
            }
            Divider()
            Button("Delete", role: .destructive, action: onDelete)
        }
    }

    private var checkbox: some View {
        Button(action: onToggleSelect) {
            ZStack {
                RoundedRectangle(cornerRadius: 4)
                    .fill(selected ? Theme.green : .clear)
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(selected ? Theme.green : Theme.lift(0.28),
                                  lineWidth: 1.5)
                if selected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Theme.greenInk)
                }
            }
            .frame(width: 16, height: 16)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.top, 8)
    }

    private var rowContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text(record.cleanedText)
                    .font(Theme.display(15))
                    .foregroundStyle(Theme.textHi)
                    .lineSpacing(3)
                    .lineLimit(expanded ? nil : 2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                metadataLine
            }
            .contentShape(Rectangle())
            .onTapGesture(perform: onTap)
            if expanded && record.rawText != record.cleanedText {
                rawBlock
            }
        }
    }

    private var metadataLine: some View {
        HStack(spacing: 9) {
            Text(record.timestamp.formatted(date: .omitted, time: .shortened))
                .font(Theme.mono(12))
            dot
            Text(AppIconCache.info(for: record.appBundleID).name)
                .font(Theme.display(12))
                .foregroundStyle(Theme.textDim2)
            dot
            Text(durationText)
                .font(Theme.mono(12))
            StateChip(text: record.cleanedText == record.rawText ? "RAW" : "CLEANED",
                      color: record.cleanedText == record.rawText ? Theme.amber : Theme.textMono)
            if !record.pasteOK {
                StateChip(text: "NOT PASTED", color: Theme.amber)
            }
        }
        .foregroundStyle(Theme.textMeta)
    }

    private var dot: some View {
        Text("·").font(Theme.display(12)).foregroundStyle(Theme.textMeta)
    }

    private var durationText: String {
        let seconds = max(0, record.durationMs / 1000)
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    private var rawBlock: some View {
        VStack(alignment: .leading, spacing: 5) {
            Eyebrow(text: "RAW TRANSCRIPT", size: 9, tracking: 1.4, color: Theme.textMono)
            Text(record.rawText)
                .font(Theme.mono(12))
                .foregroundStyle(Theme.textFaint)
                .lineSpacing(3)
                .textSelection(.enabled)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.lift(0.025), in: RoundedRectangle(cornerRadius: 8))
        .padding(.top, 8)
    }

    private func actions(_ hovering: Bool) -> some View {
        HStack(spacing: 2) {
            HoverIconButton(systemName: "doc.on.doc", help: "Copy") {
                onCopy(record.cleanedText)
            }
            Menu {
                Button("Copy raw transcript") { onCopy(record.rawText) }
                Divider()
                Button("Delete", role: .destructive, action: onDelete)
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(Theme.textFaint)
                    .frame(width: 30, height: 30)
                    .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .opacity(hovering ? 1 : 0.5)
    }
}

// MARK: - App identity (bundle ID → icon + display name)

private struct AppInfo {
    let name: String
    let icon: NSImage?
}

/// Resolves a bundle ID to its app's real icon and display name via
/// NSWorkspace, memoized per session. Falls back to a derived name when the
/// app isn't installed. Main-thread only (SwiftUI body).
@MainActor
private enum AppIconCache {
    private static var cache: [String: AppInfo] = [:]

    static func info(for bundleID: String?) -> AppInfo {
        guard let bundleID, !bundleID.isEmpty else {
            return AppInfo(name: "Unknown app", icon: nil)
        }
        if let hit = cache[bundleID] { return hit }
        var name = fallbackName(bundleID)
        var icon: NSImage?
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            var display = FileManager.default.displayName(atPath: url.path)
            if display.hasSuffix(".app") { display = String(display.dropLast(4)) }
            if !display.isEmpty { name = display }
            icon = NSWorkspace.shared.icon(forFile: url.path)
        }
        let info = AppInfo(name: name, icon: icon)
        cache[bundleID] = info
        return info
    }

    /// Last bundle-ID component, capitalized ("com.example.superapp" → "Superapp").
    private static func fallbackName(_ bundleID: String) -> String {
        let last = bundleID.split(separator: ".").last.map(String.init) ?? bundleID
        guard let first = last.first else { return bundleID }
        return first.uppercased() + last.dropFirst()
    }
}

/// 30×30 app tile: the real app icon when resolvable, a tinted first-letter
/// tile when not, a generic waveform tile when the source app is unknown.
private struct AppIconTile: View {
    let bundleID: String?

    var body: some View {
        Group {
            if let bundleID, !bundleID.isEmpty {
                let info = AppIconCache.info(for: bundleID)
                if let icon = info.icon {
                    Image(nsImage: icon)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: 30, height: 30)
                } else {
                    letterTile(info.name, tint: Self.tint(for: bundleID))
                }
            } else {
                genericTile
            }
        }
    }

    private func letterTile(_ name: String, tint: Color) -> some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(tint.opacity(0.22))
            .frame(width: 30, height: 30)
            .overlay(
                Text(String(name.prefix(1)).uppercased())
                    .font(Theme.display(13, .semibold))
                    .foregroundStyle(tint))
    }

    private var genericTile: some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(Theme.lift(0.06))
            .frame(width: 30, height: 30)
            .overlay(
                Image(systemName: "waveform")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.textFaint))
    }

    /// Stable per-app tint (never the live-signal green).
    private static func tint(for bundleID: String) -> Color {
        let palette: [Color] = [Theme.speakerRemote, Theme.entityPerson, Theme.amber, Theme.textDim]
        var hash: UInt = 5381
        for byte in bundleID.utf8 { hash = (hash << 5) &+ hash &+ UInt(byte) }
        return palette[Int(hash % UInt(palette.count))]
    }
}

// MARK: - Filter chrome

/// Bordered dropdown chip ("All apps", "Any time").
private struct FilterChipMenu<Items: View>: View {
    let label: String
    @ViewBuilder var items: Items

    var body: some View {
        Menu {
            items
        } label: {
            HStack(spacing: 6) {
                Text(label)
                    .font(Theme.display(12.5))
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
            }
            .foregroundStyle(Theme.sidebarIdle)
            .padding(.horizontal, 11).padding(.vertical, 7)
            .background(Theme.lift(0.03), in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9)
                .strokeBorder(Theme.hairline(0.07), lineWidth: 1))
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
    }
}

/// 32×32 bordered icon button (filter-bar refresh).
private struct BorderedIconButton: View {
    let systemName: String
    var help: String = ""
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(hovering ? Theme.textBody : Theme.textFaint)
                .frame(width: 32, height: 32)
                .background(Theme.lift(hovering ? 0.07 : 0.03),
                            in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Theme.hairline(0.07), lineWidth: 1))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
    }
}

// MARK: - Time filter

private enum TimeFilter: CaseIterable {
    case any, today, yesterday, week

    var label: String {
        switch self {
        case .any: return "Any time"
        case .today: return "Today"
        case .yesterday: return "Yesterday"
        case .week: return "This week"
        }
    }

    func contains(_ date: Date) -> Bool {
        let cal = Calendar.current
        switch self {
        case .any: return true
        case .today: return cal.isDateInToday(date)
        case .yesterday: return cal.isDateInYesterday(date)
        case .week: return cal.isDate(date, equalTo: Date(), toGranularity: .weekOfYear)
        }
    }
}

// MARK: - Helpers

private func copyToPasteboard(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
}
