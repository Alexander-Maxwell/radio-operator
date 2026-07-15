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
                // Full size (the oscilloscope look). No cross-state animation, so
                // state swaps snap cleanly with no cross-fade ghost on release.
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
            HStack(spacing: 12) {
                OscilloWave(level: state.micLevel)
                LCDTimer(start: recordingStart)
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

// MARK: - Oscilloscope waveform (recording)

/// A tactical oscilloscope: a dense field of fine brass striations forming a
/// center-weighted audio waveform with a hot core glow, framed by a tick ruler,
/// corner brackets, and centering chevrons. Rides the live mic level.
struct OscilloWave: View {
    let level: Float
    var width: CGFloat = 290
    var height: CGFloat = 60

    private var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    private let frameColor = Color(red: 0.60, green: 0.51, blue: 0.32).opacity(0.5)

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: reduceMotion)) { tl in
            Canvas { ctx, size in draw(ctx, size, t: tl.date.timeIntervalSinceReferenceDate) }
        }
        .frame(width: width, height: height)
    }

    private func lerp(_ a: Double, _ b: Double, _ t: Double) -> Double { a + (b - a) * t }
    /// Dim brass → brass → hot cream, by heat 0…1.
    private func brass(_ heat: Double) -> Color {
        let h = max(0, min(1, heat))
        if h < 0.5 { let u = h / 0.5
            return Color(red: lerp(0.40, 0.74, u), green: lerp(0.34, 0.62, u), blue: lerp(0.19, 0.41, u)) }
        let u = (h - 0.5) / 0.5
        return Color(red: lerp(0.74, 0.99, u), green: lerp(0.62, 0.94, u), blue: lerp(0.41, 0.80, u))
    }
    /// Center-weighted envelope with speech-like humps.
    private func env(_ x: Double) -> Double {
        exp(-pow((x - 0.5) / 0.30, 2)) * (0.5 + 0.5 * pow(abs(sin(x * 15)), 1.3))
    }

    private func draw(_ ctx: GraphicsContext, _ size: CGSize, t: Double) {
        let W = size.width, H = size.height, mid = H / 2
        let inset: CGFloat = 22
        drawRuler(ctx, W, H, inset: inset)
        drawBrackets(ctx, W, H, inset: inset)
        drawChevrons(ctx, W / 2, H)

        let lvl = Double(max(0.12, min(1, level)))
        let waveW = W - inset * 2
        let n = 120
        for i in 0..<n {
            let fx = Double(i) / Double(n - 1)
            let x = inset + CGFloat(fx) * waveW
            let e = env(fx)
            let detail = 0.30 + 0.70 * abs(sin(Double(i) * 0.63 + t * 6.5) * cos(Double(i) * 0.29 - t * 3.7))
            let a = CGFloat(e * detail * lvl) * (H * 0.44)
            var p = Path(); p.move(to: CGPoint(x: x, y: mid - a)); p.addLine(to: CGPoint(x: x, y: mid + a))
            ctx.stroke(p, with: .color(brass(min(1, e * 1.25)).opacity(0.9)), lineWidth: 1.3)
        }
        ctx.fill(Path(ellipseIn: CGRect(x: W / 2 - 46, y: mid - 26, width: 92, height: 52)),
                 with: .radialGradient(Gradient(colors: [brass(1).opacity(0.30), .clear]),
                                       center: CGPoint(x: W / 2, y: mid), startRadius: 1, endRadius: 46))
    }

    private func drawRuler(_ ctx: GraphicsContext, _ W: CGFloat, _ H: CGFloat, inset: CGFloat) {
        let count = 56
        for (yy, dir) in [(CGFloat(6), CGFloat(1)), (H - 6, CGFloat(-1))] {
            for i in 0...count {
                let x = inset - 4 + (W - inset * 2 + 8) * CGFloat(i) / CGFloat(count)
                let long = i % 5 == 0
                var p = Path(); p.move(to: CGPoint(x: x, y: yy)); p.addLine(to: CGPoint(x: x, y: yy + dir * (long ? 8 : 4)))
                ctx.stroke(p, with: .color(frameColor.opacity(long ? 0.7 : 0.38)), lineWidth: 1)
            }
        }
    }

    private func drawBrackets(_ ctx: GraphicsContext, _ W: CGFloat, _ H: CGFloat, inset: CGFloat) {
        let armW: CGFloat = 8, top = H * 0.22, bot = H * 0.78
        for (x, sgn) in [(inset, CGFloat(1)), (W - inset, CGFloat(-1))] {
            var p = Path()
            p.move(to: CGPoint(x: x + sgn * armW, y: top)); p.addLine(to: CGPoint(x: x, y: top))
            p.addLine(to: CGPoint(x: x, y: bot)); p.addLine(to: CGPoint(x: x + sgn * armW, y: bot))
            ctx.stroke(p, with: .color(frameColor), lineWidth: 1.6)
        }
    }

    private func drawChevrons(_ ctx: GraphicsContext, _ cx: CGFloat, _ H: CGFloat) {
        let w: CGFloat = 7, h: CGFloat = 5
        var top = Path(); top.move(to: CGPoint(x: cx - w, y: 2)); top.addLine(to: CGPoint(x: cx, y: 2 + h)); top.addLine(to: CGPoint(x: cx + w, y: 2))
        var bot = Path(); bot.move(to: CGPoint(x: cx - w, y: H - 2)); bot.addLine(to: CGPoint(x: cx, y: H - 2 - h)); bot.addLine(to: CGPoint(x: cx + w, y: H - 2))
        for p in [top, bot] { ctx.stroke(p, with: .color(frameColor.opacity(0.8)), lineWidth: 1.6) }
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

/// Brass LCD elapsed clock (`0:14`) in a corner-bracket frame, ticking twice a
/// second.
private struct LCDTimer: View {
    let start: Date?
    private let brass = Color(red: 0.82, green: 0.72, blue: 0.50)
    private let frameColor = Color(red: 0.60, green: 0.51, blue: 0.32).opacity(0.5)

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { context in
            Text(elapsed(to: context.date))
                .font(Theme.mono(17, .medium))
                .tracking(1)
                .foregroundStyle(brass)
                .monospacedDigit()
                .padding(.horizontal, 11).padding(.vertical, 9)
                .overlay(
                    Canvas { ctx, size in
                        let a: CGFloat = 7
                        for cx in [CGFloat(0), size.width] {
                            for cy in [CGFloat(0), size.height] {
                                let sx: CGFloat = cx == 0 ? 1 : -1, sy: CGFloat = cy == 0 ? 1 : -1
                                var p = Path()
                                p.move(to: CGPoint(x: cx + sx * a, y: cy))
                                p.addLine(to: CGPoint(x: cx, y: cy))
                                p.addLine(to: CGPoint(x: cx, y: cy + sy * a))
                                ctx.stroke(p, with: .color(frameColor), lineWidth: 1.6)
                            }
                        }
                    }
                )
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
        Ribbon(color: Color(red: 0.54, green: 0.45, blue: 0.25), amp: 0.62, freq: 1.4, speed: 0.30, phase: 0.0, w: 2.2, op: 0.32, yOff: -2.2), // dark brass
        Ribbon(color: Color(red: 0.75, green: 0.63, blue: 0.42), amp: 0.85, freq: 1.6, speed: 0.44, phase: 0.6, w: 2.0, op: 0.55, yOff:  1.3), // brass
        Ribbon(color: Color(red: 0.44, green: 0.53, blue: 0.42), amp: 0.72, freq: 1.5, speed: 0.52, phase: 1.2, w: 1.7, op: 0.50, yOff: -0.9), // olive
        Ribbon(color: Color(red: 0.84, green: 0.75, blue: 0.56), amp: 1.00, freq: 1.7, speed: 0.40, phase: 1.8, w: 1.8, op: 0.68, yOff:  2.2), // brass bright
        Ribbon(color: Color(red: 0.95, green: 0.88, blue: 0.66), amp: 0.50, freq: 1.9, speed: 0.58, phase: 2.4, w: 1.1, op: 0.55, yOff:  0.0), // brass light
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
