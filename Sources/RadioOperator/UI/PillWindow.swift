import AppKit
import SwiftUI

/// The floating live-transcript pill: a borderless, non-activating panel that
/// appears bottom-center on the screen containing the frontmost app's window,
/// shows live volatile/final text while dictating, and reports paste failures
/// (its most important error job — it's already where the user is looking).
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
                contentRect: NSRect(x: 0, y: 0, width: 560, height: 96),
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

    private var isError: Bool {
        if case .error = state.dictationPhase { return true }
        return false
    }
    private var errorMessage: String {
        if case .error(let m) = state.dictationPhase { return m }
        return ""
    }
    /// Recording is the fully-live state; finalizing/pasting dim the wave.
    private var isLive: Bool {
        if case .recording = state.dictationPhase { return true }
        return false
    }

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            HStack(spacing: 9.5) {
                Image(nsImage: MenuBarIcon.emblem(
                    color: NSColor(srgbRed: 0.706, green: 0.639, blue: 0.455, alpha: 1), size: 24.7))
                    .frame(width: 24.7, height: 24.7)
                if isError {
                    HStack(spacing: 6.5) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(Palette.live)
                            .font(.system(size: 13))
                        Text(errorMessage)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Palette.bone)
                            .lineLimit(2)
                            .frame(maxWidth: 275, alignment: .leading)
                    }
                } else {
                    Waveform(level: state.micLevel, live: isLive)
                }
            }
            .padding(.horizontal, 12.5)
            .padding(.vertical, 9.5)
            .fixedSize(horizontal: true, vertical: true)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color(red: 0.07, green: 0.068, blue: 0.055))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.07), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.55), radius: 11.5, y: 3)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .padding(.bottom, 2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(isError ? "Radio Operator: \(errorMessage)" : "Radio Operator listening")
    }
}

/// OD-green voice waveform — the whole "on air" indicator. Reactive to mic level,
/// with a shaped envelope so it reads as a waveform even in silence. Static under
/// Reduce Motion.
struct Waveform: View {
    let level: Float
    var live: Bool = true

    private var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    // Voice-shaped envelope: tapered ends, busy middle.
    private let env: [CGFloat] = [
        0.14, 0.28, 0.46, 0.36, 0.62, 0.90, 0.68, 1.0, 0.82, 0.58, 0.74,
        0.50, 0.80, 1.0, 0.66, 0.88, 0.60, 0.42, 0.64, 0.40, 0.26, 0.15
    ]

    var body: some View {
        HStack(spacing: 2.4) {
            ForEach(env.indices, id: \.self) { i in
                Capsule()
                    .fill(Palette.od)
                    .frame(width: 2.4, height: barHeight(i))
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: level)
            }
        }
        .frame(height: 26.5)
        .shadow(color: Palette.od.opacity(0.6), radius: 2.4)
        .opacity(live ? 1 : 0.5)
    }

    private func barHeight(_ i: Int) -> CGFloat {
        let base: CGFloat = 2.4
        // Floor keeps a visible wave in silence; level scales it up.
        let lvl = CGFloat(max(0.12, min(1, level)))
        return base + env[i] * (3.3 + lvl * 18)
    }
}
