import SwiftUI
import AppKit
import AVFoundation

// MARK: - Meetings (list + in-pane detail)

/// Library / Meetings — recorded calls as rich knowledge cards, with the
/// structured meeting detail (notes lead, transcript one glance away) opened
/// in-pane. Note reads stay off the MainActor; parsing is MeetingNoteParser.
struct MeetingsView: View {
    @EnvironmentObject var settings: SettingsStore
    @EnvironmentObject var health: PermissionHealth
    @ObservedObject private var app = AppState.shared
    @ObservedObject private var hub = HubState.shared

    @State private var metas: [MeetingNoteMeta] = []
    @State private var contentByID: [String: String] = [:]
    @State private var parsedByID: [String: MeetingNoteParser.Note] = [:]
    @State private var inFlight: Set<String> = []
    @State private var query = ""
    @State private var selectedID: String?
    @State private var loaded = false

    var body: some View {
        Group {
            if let meta = metas.first(where: { $0.id == selectedID }) {
                MeetingDetailView(
                    meta: meta,
                    onBack: { selectedID = nil; reload() },
                    onNoteMutated: { reload() })
                .id(meta.id)
            } else {
                list
            }
        }
        .onAppear { reload() }
        .onChange(of: hub.pendingMeetingID) { _, _ in consumeDeepLink() }
    }

    // MARK: List

    private var list: some View {
        VStack(spacing: 0) {
            toolbar
            filterBar
            if !loaded {
                Color.clear
            } else if metas.isEmpty {
                emptyState
            } else if filtered.isEmpty {
                noMatches
            } else {
                cards
            }
        }
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            RecordMeetingButton(active: app.meetingActive)
            Spacer()
            StatusPill(health: health)
        }
        .padding(.horizontal, 22).padding(.top, 16).padding(.bottom, 12)
    }

    private var filterBar: some View {
        HStack(spacing: 10) {
            MeetingSearchField(query: $query)
            Spacer()
            RefreshButton { reload() }
        }
        .padding(.horizontal, 22).padding(.bottom, 14)
    }

    private var cards: some View {
        ScrollView {
            LazyVStack(spacing: 14) {
                ForEach(filtered) { meta in
                    MeetingCard(
                        meta: meta,
                        parsed: parsedByID[meta.id],
                        state: summaryState(meta),
                        onOpen: { selectedID = meta.id },
                        onRetry: { retry(meta) },
                        onDelete: { reload() })
                }
            }
            .frame(maxWidth: 860)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 22).padding(.top, 6).padding(.bottom, 22)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "person.2")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(Theme.textMeta)
            Text("No meetings yet.")
                .font(Theme.display(14))
                .foregroundStyle(Theme.textDim)
            RecordMeetingButton(active: app.meetingActive)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    private var noMatches: some View {
        Text("No meetings match \u{201C}\(query)\u{201D}")
            .font(Theme.display(13))
            .foregroundStyle(Theme.textFaint)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Data

    /// Title or full-text match against the cached note contents.
    private var filtered: [MeetingNoteMeta] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return metas }
        return metas.filter { meta in
            meta.title.localizedCaseInsensitiveContains(q)
                || (contentByID[meta.id]?.localizedCaseInsensitiveContains(q) ?? false)
        }
    }

    private func summaryState(_ meta: MeetingNoteMeta) -> MeetingSummaryState {
        if meta.hasSummary { return .ready }
        if inFlight.contains(meta.id) { return .processing }
        return .pending
    }

    /// Reload off the MainActor: listing decrypts nothing, but it reads and
    /// parses every note file, so it must not run synchronously on the main
    /// thread. Results publish back on the main actor.
    private func reload() {
        let folder = NotesStore.shared.meetingsFolder
        Task {
            let bundle = await Task.detached(priority: .userInitiated) {
                () -> ([MeetingNoteMeta], [String: String], [String: MeetingNoteParser.Note]) in
                let metas = NotesStore.listMeetings(in: folder)
                var contents: [String: String] = [:]
                var parsed: [String: MeetingNoteParser.Note] = [:]
                for meta in metas {
                    guard let c = try? String(contentsOf: meta.url, encoding: .utf8) else { continue }
                    contents[meta.id] = c
                    parsed[meta.id] = MeetingNoteParser.parse(c)
                }
                return (metas, contents, parsed)
            }.value
            metas = bundle.0
            contentByID = bundle.1
            parsedByID = bundle.2
            inFlight = Set(metas
                .filter { ClaudeService.shared.isSummaryInFlight(notePath: $0.url.path) }
                .map(\.id))
            loaded = true
            // A successful summary retitles and renames the note file: follow
            // a stale selection to its successor via the shared timestamp stem.
            if let sel = selectedID, !metas.contains(where: { $0.id == sel }) {
                let stamp = String(sel.prefix(16))
                selectedID = metas.first(where: { $0.id.hasPrefix(stamp) })?.id
            }
            consumeDeepLink()
        }
    }

    /// Open a meeting requested from elsewhere (Ask citations) once its meta
    /// exists, then clear the request.
    private func consumeDeepLink() {
        guard let id = hub.pendingMeetingID,
              metas.contains(where: { $0.id == id }) else { return }
        selectedID = id
        hub.pendingMeetingID = nil
    }

    /// Kicks off a retry, then polls until the summary lands (or gives up) so
    /// the PROCESSING badge resolves itself.
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
}

// MARK: - Shared list chrome

private enum MeetingSummaryState { case ready, processing, pending }

private struct RecordMeetingButton: View {
    let active: Bool

    var body: some View {
        Button {
            NotificationCenter.default.post(
                name: Notification.Name("radiooperator.startMeeting"), object: nil)
        } label: {
            HStack(spacing: 8) {
                Circle().fill(Theme.greenInk).frame(width: 8, height: 8)
                Text(active ? "Recording…" : "Record meeting")
            }
        }
        .buttonStyle(GreenButtonStyle())
        .disabled(active)
        .opacity(active ? 0.55 : 1)
    }
}

private struct MeetingSearchField: View {
    @Binding var query: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12))
                .foregroundStyle(Theme.textMeta)
            TextField("Search meetings…", text: $query)
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
}

private struct RefreshButton: View {
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "arrow.clockwise")
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
        .help("Refresh")
    }
}

// MARK: - Meeting card

private struct MeetingCard: View {
    let meta: MeetingNoteMeta
    let parsed: MeetingNoteParser.Note?
    let state: MeetingSummaryState
    let onOpen: () -> Void
    let onRetry: () -> Void
    let onDelete: () -> Void

    @State private var hovering = false
    @State private var confirmDelete = false

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            header
            if let excerpt = parsed?.excerpt, !excerpt.isEmpty {
                Text(excerpt)
                    .font(Theme.display(13.5))
                    .foregroundStyle(Theme.textDim2)
                    .lineSpacing(4)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            footer
        }
        .padding(.vertical, 18).padding(.horizontal, 20)
        .roCard(fill: Theme.surface3, radius: 14,
                border: hovering ? Theme.green.opacity(0.35) : Theme.hairline(0.08))
        .offset(y: hovering ? -2 : 0)
        .animation(.easeOut(duration: 0.15), value: hovering)
        .contentShape(RoundedRectangle(cornerRadius: 14))
        .onHover { hovering = $0 }
        .onTapGesture(perform: onOpen)
        .contextMenu {
            Button("Open") { NSWorkspace.shared.open(meta.url) }
            Button("Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([meta.url])
            }
            Divider()
            Button("Delete Meeting", role: .destructive) { confirmDelete = true }
        }
        .confirmationDialog("Delete this meeting?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete note + recording", role: .destructive) {
                NotesStore.shared.deleteMeetingNote(meta.url)
                onDelete()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Removes the note and its audio from this Mac. This can't be undone.")
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text(meta.title)
                    .font(Theme.display(16, .semibold))
                    .foregroundStyle(Theme.textMax)
                    .lineLimit(1)
                Text("\(meetingDayLabel(meta.date)) · \(meetingTimeLabel(meta.date)) · \(meetingDurationLabel(meta.durationSeconds))")
                    .font(Theme.mono(11))
                    .tracking(0.66)
                    .foregroundStyle(Theme.textMeta)
            }
            Spacer(minLength: 0)
            badge
        }
    }

    @ViewBuilder private var badge: some View {
        switch state {
        case .ready:
            StateChip(text: "NOTES READY", color: Theme.green,
                      fill: Theme.green.opacity(0.1), dot: true)
        case .processing:
            StateChip(text: "PROCESSING", color: Theme.amber,
                      fill: Theme.amber.opacity(0.1), dot: true, pulsingDot: true)
        case .pending:
            HStack(spacing: 8) {
                StateChip(text: "SUMMARY PENDING", color: Theme.amber)
                Button("Retry", action: onRetry)
                    .buttonStyle(.plain)
                    .font(Theme.display(11.5, .medium))
                    .foregroundStyle(Theme.amber)
                    .underline()
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            HStack(spacing: 8) {
                HStack(spacing: -8) {
                    avatar("Y", fill: Theme.rgb(0x2A2E33), ink: Theme.textBody)
                    if parsed?.hasThem == true {
                        avatar("T", fill: Theme.rgb(0x3B5C8A), ink: .white)
                    }
                }
                Text(parsed?.hasThem == true ? "You · Them" : "You")
                    .font(Theme.display(12.5))
                    .foregroundStyle(Theme.textFaint)
            }
            Spacer()
            if !countsLabel.isEmpty {
                Text(countsLabel)
                    .font(Theme.mono(9.5, .medium))
                    .tracking(0.4)
                    .foregroundStyle(Theme.textMeta)
            }
            // Visible delete affordance (also on right-click). Revealed on hover.
            Button { confirmDelete = true } label: {
                Image(systemName: "trash")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(hovering ? Theme.alertRed : Theme.textFaint)
                    .frame(width: 24, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(hovering ? 1 : 0)
            .help("Delete note + recording")
            .accessibilityLabel("Delete meeting")
        }
        .padding(.top, 13)
        .overlay(alignment: .top) {
            Rectangle().fill(Theme.hairline(0.06)).frame(height: 1)
        }
    }

    private var countsLabel: String {
        guard let parsed else { return "" }
        var parts: [String] = []
        let d = parsed.decisions.count
        let a = parsed.actionItems.count
        if d > 0 { parts.append("\(d) DECISION\(d == 1 ? "" : "S")") }
        if a > 0 { parts.append("\(a) ACTION\(a == 1 ? "" : "S")") }
        return parts.joined(separator: " · ")
    }

    private func avatar(_ initial: String, fill: Color, ink: Color) -> some View {
        Text(initial)
            .font(Theme.display(10, .semibold))
            .foregroundStyle(ink)
            .frame(width: 24, height: 24)
            .background(fill, in: Circle())
            .overlay(Circle().strokeBorder(Theme.surface1, lineWidth: 1.5))
    }
}

// MARK: - Meeting detail

private struct MeetingDetailView: View {
    let meta: MeetingNoteMeta
    let onBack: () -> Void
    /// The note file changed identity (summary retitle renames it) — the
    /// parent re-lists and re-selects.
    let onNoteMutated: () -> Void

    @State private var content = ""
    @State private var parsed = MeetingNoteParser.Note()
    @State private var contentLoaded = false
    @State private var inFlight = false
    @State private var pollTask: Task<Void, Never>?
    @StateObject private var audio = MeetingAudioModel()

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(Theme.hairline(0.06)).frame(height: 1)
            panes
        }
        .onAppear {
            loadContent()
            loadAudioIfRetained()
            inFlight = ClaudeService.shared.isSummaryInFlight(notePath: meta.url.path)
            if inFlight { startPolling() }
        }
        .onDisappear {
            pollTask?.cancel()
            pollTask = nil
            audio.teardown()
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 0) {
            BackToMeetingsButton(action: onBack)
            HStack(alignment: .top, spacing: 24) {
                VStack(alignment: .leading, spacing: 9) {
                    Text(meta.title)
                        .font(Theme.display(22, .semibold))
                        .tracking(-0.22)
                        .foregroundStyle(Theme.textMax)
                    metaLine
                }
                Spacer(minLength: 0)
                actions
            }
            .padding(.top, 12)
            if audio.ready {
                MeetingAudioPlayerRow(audio: audio)
                    .padding(.top, 16)
            }
        }
        .padding(24)
    }

    private var metaLine: some View {
        HStack(spacing: 10) {
            metaText("\(meetingDayLabel(meta.date)) · \(meetingTimeLabel(meta.date))")
            metaDivider
            metaText(meetingDurationLabel(meta.durationSeconds))
            if !parsed.turns.isEmpty {
                metaDivider
                metaText(parsed.speakerCount == 1 ? "1 SPEAKER" : "\(parsed.speakerCount) SPEAKERS")
            }
            if parsed.micOnly {
                StateChip(text: "MIC ONLY", color: Theme.amber)
            }
        }
    }

    private func metaText(_ s: String) -> some View {
        Text(s)
            .font(Theme.mono(11))
            .tracking(0.55)
            .foregroundStyle(Theme.textMeta)
    }

    private var metaDivider: some View {
        Text("|")
            .font(Theme.mono(11))
            .foregroundStyle(Theme.textGhost)
    }

    private var actions: some View {
        HStack(spacing: 8) {
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(content, forType: .string)
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "doc.on.doc").font(.system(size: 11.5))
                    Text("Copy markdown")
                }
            }
            .buttonStyle(DimButtonStyle())
            .disabled(content.isEmpty)

            Button {
                NSWorkspace.shared.open(meta.url)
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "arrow.up.right.square").font(.system(size: 11.5))
                    Text("Open note")
                }
            }
            .buttonStyle(GreenButtonStyle())

            Menu {
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([meta.url])
                }
                if parsed.pending && !inFlight {
                    Button("Retry summary") { retry() }
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.textFaint)
                    .frame(width: 34, height: 34)
                    .background(Theme.lift(0.04),
                                in: RoundedRectangle(cornerRadius: 9))
                    .overlay(RoundedRectangle(cornerRadius: 9)
                        .strokeBorder(Theme.hairline(0.1), lineWidth: 1))
                    .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
        }
    }

    // MARK: Two-pane body

    private var panes: some View {
        GeometryReader { geo in
            HStack(spacing: 0) {
                knowledgePane
                    .frame(width: max(320, geo.size.width * 0.574))
                Rectangle().fill(Theme.hairline(0.06)).frame(width: 1)
                transcriptRail
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private var knowledgePane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                if parsed.pending {
                    summaryPendingSection
                } else if !parsed.summaryText.isEmpty {
                    section("SUMMARY") {
                        InlineMarkdownText(text: parsed.summaryText, size: 14.5,
                                           color: Theme.textBody, lineSpacing: 6)
                    }
                }
                if !parsed.decisions.isEmpty { decisionsSection }
                if !parsed.actionItems.isEmpty { actionsSection }
                if !parsed.followUps.isEmpty { followUpsSection }
                if let notes = parsed.myNotes {
                    section("MY NOTES") {
                        Text(notes)
                            .font(Theme.display(13.5))
                            .foregroundStyle(Theme.textDim2)
                            .lineSpacing(4)
                            .textSelection(.enabled)
                    }
                }
            }
            .padding(.vertical, 22).padding(.horizontal, 24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func section(_ title: String, @ViewBuilder body: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 11) {
            Eyebrow(text: title)
            body()
        }
    }

    private var summaryPendingSection: some View {
        section("SUMMARY") {
            HStack(spacing: 10) {
                if inFlight {
                    StateChip(text: "PROCESSING", color: Theme.amber,
                              fill: Theme.amber.opacity(0.1), dot: true, pulsingDot: true)
                    Text("Summarizing with Claude…")
                        .font(Theme.display(13))
                        .foregroundStyle(Theme.textDim)
                } else {
                    StateChip(text: "SUMMARY PENDING", color: Theme.amber)
                    Button("Retry") { retry() }
                        .buttonStyle(DimButtonStyle())
                }
            }
        }
    }

    private var decisionsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Eyebrow(text: "DECISIONS")
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(parsed.decisions.enumerated()), id: \.offset) { _, decision in
                    HStack(alignment: .firstTextBaseline, spacing: 11) {
                        Image(systemName: "checkmark")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Theme.green)
                        InlineMarkdownText(text: decision, size: 14,
                                           color: Theme.textBright, lineSpacing: 3.5)
                    }
                }
            }
        }
    }

    private var actionsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Eyebrow(text: "ACTION ITEMS")
            VStack(alignment: .leading, spacing: 9) {
                ForEach(Array(parsed.actionItems.enumerated()), id: \.offset) { _, item in
                    actionRow(item)
                }
            }
        }
    }

    private func actionRow(_ item: MeetingNoteParser.ActionItem) -> some View {
        HStack(alignment: .top, spacing: 11) {
            Button { toggleAction(item) } label: {
                ZStack {
                    if item.done {
                        RoundedRectangle(cornerRadius: 5).fill(Theme.green)
                        Image(systemName: "checkmark")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(Theme.greenInk)
                    } else {
                        RoundedRectangle(cornerRadius: 5)
                            .strokeBorder(Theme.lift(0.28), lineWidth: 1.5)
                    }
                }
                .frame(width: 16, height: 16)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.top, 1)

            Text(item.text)
                .font(Theme.display(14))
                .foregroundStyle(item.done ? Theme.textFaint : Theme.textBright)
                .strikethrough(item.done, color: Theme.textFaint)
                .lineSpacing(3)
                .frame(maxWidth: .infinity, alignment: .leading)

            if let tag = item.meta {
                Text(tag.uppercased())
                    .font(Theme.mono(10, .medium))
                    .foregroundStyle(Theme.textFaint)
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(Theme.lift(0.05),
                                in: RoundedRectangle(cornerRadius: 5))
            }
        }
        .padding(.vertical, 9).padding(.horizontal, 11)
        .background(item.done ? Theme.green.opacity(0.045) : Theme.lift(0.025),
                    in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9)
            .strokeBorder(item.done ? Theme.green.opacity(0.14) : Theme.hairline(0.05),
                          lineWidth: 1))
    }

    private var followUpsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Eyebrow(text: "FOLLOW-UPS")
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(parsed.followUps.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 11) {
                        Image(systemName: "circle")
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(Theme.textFaint2)
                        InlineMarkdownText(text: item, size: 14,
                                           color: Theme.textBody, lineSpacing: 3.5)
                    }
                }
            }
        }
    }

    // MARK: Transcript rail

    private var transcriptRail: some View {
        VStack(spacing: 0) {
            HStack {
                Eyebrow(text: "TRANSCRIPT")
                Spacer()
                HStack(spacing: 12) {
                    legendItem(color: Theme.green, label: "You")
                    if parsed.hasThem {
                        legendItem(color: Theme.speakerRemote, label: "Them")
                    }
                }
            }
            .padding(.horizontal, 20).padding(.top, 16).padding(.bottom, 12)

            if parsed.turns.isEmpty {
                Text(contentLoaded ? "No speech captured." : "")
                    .font(Theme.display(12.5))
                    .foregroundStyle(Theme.textMeta)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 3) {
                        ForEach(Array(parsed.turns.enumerated()), id: \.offset) { _, turn in
                            TranscriptTurnRow(turn: turn, seekable: audio.ready) {
                                seekToTurn(turn)
                            }
                        }
                    }
                    .padding(.horizontal, 20).padding(.top, 4).padding(.bottom, 20)
                }
            }
        }
        .background(Theme.bgRail)
    }

    private func legendItem(color: Color, label: String) -> some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 7, height: 7)
            Text(label)
                .font(Theme.display(11))
                .foregroundStyle(Theme.textFaint)
        }
    }

    private func seekToTurn(_ turn: MeetingNoteParser.Turn) {
        guard audio.ready,
              let offset = MeetingNoteParser.timeOffset(clock: turn.time, noteStart: meta.date)
        else { return }
        audio.seek(to: offset)
    }

    // MARK: Data

    /// Note reads go off the MainActor; results publish back on it.
    private func loadContent() {
        let url = meta.url
        Task {
            let c = await Task.detached(priority: .userInitiated) {
                try? String(contentsOf: url, encoding: .utf8)
            }.value
            guard let c else { onNoteMutated(); return }
            content = c
            parsed = MeetingNoteParser.parse(c)
            contentLoaded = true
        }
    }

    /// Retained audio is opt-in and often absent: only mount the player when
    /// the note's stem has at least one track on disk.
    private func loadAudioIfRetained() {
        let stem = meta.url.deletingPathExtension().lastPathComponent
        let folder = NotesStore.shared.audioFolder
        let urls = ["me", "them"]
            .map { folder.appendingPathComponent("\(stem) - \($0).m4a") }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !urls.isEmpty else { return }
        Task { await audio.load(urls: urls, seed: stem) }
    }

    private func toggleAction(_ item: MeetingNoteParser.ActionItem) {
        guard let current = NotesStore.shared.read(noteURL: meta.url),
              let updated = MeetingNoteParser.togglingCheckbox(
                in: current, sourceLine: item.sourceLine)
        else { return }
        try? updated.write(to: meta.url, atomically: true, encoding: .utf8)
        content = updated
        parsed = MeetingNoteParser.parse(updated)
    }

    private func retry() {
        MeetingController.shared.retrySummary(noteURL: meta.url)
        inFlight = true
        startPolling()
    }

    /// Polls until the in-flight summary lands so PROCESSING resolves to
    /// content live. A successful summary may rename the file (retitle) —
    /// then the parent takes over via onNoteMutated.
    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task {
            for _ in 0..<90 {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                if Task.isCancelled { return }
                if !ClaudeService.shared.isSummaryInFlight(notePath: meta.url.path) { break }
            }
            if Task.isCancelled { return }
            inFlight = false
            if FileManager.default.fileExists(atPath: meta.url.path) {
                loadContent()
            } else {
                onNoteMutated()
            }
        }
    }
}

// MARK: - Detail chrome

private struct BackToMeetingsButton: View {
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 10, weight: .semibold))
                Text("Meetings")
                    .font(Theme.display(12.5, .medium))
            }
            .foregroundStyle(hovering ? Theme.textHi : Theme.textFaint)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// Inline-markdown text (bold key facts brighten to textHi).
private struct InlineMarkdownText: View {
    let text: String
    let size: CGFloat
    let color: Color
    let lineSpacing: CGFloat

    var body: some View {
        Text(attributed)
            .font(Theme.display(size))
            .foregroundStyle(color)
            .lineSpacing(lineSpacing)
            .textSelection(.enabled)
    }

    private var attributed: AttributedString {
        var a = (try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
        let boldRanges = a.runs.compactMap { run in
            run.inlinePresentationIntent?.contains(.stronglyEmphasized) == true
                ? run.range : nil
        }
        for range in boldRanges {
            a[range].foregroundColor = Theme.textHi
        }
        return a
    }
}

private struct TranscriptTurnRow: View {
    let turn: MeetingNoteParser.Turn
    let seekable: Bool
    let onSeek: () -> Void

    private var color: Color { turn.speaker == .me ? Theme.green : Theme.speakerRemote }
    private var name: String { turn.speaker == .me ? "You" : "Them" }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 9) {
                Text(name)
                    .font(Theme.display(12, .semibold))
                    .foregroundStyle(color)
                if seekable {
                    Button(action: onSeek) {
                        Text(turn.time)
                            .font(Theme.mono(10.5))
                            .foregroundStyle(Theme.textMono)
                            .underline()
                    }
                    .buttonStyle(.plain)
                    .help("Jump the player here")
                } else {
                    Text(turn.time)
                        .font(Theme.mono(10.5))
                        .foregroundStyle(Theme.textMono)
                }
            }
            Text(turn.text)
                .font(Theme.display(13.5))
                .foregroundStyle(Theme.textMuted)
                .lineSpacing(4.5)
                .textSelection(.enabled)
        }
        .padding(.vertical, 10).padding(.horizontal, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            UnevenRoundedRectangle(cornerRadii: .init(
                topLeading: 0, bottomLeading: 0, bottomTrailing: 8, topTrailing: 8))
                .fill(color.opacity(0.04)))
        .overlay(alignment: .leading) {
            Rectangle().fill(color).frame(width: 2)
        }
    }
}

// MARK: - Audio player (retained two-track audio)

/// Local playback of retained meeting audio. Both tracks (me/them) are mixed
/// into one AVMutableComposition so YOU and THEM play together; a single
/// surviving file plays directly.
@MainActor
private final class MeetingAudioModel: ObservableObject {
    @Published var ready = false
    @Published var playing = false
    @Published var currentTime: Double = 0
    @Published var duration: Double = 0
    private(set) var seed = ""

    private var player: AVPlayer?
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?

    func load(urls: [URL], seed: String) async {
        self.seed = seed
        var item: AVPlayerItem?
        var total: Double = 0
        if urls.count == 1 {
            let asset = AVURLAsset(url: urls[0])
            guard let d = try? await asset.load(.duration) else { return }
            total = d.seconds
            item = AVPlayerItem(asset: asset)
        } else {
            let comp = AVMutableComposition()
            for url in urls {
                let asset = AVURLAsset(url: url)
                guard let tracks = try? await asset.loadTracks(withMediaType: .audio),
                      let src = tracks.first,
                      let d = try? await asset.load(.duration),
                      let dst = comp.addMutableTrack(
                        withMediaType: .audio,
                        preferredTrackID: kCMPersistentTrackID_Invalid)
                else { continue }
                try? dst.insertTimeRange(CMTimeRange(start: .zero, duration: d),
                                         of: src, at: .zero)
                total = max(total, d.seconds)
            }
            guard !comp.tracks.isEmpty else { return }
            item = AVPlayerItem(asset: comp)
        }
        guard let item, total.isFinite, total > 0 else { return }

        let p = AVPlayer(playerItem: item)
        timeObserver = p.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.25, preferredTimescale: 600),
            queue: .main) { [weak self] t in
            Task { @MainActor in self?.currentTime = t.seconds }
        }
        endObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification,
            object: item, queue: .main) { [weak self] _ in
            Task { @MainActor in
                self?.playing = false
                self?.player?.seek(to: .zero)
                self?.currentTime = 0
            }
        }
        player = p
        duration = total
        ready = true
    }

    func toggle() {
        guard let player else { return }
        if playing { player.pause() } else { player.play() }
        playing.toggle()
    }

    func seek(fraction: Double) {
        seek(to: fraction * duration)
    }

    func seek(to seconds: Double) {
        guard let player, duration > 0 else { return }
        let s = min(max(0, seconds), duration)
        player.seek(to: CMTime(seconds: s, preferredTimescale: 600))
        currentTime = s
    }

    func teardown() {
        player?.pause()
        if let timeObserver, let player { player.removeTimeObserver(timeObserver) }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        timeObserver = nil
        endObserver = nil
        player = nil
        playing = false
        ready = false
    }
}

private struct MeetingAudioPlayerRow: View {
    @ObservedObject var audio: MeetingAudioModel

    var body: some View {
        HStack(spacing: 14) {
            Button { audio.toggle() } label: {
                Image(systemName: audio.playing ? "pause.fill" : "play.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.surface1)
                    .frame(width: 30, height: 30)
                    .background(Theme.textHi, in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)

            Text(playerClock(audio.currentTime))
                .font(Theme.mono(11))
                .foregroundStyle(Theme.textFaint)

            WaveformScrubber(
                seed: audio.seed,
                progress: audio.duration > 0 ? audio.currentTime / audio.duration : 0,
                onSeek: { audio.seek(fraction: $0) })

            Text(playerClock(audio.duration))
                .font(Theme.mono(11))
                .foregroundStyle(Theme.textMono)

            HStack(spacing: 5) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.green)
                Text("ON-DEVICE")
                    .font(Theme.mono(10, .medium))
                    .tracking(0.8)
                    .foregroundStyle(Theme.textMeta)
            }
            .padding(.leading, 8)
            .overlay(alignment: .leading) {
                Rectangle().fill(Theme.hairline(0.08)).frame(width: 1)
            }
        }
        .padding(.vertical, 9).padding(.horizontal, 14)
        .background(Theme.lift(0.025), in: RoundedRectangle(cornerRadius: 11))
        .overlay(RoundedRectangle(cornerRadius: 11)
            .strokeBorder(Theme.hairline(0.06), lineWidth: 1))
    }

    private func playerClock(_ seconds: Double) -> String {
        let s = max(0, Int(seconds.rounded()))
        if s >= 3600 {
            return String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
        }
        return String(format: "%02d:%02d", s / 60, s % 60)
    }
}

/// Deterministic waveform scrubber: bar heights are pseudo-random but seeded
/// from the audio filename, so the same note always draws the same wave.
/// Played bars go green; click or drag seeks.
private struct WaveformScrubber: View {
    let seed: String
    let progress: Double
    let onSeek: (Double) -> Void

    var body: some View {
        GeometryReader { geo in
            let count = max(1, Int(geo.size.width / 4))
            HStack(spacing: 2) {
                ForEach(0..<count, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 1)
                        .fill(Double(i) / Double(count) < progress
                              ? Theme.green : Theme.lift(0.16))
                        .frame(width: 2,
                               height: geo.size.height * (0.3 + 0.6 * unitRandom(i)))
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .leading)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { v in
                        onSeek(min(max(0, v.location.x / max(1, geo.size.width)), 1))
                    })
        }
        .frame(height: 22)
    }

    /// SplitMix64 over an FNV-1a seed of the filename: stable in 0..<1.
    private func unitRandom(_ i: Int) -> Double {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for b in seed.utf8 { h = (h ^ UInt64(b)) &* 0x0000_0100_0000_01B3 }
        var z = h &+ (UInt64(i) &+ 1) &* 0x9E37_79B9_7F4A_7C15
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        z ^= z >> 31
        return Double(z % 1000) / 999.0
    }
}

// MARK: - Shared formatting

/// Uppercase relative day for mono meta lines ("TODAY", "YESTERDAY", "JUL 3").
private func meetingDayLabel(_ date: Date) -> String {
    let cal = Calendar.current
    if cal.isDateInToday(date) { return "TODAY" }
    if cal.isDateInYesterday(date) { return "YESTERDAY" }
    return date.formatted(date: .abbreviated, time: .omitted).uppercased()
}

private func meetingTimeLabel(_ date: Date) -> String {
    date.formatted(date: .omitted, time: .shortened).uppercased()
}

private func meetingDurationLabel(_ seconds: Int) -> String {
    if seconds < 60 { return "<1 MIN" }
    let minutes = seconds / 60
    if minutes >= 60 { return "\(minutes / 60) HR \(minutes % 60) MIN" }
    return "\(minutes) MIN"
}
