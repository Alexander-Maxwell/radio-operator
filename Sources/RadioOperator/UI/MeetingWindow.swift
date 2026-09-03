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
            hairline
            transcript
            if state.meetingActive || !controller.userNotes.isEmpty {
                hairline
                notesPane
            }
            hairline
            footer
        }
        .frame(minWidth: 480, minHeight: 420)
        .background(Theme.surface1)
        .environment(\.colorScheme, .dark)
    }

    private var hairline: some View {
        Rectangle().fill(Theme.hairline(0.07)).frame(height: 1)
    }

    private var header: some View {
        HStack(spacing: 9) {
            if state.meetingActive {
                GlowDot(color: Theme.recRed, size: 9, pulsing: true)
                Text("Recording")
                    .font(Theme.display(14, .semibold))
                    .foregroundStyle(Theme.textMax)
                Text(controller.elapsedText)
                    .font(Theme.mono(12.5))
                    .foregroundStyle(Theme.textFaint)
                if state.meetingDegradedNoTap {
                    StateChip(text: "MIC ONLY", color: Theme.amber)
                }
                if state.meetingRetainingAudio {
                    Image(systemName: "recordingtape")
                        .font(.system(size: 12))
                        .help("Audio retained locally")
                        .foregroundStyle(Theme.textFaint)
                }
            } else {
                Text("Meeting")
                    .font(Theme.display(14, .semibold))
                    .foregroundStyle(Theme.textMax)
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
    }

    private func bannerView(_ text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11))
                .foregroundStyle(Theme.amber)
            Text(text)
                .font(Theme.display(12.5))
                .foregroundStyle(Theme.textBody)
            Spacer()
            Button {
                controller.banner = nil
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Theme.textFaint)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Theme.amber.opacity(0.1))
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
                            .font(Theme.display(13))
                            .foregroundStyle(Theme.textDim)
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
                .padding(14)
            }
            .background(Theme.bgRail)
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

    /// Speaker turn: 2px speaker-colored left border, faint tint, square
    /// left / rounded right corners.
    private func utteranceRow(_ u: Utterance) -> some View {
        let color = u.speaker == .me ? Theme.speakerMe : Theme.speakerRemote
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 7) {
                Text(u.speaker.rawValue)
                    .font(Theme.display(12, .semibold))
                    .foregroundStyle(color)
                Text(u.start, style: .time)
                    .font(Theme.mono(10.5))
                    .foregroundStyle(Theme.textMono)
            }
            Text(u.text)
                .font(Theme.display(13.5))
                .foregroundStyle(Theme.textMuted)
                .lineSpacing(3)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(0.06),
                    in: UnevenRoundedRectangle(cornerRadii: .init(
                        topLeading: 0, bottomLeading: 0,
                        bottomTrailing: 8, topTrailing: 8)))
        .overlay(alignment: .leading) {
            Rectangle().fill(color).frame(width: 2)
        }
    }

    private func ghostRow(speaker: Speaker, text: String) -> some View {
        let color = speaker == .me ? Theme.speakerMe : Theme.speakerRemote
        return HStack(alignment: .firstTextBaseline, spacing: 7) {
            Text(speaker.rawValue)
                .font(Theme.display(12, .semibold))
                .foregroundStyle(color.opacity(0.7))
            Text(text)
                .font(Theme.display(13))
                .italic()
                .foregroundStyle(Theme.textDim2)
        }
        .padding(.horizontal, 12)
    }

    /// Jot-and-enhance: rough notes typed here are persisted with the note
    /// and steer the Claude summary (emphasis, not transcript).
    private var notesPane: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Eyebrow(text: "MY NOTES", size: 10, tracking: 1.6)
                Text("jotted points steer the summary")
                    .font(Theme.display(11))
                    .foregroundStyle(Theme.textMeta)
            }
            TextEditor(text: $controller.userNotes)
                .font(Theme.display(13))
                .foregroundStyle(Theme.textBody)
                .frame(minHeight: 56, maxHeight: 110)
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(Theme.lift(0.03),
                            in: RoundedRectangle(cornerRadius: 9))
                .overlay(RoundedRectangle(cornerRadius: 9)
                    .strokeBorder(Theme.hairline(0.07), lineWidth: 1))
                .disabled(!state.meetingActive)
            if !controller.liveAnswers.isEmpty {
                Eyebrow(text: "LIVE ANSWERS", size: 10, tracking: 1.6)
                    .padding(.top, 4)
                ScrollView {
                    Text(controller.liveAnswers)
                        .font(Theme.display(12))
                        .foregroundStyle(Theme.textBody)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(6)
                }
                .frame(maxHeight: 110)
                .background(Theme.lift(0.03), in: RoundedRectangle(cornerRadius: 9))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var footer: some View {
        HStack(spacing: 8) {
            switch controller.summaryPhase {
            case .none:
                if state.meetingActive {
                    Spacer()
                    Button {
                        MeetingController.shared.stop()
                    } label: {
                        HStack(spacing: 7) {
                            Image(systemName: "stop.fill")
                                .font(.system(size: 10, weight: .bold))
                            Text("Stop Meeting")
                        }
                    }
                    .buttonStyle(RecButtonStyle())
                    .keyboardShortcut(.escape, modifiers: [])
                } else {
                    Text("Start a meeting from the menu bar icon.")
                        .font(Theme.display(12.5))
                        .foregroundStyle(Theme.textDim)
                    Spacer()
                }
            case .transcriptSaved:
                statusLabel("checkmark.circle.fill", Theme.green, "Transcript saved")
                Spacer()
            case .summarizing(let startedAt):
                ProgressView().controlSize(.small)
                SummarizingLabel(startedAt: startedAt)
                Spacer()
            case .ready(let noteURL):
                statusLabel("sparkles", Theme.green, "Summary ready")
                Spacer()
                Button("Open Note") {
                    NSWorkspace.shared.open(noteURL)
                }
                .buttonStyle(GreenButtonStyle())
            case .failed(let message, let noteURL):
                statusLabel("exclamationmark.triangle.fill", Theme.amber, message)
                    .lineLimit(1)
                Spacer()
                Button("Open Transcript") { NSWorkspace.shared.open(noteURL) }
                    .buttonStyle(DimButtonStyle())
                Button("Retry Summary") {
                    MeetingController.shared.retrySummary(noteURL: noteURL)
                }
                .buttonStyle(DimButtonStyle())
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
    }

    private func statusLabel(_ symbol: String, _ color: Color, _ text: String) -> some View {
        HStack(spacing: 7) {
            Image(systemName: symbol)
                .font(.system(size: 12))
                .foregroundStyle(color)
            Text(text)
                .font(Theme.display(12.5))
                .foregroundStyle(Theme.textBody)
        }
    }
}

private struct SummarizingLabel: View {
    let startedAt: Date
    @State private var now = Date()
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        Text("Summarizing with Claude… \(Int(now.timeIntervalSince(startedAt)))s")
            .font(Theme.display(12.5))
            .foregroundStyle(Theme.textFaint)
            .onReceive(timer) { now = $0 }
    }
}
