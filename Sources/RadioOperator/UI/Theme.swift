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

    // MARK: Surfaces (Tactical Night Operations — dark)

    /// Window background — Rich Black.
    static let bgApp = rgb(0x0B0D0F)
    /// Sidebar / panel background — Charcoal.
    static let bgSidebar = rgb(0x14181D)
    /// Transcript rail background.
    static let bgRail = rgb(0x101419)
    /// Window body / secondary surface — Charcoal.
    static let surface1 = rgb(0x14181D)
    /// Card — Tactical Graphite.
    static let surface2 = rgb(0x1A2026)
    /// Nested / meeting card.
    static let surface3 = rgb(0x1A2026)
    /// Popover / dropdown — Dark Steel.
    static let surfacePop = rgb(0x242B33)

    // MARK: Text (brightest → faintest)

    /// Largest headings.
    static let textMax = rgb(0xFFFFFF)
    /// Primary text, row titles.
    static let textHi = rgb(0xF2F3F5)
    /// Emphasis body.
    static let textBright = rgb(0xE3E8ED)
    /// Body copy on cards.
    static let textBody = rgb(0xCBD1D8)
    /// Muted body (transcript lines) — Secondary.
    static let textMuted = rgb(0xB5BDC6)
    /// Section paragraphs.
    static let textDim = rgb(0x98A1AB)
    /// Meeting summaries.
    static let textDim2 = rgb(0x8B95A0)
    /// Metadata, dim labels — Muted.
    static let textFaint = rgb(0x7B8793)
    /// Section eyebrow labels.
    static let textFaint2 = rgb(0x6D7883)
    /// Fine metadata.
    static let textMeta = rgb(0x616B76)
    /// Mono micro-labels.
    static let textMono = rgb(0x7B8793)
    /// Faintest (version string) — Disabled.
    static let textGhost = rgb(0x505962)
    /// Inactive sidebar item label.
    static let sidebarIdle = rgb(0x98A1AB)

    // MARK: Accents (semantic — use sparingly)

    /// The ONE brand accent: Burnished Brass — the signature color. (Name kept
    /// from the green era to avoid a global rename; see `primary` alias below.)
    static let green = rgb(0xBFA06A)
    /// Link hover / pressed (brighten).
    static let greenHi = rgb(0xD3B67C)
    /// Primary button hover.
    static let greenBtnHover = rgb(0xD3B67C)
    /// Text/icon on a brass fill.
    static let greenInk = rgb(0x111111)
    /// Warnings, "processing" — Amber.
    static let amber = rgb(0xE2A33A)
    /// Problems, failures — Muted Red.
    static let alertRed = rgb(0xC24949)
    /// Recording live dot + stop — Operational Red.
    static let recRed = rgb(0xC64545)
    /// Recording pulse / danger hover.
    static let recRedHover = rgb(0xD65252)
    /// Remote speaker ("Them" / Opponent) — Military Olive.
    static let speakerRemote = rgb(0x70886C)
    /// Local speaker ("You" / Speaking) — Brass.
    static let speakerMe = rgb(0xBFA06A)
    /// People entities, AI-extraction accent — Olive.
    static let entityPerson = rgb(0x738A65)

    // MARK: Named aliases (for new code / the pill)

    /// Same value as `green` (Burnished Brass).
    static let primary = green
    /// Primary pressed.
    static let primaryPress = rgb(0x92764A)
    /// Secondary brass (soft highlights, chips).
    static let primarySoft = rgb(0xD6C08E)
    /// Brass on DARK surfaces (pill mark + meter) — brighter for contrast.
    static let primaryBright = rgb(0xD6C08E)
    /// On-primary text.
    static let onPrimary = greenInk
    /// Opaque card & control border — Gunmetal.
    static let border = rgb(0x343E47)

    /// Hairline borders/dividers: white at 0.04–0.13 alpha (reads on dark).
    static func hairline(_ alpha: Double = 0.08) -> Color {
        Color.white.opacity(alpha)
    }

    /// Subtle light fill for hover lifts, control tracks, keycaps on dark.
    static func lift(_ alpha: Double = 0.05) -> Color {
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
