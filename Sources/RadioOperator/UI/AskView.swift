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
/// flight at a time; answers cite note filenames as tappable chips.
struct AskView: View {
    private typealias Message = AskSession.Message

    @ObservedObject private var session = AskSession.shared
    @State private var input = ""

    private var messages: [Message] { session.messages }
    private var isPending: Bool { messages.contains { $0.isPending } }

    var body: some View {
        VStack(spacing: 0) {
            scopeBar
            Divider()
            if messages.isEmpty {
                emptyState
            } else {
                transcript
            }
            Divider()
            inputBar
        }
        .frame(minWidth: 460, minHeight: 400)
    }

    private var scopeBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.caption).foregroundStyle(.secondary)
            Text("Search").font(.caption).foregroundStyle(.secondary)
            Picker("", selection: $session.scope) {
                ForEach(ClaudeService.AskScope.allCases, id: \.self) { Text($0.displayName).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden().frame(maxWidth: 260)
            Spacer()
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(messages) { message in
                        row(message)
                            .id(message.id)
                    }
                }
                .padding(12)
            }
            .onChange(of: messages.count) {
                if let last = messages.last {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
        }
    }

    @ViewBuilder
    private func row(_ message: Message) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(message.role == .user ? "You" : "Radio Operator")
                .font(.caption2)
                .foregroundStyle(.secondary)
            if message.isPending {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    TimelineView(.periodic(from: message.startedAt, by: 1)) { context in
                        let s = max(0, Int(context.date.timeIntervalSince(message.startedAt)))
                        Text("Searching your notes… (\(s)s)")
                            .foregroundStyle(.secondary)
                    }
                    Button("Stop", action: stop)
                        .controlSize(.small)
                }
            } else {
                Text(.init(message.text))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let retry = message.retryQuestion {
                    Button("Retry") { submit(retry) }
                        .buttonStyle(.link)
                        .disabled(isPending)
                }
                if !message.citations.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(message.citations, id: \.self) { name in
                            Button {
                                NSWorkspace.shared.open(
                                    NotesStore.shared.meetingsFolder.appendingPathComponent(name))
                            } label: {
                                Label(name, systemImage: "doc.text")
                                    .font(.caption)
                                    .lineLimit(1)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            message.role == .user ? AnyShapeStyle(.quaternary.opacity(0.5)) : AnyShapeStyle(.clear),
            in: RoundedRectangle(cornerRadius: 8))
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "text.magnifyingglass")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("Ask about anything you've dictated or any meeting you've captured.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 340)
            VStack(spacing: 6) {
                exampleButton("What did we decide in my last meeting?")
                exampleButton("List all my open action items")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    private func exampleButton(_ question: String) -> some View {
        Button(question) { input = question }
    }

    private var inputBar: some View {
        HStack(spacing: 8) {
            if !messages.isEmpty {
                Button {
                    stop()
                    session.messages = []
                } label: {
                    Image(systemName: "square.and.pencil")
                }
                .help("New conversation")
                .disabled(isPending)
            }
            TextField("Ask about your notes…", text: $input)
                .textFieldStyle(.roundedBorder)
                .onSubmit(send)
                .disabled(isPending)
            Button("Send", action: send)
                .disabled(isPending || input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(10)
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
}
