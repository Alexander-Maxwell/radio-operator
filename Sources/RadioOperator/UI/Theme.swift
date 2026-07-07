import SwiftUI
import AppKit
import CoreText

// MARK: - Design tokens (redesign handoff, 2026-07)
//
// The single source of truth for the "signals-intelligence" design system:
// dark surfaces, one green live-signal accent, mono micro-labels. Values are
// the hex tokens from the design handoff README — change them there first.
//
// Rule: green means LIVE SIGNAL (ready / recording-safe / on-device) only.
// Never use it as generic success chrome on states that are true 99% of the
// time — that mistake is what the old five-LED SIGNAL ribbon got wrong.

enum Theme {

    // MARK: Surfaces (darkest → lightest)

    /// App/page background (deepest).
    static let bgApp = rgb(0x0A0B0D)
    /// Sidebar background.
    static let bgSidebar = rgb(0x0C0E10)
    /// Transcript rail background.
    static let bgRail = rgb(0x0C0F12)
    /// Window body / primary surface.
    static let surface1 = rgb(0x0F1215)
    /// Nested card.
    static let surface2 = rgb(0x101317)
    /// Meeting card, query bar, source card.
    static let surface3 = rgb(0x12161A)
    /// Popover / dropdown.
    static let surfacePop = rgb(0x161A1E)

    // MARK: Text (brightest → dimmest)

    /// Largest headings.
    static let textMax = rgb(0xF4F7F9)
    /// Primary text, row titles.
    static let textHi = rgb(0xE7EBEE)
    /// Emphasis body.
    static let textBright = rgb(0xD6DBDF)
    /// Body copy on cards.
    static let textBody = rgb(0xC2C8CD)
    /// Muted body (transcript lines).
    static let textMuted = rgb(0xB7BEC4)
    /// Section paragraphs.
    static let textDim = rgb(0x98A1A8)
    /// Meeting summaries.
    static let textDim2 = rgb(0x9AA1A7)
    /// Metadata, dim labels.
    static let textFaint = rgb(0x8B949B)
    /// Section eyebrow labels.
    static let textFaint2 = rgb(0x7F888F)
    /// Fine metadata.
    static let textMeta = rgb(0x6B7278)
    /// Mono micro-labels.
    static let textMono = rgb(0x5C656C)
    /// Faintest (version string).
    static let textGhost = rgb(0x454D53)
    /// Inactive sidebar item label.
    static let sidebarIdle = rgb(0xA6ADB3)

    // MARK: Accents (semantic — use sparingly)

    /// Live / ready / recording-safe / on-device. The ONE brand accent.
    static let green = rgb(0x37D67A)
    /// Link hover.
    static let greenHi = rgb(0x6EE6A2)
    /// Primary button hover.
    static let greenBtnHover = rgb(0x4BE08C)
    /// Text/icon on a green fill.
    static let greenInk = rgb(0x05230F)
    /// Warnings, "processing", mid grades.
    static let amber = rgb(0xF2B14C)
    /// Problems, failures.
    static let alertRed = rgb(0xF0674F)
    /// Recording live dot + stop button (distinct from alert red).
    static let recRed = rgb(0xF0503C)
    /// Stop button hover.
    static let recRedHover = rgb(0xFF6450)
    /// Remote speaker, brand entities.
    static let speakerRemote = rgb(0x6BA5FF)
    /// People entities, AI-extraction accent.
    static let entityPerson = rgb(0xC08CF0)

    /// Hairline borders: white at 0.06–0.13 alpha.
    static func hairline(_ alpha: Double = 0.08) -> Color {
        Color.white.opacity(alpha)
    }

    static func rgb(_ hex: UInt32) -> Color {
        Color(.sRGB,
              red: Double((hex >> 16) & 0xFF) / 255,
              green: Double((hex >> 8) & 0xFF) / 255,
              blue: Double(hex & 0xFF) / 255)
    }

    // MARK: Typography

    /// Display/UI face: Space Grotesk when bundled, SF otherwise.
    static func display(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        guard ThemeFonts.loaded else { return .system(size: size, weight: weight) }
        let name: String
        switch weight {
        case .bold, .heavy, .black: name = "SpaceGrotesk-Bold"
        case .semibold:             name = "SpaceGrotesk-SemiBold"
        case .medium:               name = "SpaceGrotesk-Medium"
        default:                    name = "SpaceGrotesk-Regular"
        }
        return .custom(name, size: size)
    }

    /// Mono face for eyebrows, timecodes, metadata: IBM Plex Mono when
    /// bundled, SF Mono otherwise.
    static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        guard ThemeFonts.loaded else {
            return .system(size: size, weight: weight, design: .monospaced)
        }
        let name: String
        switch weight {
        case .semibold, .bold, .heavy, .black: name = "IBMPlexMono-SemiBold"
        case .medium:                          name = "IBMPlexMono-Medium"
        default:                               name = "IBMPlexMono-Regular"
        }
        return .custom(name, size: size)
    }

    /// App version for the sidebar footer, from the bundle when present
    /// (debug binaries run bare, without an Info.plist).
    static var version: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "dev"
    }
}

// MARK: - Bundled font registration

/// Registers the bundled Space Grotesk + IBM Plex Mono faces (OFL-licensed,
/// resources/fonts). Looks in the app bundle first, then falls back to the
/// repo checkout so `swift build` debug binaries render identically. If
/// neither exists, `loaded` stays false and Theme falls back to SF.
enum ThemeFonts {
    private(set) static var loaded = false

    static func register() {
        guard !loaded else { return }
        var dirs: [URL] = []
        if let res = Bundle.main.resourceURL {
            dirs.append(res.appendingPathComponent("fonts", isDirectory: true))
        }
        // Debug run from .build/<config>/RadioOperator → ../../resources/fonts.
        let exe = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        dirs.append(exe.deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("resources/fonts", isDirectory: true))

        for dir in dirs {
            guard let files = try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: nil) else { continue }
            let ttfs = files.filter { $0.pathExtension.lowercased() == "ttf" }
            guard !ttfs.isEmpty else { continue }
            var ok = false
            for url in ttfs {
                ok = CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil) || ok
            }
            if ok { loaded = true; return }
        }
    }
}

// MARK: - Shared components

/// Mono uppercase section eyebrow (`SUMMARY`, `CONSOLE`, …).
struct Eyebrow: View {
    let text: String
    var size: CGFloat = 10.5
    var tracking: CGFloat = 1.9      // ≈0.18em at 10.5px
    var color: Color = Theme.textFaint2

    var body: some View {
        Text(text)
            .font(Theme.mono(size, .medium))
            .tracking(tracking)
            .foregroundStyle(color)
    }
}

/// Small glowing status dot. `pulsing` runs the ro-pulse keyframe
/// (opacity 1→0.35 + scale 1→0.85, ~1.6s), honoring Reduce Motion.
struct GlowDot: View {
    var color: Color = Theme.green
    var size: CGFloat = 7
    var pulsing = false

    @State private var dim = false

    private var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .shadow(color: color.opacity(0.7), radius: size)
            .opacity(pulsing && dim ? 0.35 : 1)
            .scaleEffect(pulsing && dim ? 0.85 : 1)
            .onAppear {
                guard pulsing, !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
                    dim = true
                }
            }
    }
}

/// Bordered mono state chip (`CLEANED`, `RAW`, `NOT PASTED`, `● NOTES READY`).
struct StateChip: View {
    let text: String
    var color: Color = Theme.textMono
    var fill: Color? = nil
    var dot = false
    var pulsingDot = false

    var body: some View {
        HStack(spacing: 5) {
            if dot { GlowDot(color: color, size: 5, pulsing: pulsingDot) }
            Text(text)
                .font(Theme.mono(9.5, .medium))
                .tracking(0.6)
        }
        .foregroundStyle(color)
        .padding(.horizontal, 7).padding(.vertical, 3)
        .background(fill ?? .clear, in: RoundedRectangle(cornerRadius: 5))
        .overlay(RoundedRectangle(cornerRadius: 5)
            .strokeBorder(color.opacity(0.35), lineWidth: 1))
    }
}

/// kbd keycap (`⌘`, `⇧`, `D`) for hotkey hints.
struct Keycap: View {
    let text: String
    var body: some View {
        Text(text)
            .font(Theme.mono(10, .medium))
            .foregroundStyle(Theme.textDim)
            .padding(.horizontal, 5).padding(.vertical, 2)
            .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4)
                .strokeBorder(Theme.hairline(0.1), lineWidth: 1))
    }
}

/// Segmented control per the handoff spec: 3px-padded track
/// rgba(255,255,255,0.045), 11px radius; active segment 0.11 white + textMax.
struct RoSegmented<T: Hashable>: View {
    let options: [(T, String)]
    @Binding var selection: T

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.0) { value, label in
                let on = selection == value
                Text(label)
                    .font(Theme.display(12.5, .medium))
                    .foregroundStyle(on ? Theme.textMax : Theme.textFaint2)
                    .padding(.horizontal, 12).padding(.vertical, 5)
                    .background(on ? Color.white.opacity(0.11) : .clear,
                                in: RoundedRectangle(cornerRadius: 8))
                    .contentShape(Rectangle())
                    .onTapGesture { selection = value }
            }
        }
        .padding(3)
        .background(Color.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 11))
    }
}

/// 30×30 hover-reveal icon button for row actions (copy / insert / overflow).
struct HoverIconButton: View {
    let systemName: String
    var help: String = ""
    var hoverTint: Color = Theme.textHi
    var hoverFill: Color = Color.white.opacity(0.07)
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(hovering ? hoverTint : Theme.textFaint)
                .frame(width: 30, height: 30)
                .background(hovering ? hoverFill : .clear,
                            in: RoundedRectangle(cornerRadius: 7))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
    }
}

/// Primary action button: green fill, dark ink, hover-brightens.
struct GreenButtonStyle: ButtonStyle {
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.display(13, .semibold))
            .foregroundStyle(Theme.greenInk)
            .padding(.horizontal, 14).padding(.vertical, 7)
            .background(hovering ? Theme.greenBtnHover : Theme.green,
                        in: RoundedRectangle(cornerRadius: 9))
            .opacity(configuration.isPressed ? 0.85 : 1)
            .onHover { hovering = $0 }
    }
}

/// Secondary action button: faint white fill + hairline border.
struct DimButtonStyle: ButtonStyle {
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.display(12.5, .medium))
            .foregroundStyle(Theme.textBody)
            .padding(.horizontal, 12).padding(.vertical, 6.5)
            .background(Color.white.opacity(hovering ? 0.08 : 0.045),
                        in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Theme.hairline(0.1), lineWidth: 1))
            .opacity(configuration.isPressed ? 0.85 : 1)
            .onHover { hovering = $0 }
    }
}

/// Destructive/live button: rec-red fill, white text (Stop & save).
struct RecButtonStyle: ButtonStyle {
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.display(13, .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 14).padding(.vertical, 7)
            .background(hovering ? Theme.recRedHover : Theme.recRed,
                        in: RoundedRectangle(cornerRadius: 9))
            .opacity(configuration.isPressed ? 0.85 : 1)
            .onHover { hovering = $0 }
    }
}

/// Card surface: fill + hairline border + radius, per the handoff card specs.
struct RoCard: ViewModifier {
    var fill: Color = Theme.surface2
    var radius: CGFloat = 13
    var border: Color = Theme.hairline(0.08)

    func body(content: Content) -> some View {
        content
            .background(fill, in: RoundedRectangle(cornerRadius: radius))
            .overlay(RoundedRectangle(cornerRadius: radius)
                .strokeBorder(border, lineWidth: 1))
    }
}

extension View {
    func roCard(fill: Color = Theme.surface2, radius: CGFloat = 13,
                border: Color = Theme.hairline(0.08)) -> some View {
        modifier(RoCard(fill: fill, radius: radius, border: border))
    }
}

/// Staggered live audio meter (the ro-wave keyframe): thin bars scaling with
/// the incoming level, colored per track. Static under Reduce Motion.
struct LevelMeter: View {
    let level: Float
    var color: Color = Theme.green
    var barCount: Int = 24
    var height: CGFloat = 16

    private var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    // Voice-shaped envelope so it reads as a waveform even at low level.
    private func envelope(_ i: Int) -> CGFloat {
        let x = Double(i) / Double(max(1, barCount - 1))
        return CGFloat(0.35 + 0.65 * sin(.pi * x) * (0.7 + 0.3 * sin(x * 19)))
    }

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<barCount, id: \.self) { i in
                Capsule()
                    .fill(color)
                    .frame(width: 3,
                           height: max(2.5, envelope(i) * height * CGFloat(max(0.15, min(1, level)))))
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: level)
            }
        }
        .frame(height: height)
    }
}

/// Hover-tracked container: row background lift + action reveal, one state.
struct HoverRow<Content: View>: View {
    var radius: CGFloat = 11
    var liftColor: Color = Color.white.opacity(0.035)
    @ViewBuilder var content: (Bool) -> Content

    @State private var hovering = false

    var body: some View {
        content(hovering)
            .background(hovering ? liftColor : .clear,
                        in: RoundedRectangle(cornerRadius: radius))
            .onHover { hovering = $0 }
    }
}
