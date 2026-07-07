import SwiftUI
import AppKit

// MARK: - Sections & navigation

/// One hub window, two sidebar groups. CONSOLE is daily destinations — your
/// knowledge (Dictations, Meetings, Ask). SETTINGS is set-and-forget config;
/// Dictionary and Snippets live there because they tune capture quality —
/// they're config, not destinations.
enum HubSection: CaseIterable {
    // Console
    case dictations, meetings, ask
    // Settings
    case dictationSettings, meetingSettings, intelligence, dictionary, snippets,
         privacy, general

    var title: String {
        switch self {
        case .dictations: return "Dictations"
        case .meetings: return "Meetings"
        case .ask: return "Ask"
        case .dictationSettings: return "Dictation"
        case .meetingSettings: return "Meetings"
        case .intelligence: return "Intelligence"
        case .dictionary: return "Dictionary"
        case .snippets: return "Snippets"
        case .privacy: return "Privacy & Data"
        case .general: return "General"
        }
    }

    var icon: String {
        switch self {
        case .dictations: return "waveform"
        case .meetings: return "person.2"
        case .ask: return "magnifyingglass"
        case .dictationSettings: return "mic"
        case .meetingSettings: return "person.wave.2"
        case .intelligence: return "sparkles"
        case .dictionary: return "character.book.closed"
        case .snippets: return "chevron.left.forwardslash.chevron.right"
        case .privacy: return "lock.shield"
        case .general: return "gearshape"
        }
    }

    var isConsole: Bool {
        switch self {
        case .dictations, .meetings, .ask: return true
        default: return false
        }
    }
}

/// Cross-window navigation target for the single hub window. Menu items set
/// this before showing the window, so an already-open hub navigates reactively.
@MainActor
final class HubState: ObservableObject {
    static let shared = HubState()
    @Published var section: HubSection = .dictations
    private init() {}
}

// MARK: - Live permission / connection health

/// Polls the five readiness signals. Feeds the calm status pill — not a
/// permanent dashboard. Permanence isn't importance: these are true 99% of
/// the time, so they only get to shout when something actually breaks.
@MainActor
final class PermissionHealth: ObservableObject {
    @Published var mic: Permissions.Status = .notDetermined
    @Published var accessibility: Permissions.Status = .denied
    @Published var inputMonitoring: Permissions.Status = .notDetermined
    @Published var systemAudio = false
    @Published var claudeReady = false

    private var timer: Timer?

    var okCount: Int {
        [mic == .granted, accessibility == .granted, inputMonitoring == .granted,
         systemAudio, claudeReady].filter { $0 }.count
    }
    var allClear: Bool { okCount == 5 }

    /// Short label for the amber pill — the first (most capture-critical) gap.
    var firstGap: String? {
        if mic != .granted { return "Microphone needed" }
        if accessibility != .granted { return "Accessibility needed" }
        if inputMonitoring != .granted { return "Input monitoring needed" }
        if !systemAudio { return "System audio needed" }
        if !claudeReady { return "Claude engine needs sign-in" }
        return nil
    }

    func refresh() {
        mic = Permissions.microphone
        accessibility = Permissions.accessibility
        inputMonitoring = Permissions.inputMonitoring
        systemAudio = Permissions.systemAudioLikelyGranted
        let s = SettingsStore.shared
        claudeReady = s.data.claudeMode == .cli
            ? (ClaudeService.shared.cliPath() != nil && ClaudeService.shared.cliAuthOK())
            : ((s.apiKey ?? "").isEmpty == false)
    }

    func start() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func stop() { timer?.invalidate(); timer = nil }
}

// MARK: - Root

struct HubView: View {
    @EnvironmentObject var settings: SettingsStore
    @ObservedObject private var hub = HubState.shared
    @StateObject private var health = PermissionHealth()

    var body: some View {
        HStack(spacing: 0) {
            HubSidebar(selection: $hub.section)
                .frame(width: 236)
            Rectangle().fill(Theme.hairline(0.06)).frame(width: 1)
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Theme.surface1)
        }
        .frame(minWidth: 960, minHeight: 600)
        .background(Theme.bgApp)
        .environment(\.colorScheme, .dark)
        .environmentObject(health)
        .onAppear { health.start() }
        .onDisappear { health.stop() }
    }

    // Console screens own their scrolling and fill the pane; settings panes
    // sit in a scroll view with padding.
    @ViewBuilder private var detail: some View {
        switch hub.section {
        case .dictations: DictationsView().environmentObject(settings)
        case .meetings:   MeetingsView().environmentObject(settings)
        case .ask:        AskView()
        default:
            ScrollView {
                settingsPane
                    .padding(24)
                    .frame(maxWidth: 860, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    @ViewBuilder private var settingsPane: some View {
        switch hub.section {
        case .dictionary:       DictionaryPane()
        case .snippets:         SnippetsPane()
        case .dictationSettings: DictationPane()
        case .meetingSettings:  MeetingsPane()
        case .intelligence:     IntelligencePane(health: health)
        case .privacy:          PrivacyPane(health: health)
        case .general:          GeneralPane()
        default:                EmptyView()
        }
    }
}

// MARK: - Sidebar

private struct HubSidebar: View {
    @Binding var selection: HubSection

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            group("CONSOLE", [.dictations, .meetings, .ask])
                .padding(.top, 14)
            group("SETTINGS", [.dictationSettings, .meetingSettings, .intelligence,
                               .dictionary, .snippets, .privacy, .general])
                .padding(.top, 22)
            Spacer(minLength: 12)
            footer
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Theme.bgSidebar)
    }

    private func group(_ label: String, _ sections: [HubSection]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Eyebrow(text: label, size: 10, tracking: 2.2, color: Theme.textMono)
                .padding(.horizontal, 22)
                .padding(.bottom, 7)
            ForEach(sections, id: \.self) { section in
                SidebarItem(section: section, selection: $selection)
            }
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 10) {
            Rectangle().fill(Theme.hairline(0.06)).frame(height: 1)
            HStack(alignment: .top, spacing: 8) {
                GlowDot(color: Theme.green, size: 7)
                    .padding(.top, 3)
                Text("Local-first · nothing\nleaves this Mac")
                    .font(Theme.display(12))
                    .foregroundStyle(Theme.textDim2)
                    .lineSpacing(2)
            }
            .padding(.horizontal, 22)
            Text("RADIO OPERATOR \(Theme.version)")
                .font(Theme.mono(10))
                .tracking(0.5)
                .foregroundStyle(Theme.textGhost)
                .padding(.horizontal, 37)
                .padding(.bottom, 12)
        }
    }
}

private struct SidebarItem: View {
    let section: HubSection
    @Binding var selection: HubSection

    @State private var hovering = false

    private var on: Bool { selection == section }

    var body: some View {
        Button { selection = section } label: {
            ZStack(alignment: .leading) {
                HStack(spacing: 11) {
                    Image(systemName: section.icon)
                        .font(.system(size: 13.5, weight: .medium))
                        .frame(width: 18)
                    Text(section.title)
                        .font(Theme.display(13.5, .medium))
                    Spacer(minLength: 0)
                }
                .foregroundStyle(on ? Theme.textMax : Theme.sidebarIdle)
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(on ? Color.white.opacity(0.065)
                              : (hovering ? Color.white.opacity(0.03) : .clear)))
                .padding(.horizontal, 10)
                // 3×16 green accent bar flush to the sidebar's left edge.
                UnevenRoundedRectangle(cornerRadii: .init(
                    topLeading: 0, bottomLeading: 0, bottomTrailing: 3, topTrailing: 3))
                    .fill(on ? Theme.green : .clear)
                    .frame(width: 3, height: 16)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

// MARK: - Status pill (the demoted five-LED bar)

/// One calm signal that escalates instead of decorating. Default: a small
/// green "Ready" pill. On click: a checklist popover. Amber only when a
/// permission gap actually needs the user.
struct StatusPill: View {
    @ObservedObject var health: PermissionHealth
    /// Navigate the hub (Claude sign-in lives in Intelligence).
    var navigate: (HubSection) -> Void = { HubState.shared.section = $0 }

    @State private var open = false

    var body: some View {
        Button { open.toggle() } label: {
            HStack(spacing: 7) {
                if health.allClear {
                    GlowDot(color: Theme.green, size: 7)
                    Text("Ready")
                        .font(Theme.display(12.5))
                        .foregroundStyle(Theme.textBody)
                } else {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.amber)
                    Text(health.firstGap ?? "Needs attention")
                        .font(Theme.display(12.5))
                        .foregroundStyle(Theme.amber)
                    Text("Fix")
                        .font(Theme.display(12.5, .medium))
                        .underline()
                        .foregroundStyle(Theme.amber)
                }
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(Theme.textMono)
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(Color.white.opacity(0.03), in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9)
                .strokeBorder(health.allClear ? Theme.hairline(0.09)
                              : Theme.amber.opacity(0.35), lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .popover(isPresented: $open, arrowEdge: .bottom) {
            StatusPopover(health: health) { section in
                open = false
                navigate(section)
            }
        }
    }
}

private struct StatusPopover: View {
    @ObservedObject var health: PermissionHealth
    var navigate: (HubSection) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                HStack(spacing: 7) {
                    GlowDot(color: health.allClear ? Theme.green : Theme.amber, size: 6)
                    Eyebrow(text: health.allClear ? "ALL SYSTEMS CLEAR" : "NEEDS ATTENTION",
                            size: 10, tracking: 1.6,
                            color: health.allClear ? Theme.green : Theme.amber)
                }
                Spacer()
                Text("\(health.okCount)/5")
                    .font(Theme.mono(10))
                    .foregroundStyle(Theme.textMono)
            }
            .padding(.horizontal, 14).padding(.vertical, 11)
            Rectangle().fill(Theme.hairline(0.07)).frame(height: 1)

            VStack(spacing: 0) {
                row("Microphone", ok: health.mic == .granted, okLabel: "GRANTED") { fixMic() }
                row("Accessibility", ok: health.accessibility == .granted, okLabel: "GRANTED") {
                    Permissions.promptAccessibility()
                    Permissions.openSettings(pane: Permissions.accessibilityPane)
                }
                row("Input monitoring", ok: health.inputMonitoring == .granted, okLabel: "GRANTED") {
                    Permissions.requestInputMonitoring()
                    Permissions.openSettings(pane: Permissions.inputMonitoringPane)
                }
                row("System audio", ok: health.systemAudio, okLabel: "READY") {
                    Permissions.openSettings(pane: Permissions.audioCapturePane)
                }
                row("Claude engine", ok: health.claudeReady, okLabel: "READY") {
                    navigate(.intelligence)
                }
            }
            .padding(.vertical, 4)

            Rectangle().fill(Theme.hairline(0.07)).frame(height: 1)
            Text("Capture and transcription run on this Mac. You'll only see this open when something needs you.")
                .font(Theme.display(11))
                .foregroundStyle(Theme.textMeta)
                .lineSpacing(2)
                .padding(.horizontal, 14).padding(.vertical, 10)
        }
        .frame(width: 274)
        .background(Theme.surfacePop)
        .environment(\.colorScheme, .dark)
    }

    private func row(_ name: String, ok: Bool, okLabel: String,
                     fix: @escaping () -> Void) -> some View {
        HStack(spacing: 9) {
            Image(systemName: ok ? "checkmark" : "exclamationmark.triangle.fill")
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(ok ? Theme.green : Theme.amber)
                .frame(width: 16)
            Text(name)
                .font(Theme.display(12.5))
                .foregroundStyle(Theme.textBody)
            Spacer()
            if ok {
                Text(okLabel)
                    .font(Theme.mono(9.5, .medium))
                    .tracking(0.8)
                    .foregroundStyle(Theme.textMono)
            } else {
                Button("Fix", action: fix)
                    .buttonStyle(.plain)
                    .font(Theme.display(11.5, .medium))
                    .foregroundStyle(Theme.amber)
                    .underline()
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 6.5)
    }

    private func fixMic() {
        switch Permissions.microphone {
        case .notDetermined:
            Task { _ = await Permissions.requestMicrophone(); health.refresh() }
        default:
            Permissions.openSettings(pane: Permissions.microphonePane)
        }
    }
}
