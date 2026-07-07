import SwiftUI
import AppKit

/// Holds the Ask conversation outside the view so closing the window doesn't
/// erase it, and so prior turns can feed the next question as context.
@MainActor
final class AskSession: ObservableObject {
    static let shared = AskSession()

    struct Message: Identifiable {
        enum Role { case user, assistant }
        let id = UUID()
        var role: Role
        var text: String
        var isPending = false
        var startedAt = Date()
        var retryQuestion: String? = nil
        var citations: [String] = []
    }

    @Published var messages: [Message] = []
    /// Which slice of the corpus new questions search. Persists with the session.
    @Published var scope: ClaudeService.AskScope = .all
    var askTask: Task<Void, Never>?

    /// Completed (question, answer) pairs for multi-turn context.
    func historyPairs() -> [(String, String)] {
        var pairs: [(String, String)] = []
        var lastQuestion: String?
        for m in messages {
            switch m.role {
            case .user:
                lastQuestion = m.text
            case .assistant:
                if !m.isPending, m.retryQuestion == nil, !m.text.isEmpty, let q = lastQuestion {
                    pairs.append((q, m.text))
                    lastQuestion = nil
                }
            }
        }
        return pairs
    }
}

/// Chat over the local notes corpus via ClaudeService.ask. One question in
/// flight at a time; answers cite note filenames, rendered as source cards
/// that deep-link back to the capture.
struct AskView: View {
    private typealias Message = AskSession.Message

    @ObservedObject private var session = AskSession.shared
    @State private var input = ""
    @FocusState private var fieldFocused: Bool
    /// Meeting metas keyed by filename, for resolving citations to titles.
    @State private var meetingsByID: [String: MeetingNoteMeta] = [:]

    private static let suggestions = [
        "What did I commit to this week?",
        "Action items from my meetings",
        "What's still waiting on someone else?",
    ]

    private var messages: [Message] { session.messages }
    private var isPending: Bool { messages.contains { $0.isPending } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                queryBar
                controlRow
            }
            .padding(.horizontal, 28).padding(.top, 26)
            .frame(maxWidth: 896, alignment: .leading)
            if messages.isEmpty {
                emptyState
            } else {
                transcript
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear(perform: reloadMeetings)
        .onChange(of: messages.count) { reloadMeetings() }
    }

    // MARK: - Query bar

    private var queryBar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 13) {
                Image(systemName: "sparkles")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(Theme.green)
                TextField("", text: $input,
                          prompt: Text("Ask about your notes…").foregroundStyle(Theme.textMeta))
                    .textFieldStyle(.plain)
                    .font(Theme.display(16))
                    .foregroundStyle(Theme.textHi)
                    .focused($fieldFocused)
                    .onSubmit(send)
                    .disabled(isPending)
                AskSubmitButton(disabled: isPending ||
                    input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                                action: send)
            }
            .padding(.horizontal, 18).padding(.vertical, 12)
            .background(Theme.surface3, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14)
                .strokeBorder(fieldFocused ? Theme.green.opacity(0.3) : Theme.hairline(0.12),
                              lineWidth: 1))
            .overlay {
                if fieldFocused {
                    RoundedRectangle(cornerRadius: 16)
                        .inset(by: -2)
                        .stroke(Theme.green.opacity(0.1), lineWidth: 3)
                }
            }
            if !messages.isEmpty {
                HoverIconButton(systemName: "square.and.pencil", help: "New conversation") {
                    stop()
                    session.messages = []
                }
                .disabled(isPending)
            }
        }
    }

    /// The always-visible scope selector, right-aligned under the query bar.
    private var controlRow: some View {
        HStack(alignment: .center, spacing: 9) {
            Spacer(minLength: 12)
            Eyebrow(text: "SEARCH", size: 10, tracking: 1.2, color: Theme.textMono)
            RoSegmented(
                options: ClaudeService.AskScope.allCases.map { ($0, $0.displayName) },
                selection: $session.scope)
                .fixedSize()
        }
    }

    private var suggestionChips: some View {
        AskChipFlow(hSpacing: 8, vSpacing: 8) {
            Eyebrow(text: "TRY", size: 10, tracking: 1.2, color: Theme.textMono)
                .padding(.vertical, 6)
            ForEach(Self.suggestions, id: \.self) { question in
                AskSuggestionChip(text: question) {
                    input = question
                    send()
                }
            }
        }
    }

    // MARK: - Transcript

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 22) {
                    ForEach(messages) { message in
                        turn(message)
                            .id(message.id)
                    }
                }
                .frame(maxWidth: 840, alignment: .leading)
                .padding(.horizontal, 28).padding(.vertical, 22)
            }
            .onAppear {
                if let last = messages.last { proxy.scrollTo(last.id, anchor: .bottom) }
            }
            .onChange(of: messages.count) {
                if let last = messages.last {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
        }
    }

    @ViewBuilder
    private func turn(_ message: Message) -> some View {
        if message.role == .user {
            userTurn(message)
        } else if message.isPending {
            pendingTurn(message)
        } else {
            answerTurn(message)
        }
    }

    private func userTurn(_ message: Message) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Eyebrow(text: "YOU ASKED")
            Text(message.text)
                .font(Theme.display(14, .medium))
                .foregroundStyle(Theme.textBright)
                .textSelection(.enabled)
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.lift(0.03), in: RoundedRectangle(cornerRadius: 10))
    }

    private func pendingTurn(_ message: Message) -> some View {
        HStack(spacing: 10) {
            GlowDot(color: Theme.green, size: 7, pulsing: true)
            TimelineView(.periodic(from: message.startedAt, by: 1)) { context in
                let s = max(0, Int(context.date.timeIntervalSince(message.startedAt)))
                Text("SEARCHING YOUR NOTES… (\(s)s)")
                    .font(Theme.mono(11, .medium))
                    .tracking(1)
                    .foregroundStyle(Theme.textFaint)
            }
            Button("Stop", action: stop)
                .buttonStyle(DimButtonStyle())
        }
        .padding(.vertical, 4)
    }

    private func answerTurn(_ message: Message) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Eyebrow(text: "ANSWER")
                Spacer()
                if !message.citations.isEmpty {
                    StateChip(
                        text: "FROM YOUR NOTES · \(message.citations.count) SOURCE\(message.citations.count == 1 ? "" : "S")",
                        color: Theme.green, fill: Theme.green.opacity(0.07))
                }
            }
            Text(.init(message.text))
                .font(Theme.display(15))
                .foregroundStyle(Theme.textBright)
                .lineSpacing(5)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let retry = message.retryQuestion {
                Button("Retry") { submit(retry) }
                    .buttonStyle(DimButtonStyle())
                    .disabled(isPending)
            }
            if !message.citations.isEmpty {
                sources(message.citations)
            }
        }
    }

    private func sources(_ citations: [String]) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Eyebrow(text: "SOURCES")
                .padding(.top, 8)
            ForEach(Array(citations.enumerated()), id: \.element) { index, name in
                sourceCard(number: index + 1, citation: name)
            }
        }
    }

    /// A citation is a note filename; meetings resolve to their title and
    /// deep-link in-app, anything else opens as a dictation log file.
    @ViewBuilder
    private func sourceCard(number: Int, citation: String) -> some View {
        let filename = (citation as NSString).lastPathComponent
        if let meta = meetingsByID[filename] {
            AskSourceCard(
                number: number, icon: "person.2", title: meta.title,
                provenance: "MEETING · \(Self.dayLabel(meta.date)) \(Self.timeLabel(meta.date))"
            ) {
                HubState.shared.pendingMeetingID = meta.id
                HubState.shared.section = .meetings
            }
        } else {
            let stem = (filename as NSString).deletingPathExtension
            AskSourceCard(
                number: number, icon: "waveform", title: stem,
                provenance: Self.stemDate(stem).map { "DICTATION LOG · \($0)" } ?? "DICTATION LOG"
            ) {
                openCitation(filename)
            }
        }
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "sparkles")
                .font(.system(size: 28))
                .foregroundStyle(Theme.green)
            Text("Ask about anything you've dictated or any meeting you've captured.")
                .font(Theme.display(13))
                .foregroundStyle(Theme.textDim)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
            suggestionChips
                .padding(.top, 6)
                .frame(maxWidth: 720)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    // MARK: - Submission

    private func send() {
        let question = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !isPending else { return }
        input = ""
        submit(question)
    }

    private func submit(_ question: String) {
        // Prior completed turns become context BEFORE this question is added.
        let history = session.historyPairs()
        session.messages.append(Message(role: .user, text: question))
        // Empty corpus → answer instantly without spawning Claude.
        if NotesStore.shared.listMeetings().isEmpty && HistoryStore.shared.recent(limit: 1).isEmpty {
            session.messages.append(Message(
                role: .assistant,
                text: "Nothing to search yet — capture a meeting or a dictation first."))
            return
        }
        let pending = Message(role: .assistant, text: "", isPending: true)
        session.messages.append(pending)
        let pendingID = pending.id
        session.askTask = Task {
            do {
                let answer = try await ClaudeService.shared.ask(
                    question: question, history: history,
                    notesFolder: SettingsStore.shared.notesFolderURL,
                    scope: session.scope)
                guard !Task.isCancelled else { return }
                replace(pendingID, with: Message(
                    role: .assistant, text: answer, citations: Self.citations(in: answer)))
            } catch {
                guard !Task.isCancelled else { return }
                replace(pendingID, with: Message(
                    role: .assistant, text: error.localizedDescription, retryQuestion: question))
            }
        }
    }

    private func stop() {
        session.askTask?.cancel() // cancellation also terminates the CLI child
        session.askTask = nil
        guard let index = messages.firstIndex(where: { $0.isPending }) else { return }
        let lastQuestion = messages.last(where: { $0.role == .user })?.text
        session.messages[index] = Message(role: .assistant, text: "Stopped.", retryQuestion: lastQuestion)
    }

    private func replace(_ id: UUID, with message: Message) {
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return }
        session.messages[index] = message
    }

    /// Pulls unique [filename.md] citations, in order of first appearance.
    private static func citations(in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: "\\[([^\\[\\]]+\\.md)\\]") else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        var seen = Set<String>()
        var out: [String] = []
        for match in regex.matches(in: text, range: range) {
            guard let r = Range(match.range(at: 1), in: text) else { continue }
            let name = String(text[r])
            if seen.insert(name).inserted { out.append(name) }
        }
        return out
    }

    // MARK: - Citation resolution

    /// Meeting metas load off the MainActor: listing parses every note file.
    private func reloadMeetings() {
        let folder = NotesStore.shared.meetingsFolder
        Task {
            let map = await Task.detached(priority: .utility) {
                let metas = NotesStore.listMeetings(in: folder)
                return Dictionary(metas.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            }.value
            meetingsByID = map
        }
    }

    /// Non-meeting citations open on disk: dictation logs live in
    /// Dictations/, with the meetings folder as the legacy fallback.
    private func openCitation(_ filename: String) {
        let dictation = NotesStore.shared.dictationsFolder.appendingPathComponent(filename)
        if FileManager.default.fileExists(atPath: dictation.path) {
            NSWorkspace.shared.open(dictation)
        } else {
            NSWorkspace.shared.open(
                NotesStore.shared.meetingsFolder.appendingPathComponent(filename))
        }
    }

    // MARK: - Provenance formatting

    private static let monthDay: DateFormatter = {
        let df = DateFormatter()
        df.dateFormat = "MMM d"
        return df
    }()

    private static let clock: DateFormatter = {
        let df = DateFormatter()
        df.dateFormat = "h:mm a"
        return df
    }()

    private static let stemParser: DateFormatter = {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "yyyy-MM-dd"
        return df
    }()

    private static func dayLabel(_ date: Date) -> String {
        if Calendar.current.isDateInToday(date) { return "TODAY" }
        if Calendar.current.isDateInYesterday(date) { return "YESTERDAY" }
        return monthDay.string(from: date).uppercased()
    }

    private static func timeLabel(_ date: Date) -> String {
        clock.string(from: date).uppercased()
    }

    /// Dictation logs are named YYYY-MM-DD; render that as a day label.
    private static func stemDate(_ stem: String) -> String? {
        guard stem.count >= 10,
              let date = stemParser.date(from: String(stem.prefix(10))) else { return nil }
        return dayLabel(date)
    }
}

// MARK: - Pieces

/// Circular green submit affordance in the query bar.
private struct AskSubmitButton: View {
    let disabled: Bool
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "arrow.up")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.greenInk)
                .frame(width: 30, height: 30)
                .background(hovering && !disabled ? Theme.greenBtnHover : Theme.green,
                            in: Circle())
                .opacity(disabled ? 0.35 : 1)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .onHover { hovering = $0 }
    }
}

/// Tappable example-question chip.
private struct AskSuggestionChip: View {
    let text: String
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(text)
                .font(Theme.display(12.5))
                .foregroundStyle(hovering ? Theme.textHi : Theme.sidebarIdle)
                .padding(.horizontal, 11).padding(.vertical, 5)
                .background(Theme.lift(hovering ? 0.07 : 0.04),
                            in: RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7)
                    .strokeBorder(Theme.hairline(0.07), lineWidth: 1))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// Numbered, clickable citation card: green index circle, type icon + title,
/// mono provenance, ↗ affordance. Border tints green on hover.
private struct AskSourceCard: View {
    let number: Int
    let icon: String
    let title: String
    let provenance: String
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .center, spacing: 13) {
                Text("\(number)")
                    .font(Theme.mono(11, .semibold))
                    .foregroundStyle(Theme.green)
                    .frame(width: 22, height: 22)
                    .background(Theme.green.opacity(0.12), in: Circle())
                    .overlay(Circle().strokeBorder(Theme.green.opacity(0.3), lineWidth: 1))
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 7) {
                        Image(systemName: icon)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Theme.textFaint)
                        Text(title)
                            .font(Theme.display(13.5, .semibold))
                            .foregroundStyle(Theme.textHi)
                            .lineLimit(1)
                    }
                    Text(provenance)
                        .font(Theme.mono(10))
                        .tracking(0.5)
                        .foregroundStyle(Theme.textMono)
                }
                Spacer(minLength: 8)
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(hovering ? Theme.green : Theme.textMono)
            }
            .padding(.horizontal, 15).padding(.vertical, 13)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .roCard(fill: Theme.surface3, radius: 12,
                border: hovering ? Theme.green.opacity(0.3) : Theme.hairline(0.07))
        .onHover { hovering = $0 }
    }
}

/// Left-aligned wrapping row: the suggestion chips break onto new lines
/// instead of overflowing at narrow widths.
private struct AskChipFlow: Layout {
    var hSpacing: CGFloat = 8
    var vSpacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, width: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > maxWidth {
                x = 0
                y += rowHeight + vSpacing
                rowHeight = 0
            }
            x += size.width + hSpacing
            rowHeight = max(rowHeight, size.height)
            width = max(width, x - hSpacing)
        }
        return CGSize(width: width, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + vSpacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), anchor: .topLeading,
                          proposal: ProposedViewSize(size))
            x += size.width + hSpacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
