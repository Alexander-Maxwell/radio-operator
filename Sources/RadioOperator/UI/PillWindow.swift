import AppKit
import SwiftUI

/// The floating live-transcript pill: a borderless, non-activating panel that
/// appears bottom-center on the screen containing the frontmost app's window,
/// shows the recording state while dictating, and reports paste failures (its
/// most important error job — it's already where the user is looking).
///
/// Visually it's a translucent "liquid glass" capsule: frosted vibrancy over the
/// desktop, a bright rim, and a flowing multi-hued waveform in the violet family.
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
                contentRect: NSRect(x: 0, y: 0, width: 560, height: 120),
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
            // Light-committed so the frosted glass renders as light vibrancy
            // regardless of the system appearance.
            panel.appearance = NSAppearance(named: .aqua)
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
            HStack(spacing: 10) {
                MarkGlyph(size: 19, live: isLive)
                content
            }
            .padding(.leading, 11)
            .padding(.trailing, 16)
            .padding(.vertical, 7)
            .fixedSize(horizontal: true, vertical: true)
            .background(glass)
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(
                        LinearGradient(colors: [Palette.glassRimTop, Palette.glassRimBottom],
                                       startPoint: .top, endPoint: .bottom),
                        lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.20), radius: 12, y: 6)
            .environment(\.colorScheme, .light)
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

    /// Frosted vibrancy + a faint white wash (keeps a light body over any
    /// desktop so the dark text and ink mark stay legible).
    private var glass: some View {
        ZStack {
            Capsule(style: .continuous).fill(.ultraThinMaterial)
            Capsule(style: .continuous).fill(Palette.glassTint)
        }
    }

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
            HStack(spacing: 10) {
                FlowWave(level: state.micLevel, live: true)
                TimerLabel(start: recordingStart)
            }
        } else {
            // Ready — compact resting form with a calm flow line.
            HStack(spacing: 10) {
                Text("Ready")
                    .font(Theme.display(12.5, .medium))
                    .foregroundStyle(Palette.pillText)
                FlowWave(level: 0, live: false, width: 84)
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

// MARK: - Flowing waveform ("liquid glass")

/// A layered, flowing waveform: several translucent sine ribbons in a cool
/// violet→teal gradient with a warm gold sparkle drifting along the crest. The
/// amplitude tracks the live mic level; the ribbons drift over time. Calm and
/// static when idle or under Reduce Motion.
struct FlowWave: View {
    let level: Float
    var live: Bool = true
    var width: CGFloat = 190
    var height: CGFloat = 28

    private var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    /// One ribbon. `amp`/`freq`/`speed`/`phase` shape the sine; `yOff` stacks it
    /// off the midline so the ribbons weave in layers; `w`/`op` the stroke.
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

    // Broad, near-parallel ribbons at close phases so they flow together
    // (violet lead, a teal + gold-adjacent for depth) rather than knotting.
    private let ribbons: [Ribbon] = [
        Ribbon(color: Color(red: 0.29, green: 0.25, blue: 0.63), amp: 0.62, freq: 1.4, speed: 0.30, phase: 0.0, w: 2.6, op: 0.32, yOff: -2.5), // indigo (back)
        Ribbon(color: Color(red: 0.42, green: 0.36, blue: 0.90), amp: 0.85, freq: 1.6, speed: 0.44, phase: 0.6, w: 2.3, op: 0.55, yOff:  1.5), // violet
        Ribbon(color: Color(red: 0.30, green: 0.62, blue: 0.71), amp: 0.72, freq: 1.5, speed: 0.52, phase: 1.2, w: 1.9, op: 0.50, yOff: -1.0), // teal
        Ribbon(color: Color(red: 0.56, green: 0.50, blue: 1.00), amp: 1.00, freq: 1.7, speed: 0.40, phase: 1.8, w: 2.0, op: 0.68, yOff:  2.5), // periwinkle (front)
        Ribbon(color: Color(red: 0.73, green: 0.67, blue: 1.00), amp: 0.50, freq: 1.9, speed: 0.58, phase: 2.4, w: 1.2, op: 0.55, yOff:  0.0), // lilac highlight
    ]

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: reduceMotion || !live)) { tl in
            Canvas { ctx, size in
                draw(ctx, size, t: tl.date.timeIntervalSinceReferenceDate)
            }
        }
        .frame(width: width, height: height)
    }

    /// 0…1 amplitude scale: calm when idle, mic-reactive when live.
    private func ampScale() -> CGFloat {
        guard live else { return 0.16 }
        let l = CGFloat(max(0.12, min(1, level)))
        return 0.34 + 0.66 * l
    }

    /// Plateau envelope: full amplitude across the middle, tapering only at the
    /// last ~16% of each end so ribbons run edge-to-edge (not center-bunched).
    private func envelope(_ x: CGFloat, _ w: CGFloat) -> CGFloat {
        let edge = w * 0.16
        let t: CGFloat
        if x < edge { t = x / edge }
        else if x > w - edge { t = (w - x) / edge }
        else { return 1 }
        return max(0, t * t * (3 - 2 * t))          // smoothstep
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
            // Gradient that fades in/out across the width, so ends dissolve.
            let grad = Gradient(colors: [r.color.opacity(0), r.color.opacity(r.op),
                                         r.color.opacity(r.op), r.color.opacity(0)])
            let shading = GraphicsContext.Shading.linearGradient(
                grad, startPoint: .zero, endPoint: CGPoint(x: size.width, y: 0))
            // Soft glow pass, then the crisp ribbon.
            ctx.stroke(path, with: shading,
                       style: StrokeStyle(lineWidth: r.w * 2.1, lineCap: .round, lineJoin: .round))
            ctx.stroke(path, with: shading,
                       style: StrokeStyle(lineWidth: r.w, lineCap: .round, lineJoin: .round))
        }
        drawSparkle(ctx, size, t)
    }

    /// Warm gold + white specks twinkling along the front ribbon — the shimmer.
    private func drawSparkle(_ ctx: GraphicsContext, _ size: CGSize, _ t: Double) {
        guard live else { return }
        let carrier = ribbons[3]        // periwinkle front ribbon
        let gold = Color(red: 0.86, green: 0.80, blue: 0.55)
        let count = 54
        for k in 0..<count {
            let x = size.width * CGFloat(k) / CGFloat(count)
            let cy = y(carrier, x, size, t)
            // Deterministic per-speck randomness (no RNG needed).
            let h = sin(Double(k) * 12.9898) * 43758.5453
            let fr = CGFloat(h - h.rounded(.down))
            let twinkle = 0.5 + 0.5 * sin(t * 3.1 + Double(k) * 1.7)
            let op = (0.12 + 0.72 * fr) * twinkle
            let rad: CGFloat = 0.5 + 1.0 * fr
            // Cling close to the crest so it reads as a shimmer along the wave.
            let jitter = (fr - 0.5) * size.height * 0.18
            let rect = CGRect(x: x - rad, y: cy + jitter - rad, width: 2 * rad, height: 2 * rad)
            let color = (fr > 0.82 ? Color.white : gold).opacity(op * 0.9)
            ctx.fill(Path(ellipseIn: rect), with: .color(color))
        }
    }
}

// MARK: - Transcribing dots

/// Three dots that pulse in sequence — the "working" affordance while text is
/// being transcribed or transformed.
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
