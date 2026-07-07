import AppKit
import SwiftUI

/// The floating live-transcript pill: a borderless, non-activating panel that
/// appears bottom-center on the screen containing the frontmost app's window,
/// shows the recording state while dictating, and reports paste failures (its
/// most important error job — it's already where the user is looking).
@MainActor
final class PillController {
    static let shared = PillController()

    private var panel: NSPanel?

    func show() {
        let panel: NSPanel
        if let existing = self.panel {
            panel = existing
        } else {
            panel = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 560, height: 110),
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            panel.level = .statusBar
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false
            panel.ignoresMouseEvents = true
            panel.hidesOnDeactivate = false
            panel.isReleasedWhenClosed = false
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
            panel.contentViewController = NSHostingController(
                rootView: PillView().environmentObject(AppState.shared))
            self.panel = panel
        }
        position(panel)
        panel.orderFrontRegardless()
    }

    func dismiss() {
        panel?.orderOut(nil)
    }

    private func position(_ panel: NSPanel) {
        // Screen of the frontmost app's key window ≈ screen with mouse focus;
        // fall back to main.
        let screen = NSScreen.screens.first(where: { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) })
            ?? NSScreen.main ?? NSScreen.screens.first
        guard let screen else { return }
        let frame = screen.visibleFrame
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(
            x: frame.midX - size.width / 2,
            y: frame.minY + 28))
    }
}

struct PillView: View {
    @EnvironmentObject var state: AppState

    /// Elapsed recording clock. Started/stopped as the live state flips; the
    /// app has no dictation start-timestamp, so the pill owns it.
    @State private var recordingStart: Date?

    private var isError: Bool {
        if case .error = state.dictationPhase { return true }
        return false
    }
    private var errorMessage: String {
        if case .error(let m) = state.dictationPhase { return m }
        return ""
    }
    /// Fully-live capture: dictation or Command Mode hearing the instruction.
    private var isLive: Bool {
        if case .recording = state.dictationPhase { return true }
        return state.commandPhase == .recording
    }
    /// Text is being transcribed / transformed (dictation finalizing, or any
    /// mid-flight Command Mode stage before the paste).
    private var isTranscribing: Bool {
        if case .finalizing = state.dictationPhase { return true }
        switch state.commandPhase {
        case .capturing, .transforming: return true
        default: return false
        }
    }
    /// The insert moment — mapped to the handoff "Saved to notes" state.
    private var isSaved: Bool {
        if case .pasting = state.dictationPhase { return true }
        return state.commandPhase == .pasting
    }

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            HStack(spacing: 9) {
                mark
                content
            }
            .padding(.leading, 10)
            .padding(.trailing, 14)
            .padding(.vertical, 6)
            .fixedSize(horizontal: true, vertical: true)
            .background(Capsule(style: .continuous).fill(Palette.pillBG))
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(isLive ? Palette.pillBorder : Palette.pillBorderIdle,
                                  lineWidth: 0.75)
            )
            .shadow(color: .black.opacity(0.34), radius: 8, y: 4)
            .animation(.spring(response: 0.26, dampingFraction: 0.85), value: pillPhase)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .padding(.bottom, 2)
        .onChange(of: isLive) { _, live in
            recordingStart = live ? Date() : nil
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    // MARK: Left mark (always present) — violet R-in-O, with a listening pulse.

    private var mark: some View {
        MarkGlyph(size: 19, live: isLive)
    }

    // MARK: State-dependent trailing content

    @ViewBuilder private var content: some View {
        if isError {
            noticeRow(icon: "exclamationmark.triangle.fill", tint: Palette.alert, text: errorMessage)
        } else if let notice = state.commandNotice {
            noticeRow(icon: "wand.and.stars", tint: Palette.mark, text: notice)
        } else if isSaved {
            HStack(spacing: 6) {
                Image(systemName: "checkmark")
                    .font(.system(size: 10.5, weight: .bold))
                    .foregroundStyle(Palette.mark)
                Text("Saved to notes")
                    .font(Theme.display(12.5, .medium))
                    .foregroundStyle(Palette.pillText)
            }
        } else if isTranscribing {
            HStack(spacing: 8) {
                Text("Transcribing")
                    .font(Theme.display(12.5, .medium))
                    .foregroundStyle(Palette.pillText)
                TranscribingDots()
            }
        } else if isLive {
            HStack(spacing: 9) {
                RoMeter(level: state.micLevel, live: true)
                TimerLabel(start: recordingStart)
            }
        } else {
            // Ready — compact resting form.
            HStack(spacing: 8) {
                Text("Ready")
                    .font(Theme.display(12.5, .medium))
                    .foregroundStyle(Palette.pillText)
                RoMeter(level: 0, live: false)
            }
        }
    }

    private func noticeRow(icon: String, tint: Color, text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .foregroundStyle(tint)
                .font(.system(size: 11.5))
            Text(text)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(Palette.pillText)
                .lineLimit(2)
                .frame(maxWidth: 275, alignment: .leading)
        }
    }

    /// A coarse key so width/opacity changes spring between distinct states.
    private var pillPhase: Int {
        if isError { return 0 }
        if state.commandNotice != nil { return 1 }
        if isSaved { return 2 }
        if isTranscribing { return 3 }
        if isLive { return 4 }
        return 5
    }

    private var accessibilityText: String {
        if isError { return "Radio Operator: \(errorMessage)" }
        if let n = state.commandNotice { return "Radio Operator: \(n)" }
        if isSaved { return "Radio Operator: saved to notes" }
        if isTranscribing { return "Radio Operator: transcribing" }
        if isLive { return "Radio Operator: recording" }
        return "Radio Operator: ready"
    }
}

// MARK: - Mark with a subtle "listening" pulse

/// The violet R-in-O mark, scaled/opacity-pulsed on the O ring (~1.7s loop)
/// while live to reinforce "listening." Static under Reduce Motion.
private struct MarkGlyph: View {
    let size: CGFloat
    let live: Bool

    @State private var pulse = false

    private var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    var body: some View {
        Image(nsImage: MenuBarIcon.emblem(color: Palette.markNS, size: size))
            .frame(width: size, height: size)
            .scaleEffect(live && pulse && !reduceMotion ? 1.03 : 1)
            .opacity(live && pulse && !reduceMotion ? 0.88 : 1)
            .onChange(of: live) { _, isLive in
                pulse = false
                guard isLive, !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 0.85).repeatForever(autoreverses: true)) {
                    pulse = true
                }
            }
    }
}

// MARK: - Meter

/// The recording meter: a row of thin, center-weighted vertical bars that scale
/// with the live input level. Violet while recording, faint and flat when idle.
/// Static under Reduce Motion.
struct RoMeter: View {
    let level: Float
    var live: Bool = true
    var barCount: Int = 11
    var maxHeight: CGFloat = 22

    private var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    // Center-weighted envelope: tall in the middle, short tails. Gentle texture
    // so the row reads clean, not jagged.
    private func envelope(_ i: Int) -> CGFloat {
        let x = Double(i) / Double(max(1, barCount - 1))    // 0…1
        let bell = sin(.pi * x)                              // 0 at ends, 1 center
        let texture = 0.84 + 0.16 * sin(x * 17)
        return CGFloat(bell * bell * texture)
    }

    private func barHeight(_ i: Int) -> CGFloat {
        guard live else { return 3 }                        // idle: flat 3px
        let lvl = CGFloat(max(0.16, min(1, level)))
        return 4 + envelope(i) * (maxHeight - 4) * lvl
    }

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<barCount, id: \.self) { i in
                RoundedRectangle(cornerRadius: 1.25, style: .continuous)
                    .fill(live ? Palette.mark : Palette.meterIdle)
                    .frame(width: 2.5, height: barHeight(i))
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.11), value: level)
            }
        }
        .frame(height: maxHeight, alignment: .center)
    }
}

// MARK: - Transcribing dots

/// Three dots at 100/55/25% opacity that pulse in sequence — the "working"
/// affordance while text is being transcribed or transformed.
private struct TranscribingDots: View {
    @State private var phase = 0

    private var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }
    private let timer = Timer.publish(every: 0.28, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(spacing: 3.5) {
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .fill(Palette.mark)
                    .frame(width: 4.5, height: 4.5)
                    .opacity(opacity(i))
            }
        }
        .onReceive(timer) { _ in
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 0.28)) { phase = (phase + 1) % 3 }
        }
    }

    private func opacity(_ i: Int) -> Double {
        if reduceMotion { return [1.0, 0.55, 0.25][i] }
        // The lit dot travels; the two behind it trail off.
        switch (i - phase + 3) % 3 {
        case 0: return 1.0
        case 1: return 0.55
        default: return 0.25
        }
    }
}

// MARK: - Timer

/// Mono elapsed clock (`0:14`) driven off the recording start, ticking twice a
/// second so the seconds read live without a per-frame redraw.
private struct TimerLabel: View {
    let start: Date?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { context in
            Text(elapsed(to: context.date))
                .font(Theme.mono(11, .medium))
                .tracking(0.5)
                .foregroundStyle(Palette.pillMeta)
                .monospacedDigit()
        }
    }

    private func elapsed(to now: Date) -> String {
        guard let start else { return "0:00" }
        let s = max(0, Int(now.timeIntervalSince(start)))
        return "\(s / 60):\(String(format: "%02d", s % 60))"
    }
}
