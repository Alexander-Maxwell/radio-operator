import SwiftUI
import AppKit
import CoreText

// MARK: - Design tokens (Violet "Enclosed" identity, 2026-07)
//
// The single source of truth for RO's brand identity: a LIGHT violet surface
// system, one violet primary accent, mono micro-labels. Values are the locked
// hex tokens from `design_handoff_ro_identity/README.md` — change them there
// first. The recording pill is the one dark surface (see Palette).
//
// Token NAMES are kept stable across the green→violet migration so call sites
// don't churn; `green` is now the violet primary (aliased as `primary` for new
// code). Semantic rule: the primary accent marks brand / ready / on-device /
// selected. Red stays reserved for a live microphone (recRed).

enum Theme {

    // MARK: Surfaces (app base → white cards)

    /// App/page background.
    static let bgApp = rgb(0xF5F3FB)
    /// Sidebar background (a hair deeper than the app).
    static let bgSidebar = rgb(0xEDEAF6)
    /// Transcript rail background.
    static let bgRail = rgb(0xF0EDF8)
    /// Window body / primary surface.
    static let surface1 = rgb(0xFBFAFE)
    /// Nested card.
    static let surface2 = rgb(0xFFFFFF)
    /// Meeting card, query bar, source card.
    static let surface3 = rgb(0xFFFFFF)
    /// Popover / dropdown.
    static let surfacePop = rgb(0xFFFFFF)

    // MARK: Text (deepest ink → faintest)

    /// Largest headings.
    static let textMax = rgb(0x141026)
    /// Primary text, row titles (--ro-ink).
    static let textHi = rgb(0x191430)
    /// Emphasis body.
    static let textBright = rgb(0x241C46)
    /// Body copy on cards.
    static let textBody = rgb(0x332B5C)
    /// Muted body (transcript lines).
    static let textMuted = rgb(0x4A4276)
    /// Section paragraphs.
    static let textDim = rgb(0x5A5286)
    /// Meeting summaries.
    static let textDim2 = rgb(0x635B8E)
    /// Metadata, dim labels (--ro-ink-muted).
    static let textFaint = rgb(0x857CA8)
    /// Section eyebrow labels.
    static let textFaint2 = rgb(0x948CB6)
    /// Fine metadata.
    static let textMeta = rgb(0xA198C0)
    /// Mono micro-labels.
    static let textMono = rgb(0xA99FCB)
    /// Faintest (version string).
    static let textGhost = rgb(0xBCB5D6)
    /// Inactive sidebar item label.
    static let sidebarIdle = rgb(0x5A5286)

    // MARK: Accents (semantic — use sparingly)

    /// The ONE brand accent: violet primary. Brand / ready / on-device /
    /// active / selected. (Name kept from the green era to avoid a global
    /// rename; see `primary` alias below.)
    static let green = rgb(0x6C5CE7)
    /// Link hover / pressed (darken).
    static let greenHi = rgb(0x5A49D8)
    /// Primary button hover (darken).
    static let greenBtnHover = rgb(0x5A49D8)
    /// Text/icon on a primary fill (--ro-on-primary).
    static let greenInk = rgb(0xF3F1FF)
    /// Warnings, "processing", mid grades (readable amber on light).
    static let amber = rgb(0xC0870F)
    /// Problems, failures.
    static let alertRed = rgb(0xCF3A28)
    /// Recording live dot + stop button (distinct from alert red).
    static let recRed = rgb(0xE5402A)
    /// Stop button hover.
    static let recRedHover = rgb(0xFF5A40)
    /// Remote speaker, brand entities.
    static let speakerRemote = rgb(0x3E78D4)
    /// People entities, AI-extraction accent.
    static let entityPerson = rgb(0x9A55D0)

    // MARK: Handoff-named aliases (for new code / the pill)

    /// --ro-primary. Same value as `green`, read as violet.
    static let primary = green
    /// --ro-primary-press.
    static let primaryPress = rgb(0x5A49D8)
    /// --ro-primary-soft: secondary waveform bars, subtle highlights, chips.
    static let primarySoft = rgb(0xA99CFF)
    /// --ro-primary-bright: primary on DARK surfaces (pill mark + meter).
    static let primaryBright = rgb(0x8F7FFF)
    /// --ro-on-primary.
    static let onPrimary = greenInk
    /// --ro-border: opaque card & control border.
    static let border = rgb(0xE2DDF3)

    /// Hairline borders/dividers: ink at 0.05–0.13 alpha (reads on light).
    static func hairline(_ alpha: Double = 0.08) -> Color {
        rgb(0x191430).opacity(alpha)
    }

    /// Subtle ink fill for hover lifts, control tracks, and keycaps on the
    /// light surface (replaces the old white-on-dark `Color.white.opacity`).
    static func lift(_ alpha: Double = 0.05) -> Color {
        rgb(0x191430).opacity(alpha)
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
            .background(Theme.lift(0.06), in: RoundedRectangle(cornerRadius: 4))
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
                    .background(on ? Theme.surface2 : .clear,
                                in: RoundedRectangle(cornerRadius: 8))
                    .shadow(color: on ? Theme.hairline(0.12) : .clear, radius: 1.5, y: 0.5)
                    .contentShape(Rectangle())
                    .onTapGesture { selection = value }
            }
        }
        .padding(3)
        .background(Theme.lift(0.05), in: RoundedRectangle(cornerRadius: 11))
    }
}

/// 30×30 hover-reveal icon button for row actions (copy / insert / overflow).
struct HoverIconButton: View {
    let systemName: String
    var help: String = ""
    var hoverTint: Color = Theme.textHi
    var hoverFill: Color = Theme.lift(0.06)
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
            .background(hovering ? Theme.lift(0.07) : Theme.surface2,
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
    var liftColor: Color = Theme.lift(0.04)
    @ViewBuilder var content: (Bool) -> Content

    @State private var hovering = false

    var body: some View {
        content(hovering)
            .background(hovering ? liftColor : .clear,
                        in: RoundedRectangle(cornerRadius: radius))
            .onHover { hovering = $0 }
    }
}
