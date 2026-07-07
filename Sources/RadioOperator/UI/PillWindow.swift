import AppKit
import SwiftUI

/// The floating live-transcript pill: a borderless, non-activating panel that
/// appears bottom-center on the screen containing the frontmost app's window,
/// shows the recording state while dictating, and reports paste failures (its
/// most important error job — it's already where the user is looking).
///
/// A dark near-black capsule whose meter spells in Morse: wide bars = dashes,
/// narrow = dots, riding the live level; at rest it relaxes to a resting Morse
/// pattern.
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
                contentRect: NSRect(x: 0, y: 0, width: 460, height: 96),
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
        let screen = NSScreen.screens.first(where: { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) })
            ?? NSScreen.main ?? NSScreen.screens.first
        guard let screen else { return }
        let frame = screen.visibleFrame
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(
            x: frame.midX - size.width / 2,
            y: frame.minY + 26))
    }
}

struct PillView: View {
    @EnvironmentObject var state: AppState

    /// Elapsed recording clock. The app has no dictation start-timestamp, so the
    /// pill owns it.
    @State private var recordingStart: Date?

    private var isError: Bool {
        if case .error = state.dictationPhase { return true }
        return false
    }
    private var errorMessage: String {
        if case .error(let m) = state.dictationPhase { return m }
        return ""
    }
    private var isLive: Bool {
        if case .recording = state.dictationPhase { return true }
        return state.commandPhase == .recording
    }
    private var isTranscribing: Bool {
        if case .finalizing = state.dictationPhase { return true }
        switch state.commandPhase {
        case .capturing, .transforming: return true
        default: return false
        }
    }
    private var isSaved: Bool {
        if case .pasting = state.dictationPhase { return true }
        return state.commandPhase == .pasting
    }

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            content
                .padding(.leading, 13)
                .padding(.trailing, 15)
                .padding(.vertical, 8)
                .fixedSize(horizontal: true, vertical: true)
                .background(Capsule(style: .continuous).fill(Palette.pillBG))
                .overlay(
                    Capsule(style: .continuous)
                        .strokeBorder(isLive ? Palette.pillBorder : Palette.pillBorderIdle,
                                      lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.45), radius: 12, y: 6)
                .shadow(color: Palette.mark.opacity(isLive ? 0.16 : 0), radius: 9)
                .animation(.spring(response: 0.26, dampingFraction: 0.85), value: pillPhase)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .padding(.bottom, 3)
        .onChange(of: isLive) { _, live in
            recordingStart = live ? Date() : nil
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    @ViewBuilder private var content: some View {
        if isError {
            noticeRow(icon: "exclamationmark.triangle.fill", tint: Palette.alert, text: errorMessage)
        } else if let notice = state.commandNotice {
            noticeRow(icon: "wand.and.stars", tint: Palette.mark, text: notice)
        } else if isSaved {
            HStack(spacing: 8) {
                MorseMark()
                Image(systemName: "checkmark")
                    .font(.system(size: 10.5, weight: .bold))
                    .foregroundStyle(Palette.mark)
                Text("Saved to notes")
                    .font(Theme.display(12.5, .medium))
                    .foregroundStyle(Palette.pillText)
            }
        } else if isTranscribing {
            HStack(spacing: 9) {
                MorseMark()
                Text("Transcribing")
                    .font(Theme.display(12.5, .medium))
                    .foregroundStyle(Palette.pillText)
                TranscribingDots()
            }
        } else if isLive {
            HStack(spacing: 11) {
                MorseMeter(level: state.micLevel)
                TimerLabel(start: recordingStart)
            }
        } else {
            // Ready — resting Morse pattern + label.
            HStack(spacing: 9) {
                MorseMark()
                Text("Ready")
                    .font(Theme.display(12.5, .medium))
                    .foregroundStyle(Palette.pillText)
            }
        }
    }

    private func noticeRow(icon: String, tint: Color, text: String) -> some View {
        HStack(spacing: 7) {
            Image(systemName: icon)
                .foregroundStyle(tint)
                .font(.system(size: 12.5))
            Text(text)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(Palette.pillText)
                .lineLimit(2)
                .frame(maxWidth: 270, alignment: .leading)
        }
    }

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

// MARK: - Resting Morse mark  ( ·—··· )

/// The pill's resting signal: a compact horizontal row of dots and a dash in
/// violet, echoing the icon's Morse mark. Shown in the Ready / Transcribing /
/// Saved states.
private struct MorseMark: View {
    // true = dash, false = dot.
    private let cells: [Bool] = [false, true, false, false, false]

    var body: some View {
        HStack(spacing: 4) {
            ForEach(cells.indices, id: \.self) { i in
                Capsule(style: .continuous)
                    .fill(Palette.mark)
                    .frame(width: cells[i] ? 13 : 5, height: 5)
            }
        }
    }
}

// MARK: - Morse meter (recording)

/// The recording meter that literally spells in Morse: a row of vertical bars
/// whose WIDTHS encode dashes (wide) and dots (narrow) — the pattern reads
/// R·−· O−−− R·−· — and whose HEIGHTS ride the live input level. Drifts subtly
/// so it feels alive; static under Reduce Motion.
private struct MorseMeter: View {
    let level: Float
    var height: CGFloat = 24

    private var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    // true = dash (wide bar), false = dot (narrow bar). R O R.
    private let pattern: [Bool] = [false, true, false, true, true, true, false, true, false]
    private let dotW: CGFloat = 5.5
    private let dashW: CGFloat = 12
    private let gap: CGFloat = 5

    private var totalWidth: CGFloat {
        pattern.reduce(0) { $0 + ($1 ? dashW : dotW) } + gap * CGFloat(pattern.count - 1)
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: reduceMotion)) { tl in
            Canvas { ctx, size in
                draw(ctx, size, t: tl.date.timeIntervalSinceReferenceDate)
            }
        }
        .frame(width: totalWidth, height: height)
    }

    /// Taller in the middle, shorter at the ends.
    private func centerWeight(_ i: Int) -> CGFloat {
        let x = Double(i) / Double(max(1, pattern.count - 1))
        return CGFloat(0.5 + 0.5 * sin(.pi * x))
    }

    private func draw(_ ctx: GraphicsContext, _ size: CGSize, t: Double) {
        let lvl = CGFloat(max(0.14, min(1, level)))
        let base: CGFloat = 4
        var x: CGFloat = 0
        for (i, isDash) in pattern.enumerated() {
            let w = isDash ? dashW : dotW
            let shimmer = reduceMotion ? 1 : (0.78 + 0.22 * sin(t * 4 + Double(i) * 0.9))
            let h = min(size.height, base + centerWeight(i) * lvl * (size.height - base) * CGFloat(shimmer))
            let rect = CGRect(x: x, y: (size.height - h) / 2, width: w, height: h)
            ctx.fill(Path(roundedRect: rect, cornerRadius: min(w, h) / 2), with: .color(Palette.mark))
            x += w + gap
        }
    }
}

// MARK: - Transcribing dots

/// Three dots that pulse in sequence — three dots keep the beat while text is
/// transcribed or transformed.
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
        switch (i - phase + 3) % 3 {
        case 0: return 1.0
        case 1: return 0.55
        default: return 0.25
        }
    }
}

// MARK: - Timer

/// Mono elapsed clock (`0:14`), ticking twice a second.
private struct TimerLabel: View {
    let start: Date?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { context in
            Text(elapsed(to: context.date))
                .font(Theme.mono(11.5, .medium))
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

// MARK: - Flowing waveform (meeting HUD)

/// A layered, flowing waveform: several translucent sine ribbons that drift and
/// track the level. Used by the meeting HUD (per-channel, `tint`ed). Calm and
/// static when idle or under Reduce Motion.
struct FlowWave: View {
    let level: Float
    var live: Bool = true
    var width: CGFloat = 124
    var height: CGFloat = 20
    /// When set, the ribbons are shades of this single hue (a mono channel wave).
    var tint: Color? = nil

    private var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    private struct Ribbon {
        let color: Color
        let amp: CGFloat
        let freq: CGFloat
        let speed: Double
        let phase: CGFloat
        let w: CGFloat
        let op: CGFloat
        let yOff: CGFloat
    }

    private static let brandRibbons: [Ribbon] = [
        Ribbon(color: Color(red: 0.29, green: 0.25, blue: 0.63), amp: 0.62, freq: 1.4, speed: 0.30, phase: 0.0, w: 2.2, op: 0.32, yOff: -2.2),
        Ribbon(color: Color(red: 0.42, green: 0.36, blue: 0.90), amp: 0.85, freq: 1.6, speed: 0.44, phase: 0.6, w: 2.0, op: 0.55, yOff:  1.3),
        Ribbon(color: Color(red: 0.30, green: 0.62, blue: 0.71), amp: 0.72, freq: 1.5, speed: 0.52, phase: 1.2, w: 1.7, op: 0.50, yOff: -0.9),
        Ribbon(color: Color(red: 0.56, green: 0.50, blue: 1.00), amp: 1.00, freq: 1.7, speed: 0.40, phase: 1.8, w: 1.8, op: 0.68, yOff:  2.2),
        Ribbon(color: Color(red: 0.73, green: 0.67, blue: 1.00), amp: 0.50, freq: 1.9, speed: 0.58, phase: 2.4, w: 1.1, op: 0.55, yOff:  0.0),
    ]

    private var ribbons: [Ribbon] {
        guard let tint else { return Self.brandRibbons }
        return [
            Ribbon(color: tint,        amp: 0.62, freq: 1.4, speed: 0.30, phase: 0.0, w: 2.0, op: 0.22, yOff: -2.2),
            Ribbon(color: tint,        amp: 0.85, freq: 1.6, speed: 0.44, phase: 0.6, w: 1.8, op: 0.42, yOff:  1.3),
            Ribbon(color: tint,        amp: 0.72, freq: 1.5, speed: 0.52, phase: 1.2, w: 1.6, op: 0.34, yOff: -0.9),
            Ribbon(color: tint,        amp: 1.00, freq: 1.7, speed: 0.40, phase: 1.8, w: 1.7, op: 0.60, yOff:  2.2),
            Ribbon(color: Color.white, amp: 0.50, freq: 1.9, speed: 0.58, phase: 2.4, w: 1.0, op: 0.35, yOff:  0.0),
        ]
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: reduceMotion || !live)) { tl in
            Canvas { ctx, size in
                draw(ctx, size, t: tl.date.timeIntervalSinceReferenceDate)
            }
        }
        .frame(width: width, height: height)
    }

    private func ampScale() -> CGFloat {
        guard live else { return 0.16 }
        let l = CGFloat(max(0.12, min(1, level)))
        return 0.34 + 0.66 * l
    }

    private func envelope(_ x: CGFloat, _ w: CGFloat) -> CGFloat {
        let edge = w * 0.16
        let t: CGFloat
        if x < edge { t = x / edge }
        else if x > w - edge { t = (w - x) / edge }
        else { return 1 }
        return max(0, t * t * (3 - 2 * t))
    }

    private func y(_ r: Ribbon, _ x: CGFloat, _ size: CGSize, _ t: Double) -> CGFloat {
        let midY = size.height / 2 + r.yOff * ampScale()
        let a = ampScale() * r.amp * (size.height * 0.40)
        let ph = CGFloat(t * r.speed) + r.phase
        return midY + a * envelope(x, size.width) * sin(r.freq * 2 * .pi * x / size.width + ph)
    }

    private func ribbonPath(_ r: Ribbon, _ size: CGSize, _ t: Double) -> Path {
        var p = Path()
        let steps = 72
        for i in 0...steps {
            let x = size.width * CGFloat(i) / CGFloat(steps)
            let pt = CGPoint(x: x, y: y(r, x, size, t))
            if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
        }
        return p
    }

    private func draw(_ ctx: GraphicsContext, _ size: CGSize, t: Double) {
        for r in ribbons {
            let path = ribbonPath(r, size, t)
            let grad = Gradient(colors: [r.color.opacity(0), r.color.opacity(r.op),
                                         r.color.opacity(r.op), r.color.opacity(0)])
            let shading = GraphicsContext.Shading.linearGradient(
                grad, startPoint: .zero, endPoint: CGPoint(x: size.width, y: 0))
            ctx.stroke(path, with: shading,
                       style: StrokeStyle(lineWidth: r.w * 2.1, lineCap: .round, lineJoin: .round))
            ctx.stroke(path, with: shading,
                       style: StrokeStyle(lineWidth: r.w, lineCap: .round, lineJoin: .round))
        }
    }
}
