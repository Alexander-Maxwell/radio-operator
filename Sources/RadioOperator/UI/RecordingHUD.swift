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
    @Published var collapsed = false {
        didSet { resizePanel() }
    }

    private var panel: NSPanel?

    private init() {}

    func show() {
        if panel == nil { panel = makePanel() }
        guard let panel else { return }
        let size = Self.hudSize(collapsed: collapsed)
        if let screen = activeScreen() {
            let vis = screen.visibleFrame
            panel.setFrame(NSRect(x: vis.maxX - 24 - size.width, y: vis.minY + 24,
                                  width: size.width, height: size.height), display: false)
        }
        panel.orderFrontRegardless()
    }

    func dismiss() {
        panel?.orderOut(nil)
    }

    /// Fixed HUD sizes. ponytail: the meter animates at 60fps, so ANY live
    /// content-driven resize oscillates. The card is fixed-width with a
    /// fixed-height caption, so its size is constant — no tracking needed. Bump
    /// the expanded height if the card layout ever grows past it (bottom-anchored,
    /// so the footer/buttons never clip — only the header would).
    static func hudSize(collapsed: Bool) -> NSSize {
        collapsed ? NSSize(width: 140, height: 40) : NSSize(width: 352, height: 312)
    }

    /// Bottom-right-anchored resize to the fixed size for the current state.
    private func resizePanel() {
        guard let panel else { return }
        let size = Self.hudSize(collapsed: collapsed)
        let cur = panel.frame
        panel.setFrame(NSRect(x: cur.maxX - size.width, y: cur.minY,
                              width: size.width, height: size.height), display: true)
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
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        .environment(\.colorScheme, .dark)
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
            meterRow("YOU", Theme.speakerMe, level: state.meetingMeLevel)
            if state.meetingDegradedNoTap {
                HStack(spacing: 11) {
                    trackLabel("THEM", Theme.speakerRemote)
                    Text("mic only — system audio unavailable")
                        .font(Theme.display(11))
                        .foregroundStyle(Theme.amber)
                }
                .frame(height: 22)   // match meterRow so a degraded flap can't change height
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
                    .foregroundStyle(cap.speaker == .me ? Theme.speakerMe : Theme.speakerRemote)
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
        // FIXED height (reserve 2 lines), NOT minHeight: the live caption streams
        // and flaps 1<->2 lines, and any height change re-drives the panel resize
        // -> the box oscillates. A constant height keeps the whole card size stable.
        .frame(maxWidth: .infinity, minHeight: 40, maxHeight: 40, alignment: .topLeading)
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
            FlowWave(level: max(state.meetingMeLevel, state.meetingThemLevel),
                     live: true, width: 112, height: 20)
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
