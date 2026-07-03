import SwiftUI
import AppKit

/// Live meeting window: elapsed time, banner (degraded/echo/stall states),
/// scrolling transcript with Me/Them attribution, volatile ghost lines, and
/// the post-stop status strip (saved → summarizing → ready/failed).
struct MeetingWindowView: View {
    @EnvironmentObject var state: AppState
    @ObservedObject var controller = MeetingController.shared

    var body: some View {
        VStack(spacing: 0) {
            header
            if let banner = controller.banner {
                bannerView(banner)
            }
            Divider()
            transcript
            if state.meetingActive || !controller.userNotes.isEmpty {
                Divider()
                notesPane
            }
            Divider()
            footer
        }
        .frame(minWidth: 480, minHeight: 420)
    }

    /// Jot-and-enhance: rough notes typed here are persisted with the note
    /// and steer the Claude summary (emphasis, not transcript).
    private var notesPane: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("My Notes — jotted points steer the summary")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextEditor(text: $controller.userNotes)
                .font(.body)
                .frame(minHeight: 56, maxHeight: 110)
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(Color.primary.opacity(0.04),
                            in: RoundedRectangle(cornerRadius: 6))
                .disabled(!state.meetingActive)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var header: some View {
        HStack {
            if state.meetingActive {
                Circle().fill(.red).frame(width: 9, height: 9)
                Text("Recording — \(controller.elapsedText)")
                    .font(.headline)
                if state.meetingDegradedNoTap {
                    Text("mic only")
                        .font(.caption)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(.orange.opacity(0.2), in: Capsule())
                }
                if state.meetingRetainingAudio {
                    Image(systemName: "recordingtape")
                        .help("Audio retained locally")
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("Meeting").font(.headline)
            }
            Spacer()
        }
        .padding(12)
    }

    private func bannerView(_ text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(text).font(.callout)
            Spacer()
            Button {
                controller.banner = nil
            } label: {
                Image(systemName: "xmark").font(.caption)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(.orange.opacity(0.12))
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if state.meetingUtterances.isEmpty
                        && state.meetingVolatileMe.isEmpty
                        && state.meetingVolatileThem.isEmpty {
                        Text(state.meetingActive
                             ? "Listening… speech appears here as it's transcribed."
                             : "No transcript.")
                            .foregroundStyle(.secondary)
                            .padding(.top, 24)
                            .frame(maxWidth: .infinity, alignment: .center)
                    }
                    ForEach(state.meetingUtterances) { u in
                        utteranceRow(u)
                    }
                    if !state.meetingVolatileThem.isEmpty {
                        ghostRow(speaker: .them, text: state.meetingVolatileThem)
                    }
                    if !state.meetingVolatileMe.isEmpty {
                        ghostRow(speaker: .me, text: state.meetingVolatileMe)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(12)
            }
            .onChange(of: state.meetingUtterances.count) {
                withAnimation { proxy.scrollTo("bottom") }
            }
            .onChange(of: state.meetingVolatileMe) {
                proxy.scrollTo("bottom")
            }
            .onChange(of: state.meetingVolatileThem) {
                proxy.scrollTo("bottom")
            }
        }
    }

    private func utteranceRow(_ u: Utterance) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(u.speaker == .me ? "Me" : "Them")
                    .font(.caption.bold())
                    .foregroundStyle(u.speaker == .me ? Palette.accent : Color.secondary)
                Text(u.start, style: .time)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Text(u.text)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(10)
        .background(
            (u.speaker == .me ? Palette.accent.opacity(0.08) : Color.primary.opacity(0.04)),
            in: RoundedRectangle(cornerRadius: 8))
    }

    private func ghostRow(speaker: Speaker, text: String) -> some View {
        HStack(spacing: 6) {
            Text(speaker == .me ? "Me" : "Them").font(.caption.bold())
            Text(text).italic()
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
    }

    @ViewBuilder
    private var footer: some View {
        HStack {
            switch controller.summaryPhase {
            case .none:
                if state.meetingActive {
                    Spacer()
                    Button(role: .destructive) {
                        MeetingController.shared.stop()
                    } label: {
                        Label("Stop Meeting", systemImage: "stop.circle.fill")
                    }
                    .keyboardShortcut(.escape, modifiers: [])
                } else {
                    Text("Start a meeting from the menu bar icon.")
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            case .transcriptSaved:
                Label("Transcript saved", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Spacer()
            case .summarizing(let startedAt):
                ProgressView().controlSize(.small)
                SummarizingLabel(startedAt: startedAt)
                Spacer()
            case .ready(let noteURL):
                Label("Summary ready", systemImage: "sparkles")
                    .foregroundStyle(.green)
                Spacer()
                Button("Open Note") {
                    NSWorkspace.shared.open(noteURL)
                }
            case .failed(let message, let noteURL):
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .lineLimit(1)
                Spacer()
                Button("Open Transcript") { NSWorkspace.shared.open(noteURL) }
                Button("Retry Summary") {
                    MeetingController.shared.retrySummary(noteURL: noteURL)
                }
            }
        }
        .padding(12)
    }
}

private struct SummarizingLabel: View {
    let startedAt: Date
    @State private var now = Date()
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        Text("Summarizing with Claude… \(Int(now.timeIntervalSince(startedAt)))s")
            .foregroundStyle(.secondary)
            .onReceive(timer) { now = $0 }
    }
}
