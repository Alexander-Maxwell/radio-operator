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

    private var statusText: String {
        switch state.dictationPhase {
        case .idle: return ""
        case .recording:
            return state.dictationLocked ? "Listening — locked, press the hotkey to finish" : "Listening"
        case .finalizing: return "Finishing…"
        case .pasting: return "Pasting…"
        case .error(let message): return message
        }
    }

    private var isError: Bool {
        if case .error = state.dictationPhase { return true }
        return false
    }

    private var transcriptText: String {
        let final = state.pillFinal
        let volatile = state.pillVolatile
        let joined = [final, volatile].filter { !$0.isEmpty }.joined(separator: " ")
        return joined
    }

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            HStack(spacing: 10) {
                if isError {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                } else {
                    LevelIndicator(level: state.micLevel)
                }
                VStack(alignment: .leading, spacing: 2) {
                    if !transcriptText.isEmpty {
                        Text(transcriptText)
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(Color(nsColor: .labelColor))
                            .lineLimit(3)
                            .truncationMode(.head)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Text(statusText)
                        .font(.system(size: 11))
                        .foregroundStyle(isError ? AnyShapeStyle(.orange) : AnyShapeStyle(Color(nsColor: .secondaryLabelColor)))
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .frame(maxWidth: 540)
            .fixedSize(horizontal: true, vertical: true)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5)
            )
            .shadow(color: .black.opacity(0.25), radius: 12, y: 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .padding(.bottom, 2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Radio Operator dictation: \(statusText). \(transcriptText)")
    }
}

/// Animated mic level dots; falls back to a static bar under Reduce Motion.
struct LevelIndicator: View {
    let level: Float

    private var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    var body: some View {
        if reduceMotion {
            RoundedRectangle(cornerRadius: 2)
                .fill(Palette.accent)
                .frame(width: 20, height: 4 + CGFloat(level) * 10)
        } else {
            HStack(spacing: 3) {
                ForEach(0..<4, id: \.self) { i in
                    Capsule()
                        .fill(Palette.accent)
                        .frame(width: 3, height: barHeight(index: i))
                        .animation(.easeOut(duration: 0.12), value: level)
                }
            }
            .frame(width: 24, height: 20)
        }
    }

    private func barHeight(index: Int) -> CGFloat {
        let base: CGFloat = 5
        let scaled = CGFloat(level) * 16
        let variance: [CGFloat] = [0.6, 1.0, 0.8, 0.5]
        return base + scaled * variance[index]
    }
}
