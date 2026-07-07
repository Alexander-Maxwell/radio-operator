import SwiftUI
import AppKit

// MARK: - Panel controller

/// Floating in-meeting HUD: a borderless, non-activating panel bottom-right
/// of the active screen that proves both capture tracks are landing, while
/// the full transcript window stays one click away. Draggable by background;
/// collapses to a REC pill. Shown/dismissed by MeetingController around the
/// capture lifecycle.
@MainActor
final class RecordingHUDController: ObservableObject {
    static let shared = RecordingHUDController()

    /// Collapsed ⇄ expanded. Survives across meetings within the app session.
    @Published var collapsed = false

    private var panel: NSPanel?

    private init() {}

    func show() {
        if panel == nil { panel = makePanel() }
        guard let panel else { return }
        // Fresh meeting: park at the default corner; the geometry callback
        // trues up the exact size on first layout, bottom-right anchored.
        let estimate = collapsed ? NSSize(width: 140, height: 36)
                                 : NSSize(width: 352, height: 286)
        if let screen = activeScreen() {
            let vis = screen.visibleFrame
            panel.setFrame(NSRect(x: vis.maxX - 24 - estimate.width,
                                  y: vis.minY + 24,
                                  width: estimate.width, height: estimate.height),
                           display: false)
        }
        panel.orderFrontRegardless()
    }

    func dismiss() {
        panel?.orderOut(nil)
    }

    /// Resizes the panel to the SwiftUI content's ideal size, keeping the
    /// bottom-right corner fixed so collapse/expand stays where the user
    /// dragged it.
    func contentSizeChanged(_ size: CGSize) {
        guard let panel, size.width > 1, size.height > 1 else { return }
        let frame = NSRect(x: panel.frame.maxX - size.width,
                           y: panel.frame.minY,
                           width: size.width, height: size.height)
        guard frame != panel.frame else { return }
        panel.setFrame(frame, display: true)
        panel.invalidateShadow()
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 352, height: 286),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false)
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.contentViewController = NSHostingController(
            rootView: RecordingHUDView()
                .environmentObject(AppState.shared)
                .environmentObject(self))
        return panel
    }

    private func activeScreen() -> NSScreen? {
        NSScreen.screens.first(where: { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) })
            ?? NSScreen.main ?? NSScreen.screens.first
    }
}

// MARK: - View

struct RecordingHUDView: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var hud: RecordingHUDController
    @ObservedObject var controller = MeetingController.shared

    /// Which volatile channel updated most recently (drives the caption).
    @State private var lastVolatileWasMe = false

    private let cardTint = Theme.surface2

    var body: some View {
        Group {
            if hud.collapsed { pill } else { card }
        }
        .fixedSize()
        .onGeometryChange(for: CGSize.self, of: { $0.size }) { size in
            hud.contentSizeChanged(size)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        .environment(\.colorScheme, .light)
        .onChange(of: state.meetingVolatileMe) { _, text in
            if !text.isEmpty { lastVolatileWasMe = true }
        }
        .onChange(of: state.meetingVolatileThem) { _, text in
            if !text.isEmpty { lastVolatileWasMe = false }
        }
    }

    // MARK: Expanded card

    private var card: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            meters
                .padding(.top, 15)
            captionStrip
                .padding(.top, 14)
            controls
                .padding(.top, 14)
            footer
                .padding(.top, 13)
        }
        .padding(.horizontal, 17)
        .padding(.vertical, 16)
        .frame(width: 352)
        .background {
            ZStack {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(.ultraThinMaterial)
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(cardTint.opacity(0.94))
            }
        }
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
            .strokeBorder(Theme.lift(0.13), lineWidth: 1))
    }

    private var header: some View {
        HStack(spacing: 9) {
            GlowDot(color: Theme.recRed, size: 10, pulsing: true)
            Text("Recording")
                .font(Theme.display(13, .semibold))
                .foregroundStyle(Theme.textMax)
            Text(controller.elapsedText)
                .font(Theme.mono(12))
                .foregroundStyle(Theme.textFaint)
            Spacer(minLength: 0)
            HoverIconButton(systemName: "minus.circle", help: "Collapse") {
                hud.collapsed = true
            }
        }
    }

    private var meters: some View {
        VStack(alignment: .leading, spacing: 9) {
            meterRow("YOU", Theme.green, level: state.meetingMeLevel)
            if state.meetingDegradedNoTap {
                HStack(spacing: 11) {
                    trackLabel("THEM", Theme.speakerRemote)
                    Text("mic only — system audio unavailable")
                        .font(Theme.display(11))
                        .foregroundStyle(Theme.amber)
                }
                .frame(height: 20)
            } else {
                meterRow("THEM", Theme.speakerRemote, level: state.meetingThemLevel)
            }
        }
    }

    private func meterRow(_ label: String, _ color: Color, level: Float) -> some View {
        HStack(spacing: 11) {
            trackLabel(label, color)
            FlowWave(level: level, live: true, width: 255, height: 22, tint: color)
        }
        .frame(height: 22)
    }

    private func trackLabel(_ text: String, _ color: Color) -> some View {
        Text(text)
            .font(Theme.mono(9.5, .medium))
            .tracking(1)
            .foregroundStyle(color)
            .frame(width: 44, alignment: .leading)
    }

    /// Latest words on either channel: prefer whichever volatile hypothesis
    /// updated last, fall back to the last finalized utterance.
    private var caption: (speaker: Speaker, text: String)? {
        let me = state.meetingVolatileMe
        let them = state.meetingVolatileThem
        if lastVolatileWasMe, !me.isEmpty { return (.me, me) }
        if !them.isEmpty { return (.them, them) }
        if !me.isEmpty { return (.me, me) }
        if let last = state.meetingUtterances.last { return (last.speaker, last.text) }
        return nil
    }

    private var captionStrip: some View {
        Group {
            if let cap = caption {
                Text(cap.speaker.rawValue)
                    .font(Theme.display(11, .semibold))
                    .foregroundStyle(cap.speaker == .me ? Theme.green : Theme.speakerRemote)
                + Text("  \(latestWords(cap.text))")
                    .font(Theme.display(12))
                    .italic()
                    .foregroundStyle(Theme.textDim2)
            } else {
                Text("Listening…")
                    .font(Theme.display(12))
                    .italic()
                    .foregroundStyle(Theme.textMeta)
            }
        }
        .lineLimit(2)
        .lineSpacing(2)
        .frame(maxWidth: .infinity, minHeight: 36, alignment: .topLeading)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Theme.lift(0.03), in: RoundedRectangle(cornerRadius: 9))
    }

    /// Tail of a long hypothesis so the caption always shows the newest
    /// words, cut on a word boundary.
    private func latestWords(_ text: String, maxLength: Int = 110) -> String {
        guard text.count > maxLength else { return text }
        let tail = text.suffix(maxLength)
        guard let space = tail.firstIndex(of: " ") else { return "…" + tail }
        return "…" + tail[tail.index(after: space)...]
    }

    private var controls: some View {
        HStack(spacing: 8) {
            Button {
                controller.flagMoment()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "flag")
                        .font(.system(size: 11, weight: .medium))
                    Text("Flag")
                }
            }
            .buttonStyle(DimButtonStyle())
            .help("Drop a timestamped marker into the meeting notes")

            SquareIconButton(systemName: "doc.text", help: "Open transcript") {
                WindowRouter.shared.show(id: "meeting", title: "Meeting",
                                         size: NSSize(width: 560, height: 520),
                                         brandChrome: true) {
                    MeetingWindowView().environmentObject(AppState.shared)
                }
            }

            Button {
                MeetingController.shared.stop()
                HubWindow.open(.meetings)
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 10, weight: .bold))
                    Text("Stop & save")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(RecButtonStyle())
        }
    }

    private var footer: some View {
        VStack(spacing: 12) {
            Rectangle().fill(Theme.hairline(0.07)).frame(height: 1)
            HStack(spacing: 7) {
                GlowDot(color: Theme.green, size: 6)
                Text("Nothing leaves this Mac — transcribing on-device")
                    .font(Theme.display(11))
                    .foregroundStyle(Theme.textMeta)
                Spacer(minLength: 0)
            }
        }
    }

    // MARK: Collapsed pill

    /// Minimized state — matches the dictation pill: no chrome, just the mark +
    /// a flowing wave (driven by whichever channel is loudest). Click to expand.
    private var pill: some View {
        Button {
            hud.collapsed = false
        } label: {
            HStack(spacing: 8) {
                MarkGlyph(size: 16, live: true)
                FlowWave(level: max(state.meetingMeLevel, state.meetingThemLevel),
                         live: true, width: 96, height: 18)
            }
            .padding(6)
            .contentShape(Rectangle())
            .shadow(color: .black.opacity(0.28), radius: 4, y: 1)
        }
        .buttonStyle(.plain)
        .help("Expand recording HUD")
    }
}

/// 36px square secondary icon button (transcript shortcut).
private struct SquareIconButton: View {
    let systemName: String
    var help: String = ""
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(hovering ? Theme.textHi : Theme.textBody)
                .frame(width: 36, height: 36)
                .background(Theme.lift(hovering ? 0.08 : 0.045),
                            in: RoundedRectangle(cornerRadius: 9))
                .overlay(RoundedRectangle(cornerRadius: 9)
                    .strokeBorder(Theme.hairline(0.1), lineWidth: 1))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
    }
}
