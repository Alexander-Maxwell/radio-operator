import SwiftUI
import AppKit

// MARK: - Palette / sections

private enum RO {
    /// Weathered brass: the one identity accent, used sparingly (selection, preview).
    static let accent = Palette.accent
}

enum HubSection: CaseIterable {
    // Console
    case library, ask, dictionary, snippets
    // Settings
    case dictation, meetings, intelligence, privacy, general

    var title: String {
        switch self {
        case .library: return "Library"
        case .ask: return "Ask"
        case .dictionary: return "Dictionary"
        case .snippets: return "Snippets"
        case .dictation: return "Dictation"
        case .meetings: return "Meetings"
        case .intelligence: return "Intelligence"
        case .privacy: return "Privacy & Data"
        case .general: return "General"
        }
    }
    var icon: String {
        switch self {
        case .library: return "clock.arrow.circlepath"
        case .ask: return "text.magnifyingglass"
        case .dictionary: return "character.book.closed"
        case .snippets: return "text.badge.plus"
        case .dictation: return "waveform"
        case .meetings: return "person.wave.2"
        case .intelligence: return "sparkles"
        case .privacy: return "lock.shield"
        case .general: return "gearshape"
        }
    }
}

/// Cross-window navigation target for the single hub window. Menu items set
/// this before showing the window, so an already-open hub navigates reactively.
@MainActor
final class HubState: ObservableObject {
    static let shared = HubState()
    @Published var section: HubSection = .library
    private init() {}
}

// MARK: - Live permission / connection health (the trust ribbon)

@MainActor
final class PermissionHealth: ObservableObject {
    @Published var mic: Permissions.Status = .notDetermined
    @Published var accessibility: Permissions.Status = .denied
    @Published var inputMonitoring: Permissions.Status = .notDetermined
    @Published var systemAudio = false
    @Published var claudeReady = false

    private var timer: Timer?

    func refresh() {
        mic = Permissions.microphone
        accessibility = Permissions.accessibility
        inputMonitoring = Permissions.inputMonitoring
        systemAudio = Permissions.systemAudioLikelyGranted
        let s = SettingsStore.shared
        claudeReady = s.data.claudeMode == .cli
            ? (ClaudeService.shared.cliPath() != nil)
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
        VStack(spacing: 0) {
            StatusRibbon(health: health) { hub.section = $0 }
            Divider()
            HStack(spacing: 0) {
                sidebar.frame(width: 208)
                Divider()
                detail.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 860, minHeight: 560)
        .onAppear { health.start() }
        .onDisappear { health.stop() }
    }

    // Library and Ask own their scrolling and fill the pane; settings panes
    // sit in a scroll view with padding.
    @ViewBuilder private var detail: some View {
        switch hub.section {
        case .library: LibraryView().environmentObject(settings)
        case .ask:     AskView()
        default:
            ScrollView {
                settingsPane
                    .padding(20)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    @ViewBuilder private var settingsPane: some View {
        switch hub.section {
        case .dictionary:   DictionaryPane()
        case .snippets:     SnippetsPane()
        case .dictation:    DictationPane()
        case .meetings:     MeetingsPane()
        case .intelligence: IntelligencePane(health: health)
        case .privacy:      PrivacyPane(health: health)
        case .general:      GeneralPane()
        default:            EmptyView()
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            sidebarLabel("CONSOLE")
            SidebarButton(section: .library, selection: $hub.section)
            SidebarButton(section: .ask, selection: $hub.section)
            SidebarButton(section: .dictionary, selection: $hub.section)
            SidebarButton(section: .snippets, selection: $hub.section)
            sidebarLabel("SETTINGS").padding(.top, 10)
            SidebarButton(section: .dictation, selection: $hub.section)
            SidebarButton(section: .meetings, selection: $hub.section)
            SidebarButton(section: .intelligence, selection: $hub.section)
            SidebarButton(section: .privacy, selection: $hub.section)
            SidebarButton(section: .general, selection: $hub.section)
            Spacer()
            Divider()
            HStack(spacing: 6) {
                Circle().fill(.green).frame(width: 7, height: 7)
                Text("Local-first · nothing leaves this Mac")
                    .font(.system(size: 10.5)).foregroundStyle(.secondary)
            }
            .padding(.top, 8)
            Text("Radio Operator 0.3.0")
                .font(.system(size: 10, design: .monospaced)).foregroundStyle(.tertiary)
        }
        .padding(12)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color(nsColor: .underPageBackgroundColor).opacity(0.5))
    }

    private func sidebarLabel(_ s: String) -> some View {
        Text(s).font(.system(size: 9.5, weight: .semibold, design: .monospaced))
            .tracking(1.5).foregroundStyle(.tertiary)
            .padding(.horizontal, 9).padding(.bottom, 2)
    }
}

// MARK: - Status ribbon

private struct StatusRibbon: View {
    @ObservedObject var health: PermissionHealth
    var navigate: (HubSection) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                Text("SIGNAL")
                    .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                    .tracking(1.6).foregroundStyle(.tertiary)
                statusChip("MIC", health.mic) { fixMic() }
                statusChip("ACCESS", health.accessibility) { fixAccessibility() }
                statusChip("INPUT MON", health.inputMonitoring) { fixInput() }
                boolChip("SYS AUDIO", health.systemAudio) {
                    Permissions.openSettings(pane: Permissions.audioCapturePane)
                }
                boolChip("CLAUDE", health.claudeReady) { navigate(.intelligence) }
            }
            .padding(.horizontal, 14).padding(.vertical, 9)
        }
    }

    @ViewBuilder
    private func statusChip(_ key: String, _ status: Permissions.Status,
                            fix: @escaping () -> Void) -> some View {
        RibbonChip(key: key, color: lampColor(status), ok: status == .granted,
                   value: "Granted", onFix: fix)
    }

    @ViewBuilder
    private func boolChip(_ key: String, _ ok: Bool, fix: @escaping () -> Void) -> some View {
        RibbonChip(key: key, color: ok ? .green : .orange, ok: ok,
                   value: "Ready", onFix: fix)
    }

    private func lampColor(_ s: Permissions.Status) -> Color {
        switch s {
        case .granted: return .green
        case .denied: return .red
        case .notDetermined: return .orange
        }
    }

    private func fixMic() {
        switch Permissions.microphone {
        case .notDetermined:
            Task { _ = await Permissions.requestMicrophone(); health.refresh() }
        default:
            Permissions.openSettings(pane: Permissions.microphonePane)
        }
    }
    private func fixAccessibility() {
        Permissions.promptAccessibility()
        Permissions.openSettings(pane: Permissions.accessibilityPane)
    }
    private func fixInput() {
        Permissions.requestInputMonitoring()
        Permissions.openSettings(pane: Permissions.inputMonitoringPane)
    }
}

private struct RibbonChip: View {
    let key: String
    let color: Color
    let ok: Bool
    let value: String
    var onFix: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 7) {
            Circle().fill(color).frame(width: 8, height: 8)
                .shadow(color: color.opacity(0.6), radius: 2.5)
            Text(key).font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(.secondary)
            if ok {
                Text(value).font(.system(size: 10.5)).foregroundStyle(.tertiary)
            } else if let onFix {
                Button("Fix", action: onFix)
                    .buttonStyle(.borderedProminent).controlSize(.mini).tint(.orange)
            }
        }
        .padding(.horizontal, 9).padding(.vertical, 5)
        .background(Capsule().fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(Capsule().strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1))
    }
}

// MARK: - Reusable building blocks

private struct SidebarButton: View {
    let section: HubSection
    @Binding var selection: HubSection

    var body: some View {
        Button { selection = section } label: {
            HStack(spacing: 10) {
                Image(systemName: section.icon)
                    .foregroundStyle(selection == section ? RO.accent : Color.secondary)
                    .frame(width: 18)
                Text(section.title).font(.system(size: 13))
                Spacer()
            }
            .padding(.horizontal, 9).padding(.vertical, 7)
            .contentShape(Rectangle())
            .background(RoundedRectangle(cornerRadius: 7)
                .fill(selection == section ? RO.accent.opacity(0.16) : Color.clear))
        }
        .buttonStyle(.plain)
        .foregroundStyle(selection == section ? Color.primary : Color.secondary)
    }
}

private struct PaneHeader: View {
    let title: String
    let badge: String
    let sub: String
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.system(size: 21, weight: .semibold))
                Spacer()
                Text(badge).font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .tracking(1).foregroundStyle(.tertiary)
            }
            Text(sub).font(.system(size: 12.5)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct Card<Content: View>: View {
    let title: String
    var hint: String? = nil
    @ViewBuilder var content: Content

    init(title: String, hint: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title; self.hint = hint; self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(title.uppercased())
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .tracking(1.2).foregroundStyle(.secondary)
                Spacer()
                if let hint {
                    Text(hint).font(.system(size: 11)).foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 9)
            Divider()
            content
        }
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color(nsColor: .separatorColor), lineWidth: 1))
    }
}

private struct SettingRow<Control: View>: View {
    let title: String
    var desc: String? = nil
    @ViewBuilder var control: Control

    init(title: String, desc: String? = nil, @ViewBuilder control: () -> Control) {
        self.title = title; self.desc = desc; self.control = control()
    }

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13))
                if let desc {
                    Text(desc).font(.system(size: 11.5)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            control
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }
}

// MARK: - Dictation pane

private struct DictationPane: View {
    @EnvironmentObject var settings: SettingsStore
    @State private var previewRaw =
        "so um, i think we should, like, launch the sip program on monday. new line follow up with the bevmo vendor and, you know, confirm gopuff pricing"
    @State private var inputDevices: [AudioInputDevices.Device] = []

    private var cleaned: String { CleanupEngine.clean(previewRaw, settings: settings.data) }

    private var deviceWarning: String {
        if let uid = settings.data.micDeviceUID, AudioInputDevices.device(forUID: uid) == nil {
            return "This microphone isn't connected right now — the system default is used until it returns."
        }
        return "Used for dictation and the “Me” side of meetings. Takes effect immediately, even mid-recording."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            PaneHeader(title: "Dictation", badge: "HOLD & SPEAK",
                       sub: "Hold your key, speak anywhere, release to paste. Transcribed on-device and cleaned deterministically, so text lands instantly with no model in the hot path.")

            Card(title: "Cleanup preview", hint: "runs the real engine live") {
                VStack(alignment: .leading, spacing: 8) {
                    miniLabel("YOU SAID (RAW)")
                    TextEditor(text: $previewRaw)
                        .font(.system(size: 12.5)).frame(height: 62)
                        .scrollContentBackground(.hidden)
                        .padding(7)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor)))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(nsColor: .separatorColor), lineWidth: 1))
                    miniLabel("PASTED (CLEANED)")
                    Text(cleaned.isEmpty ? "—" : cleaned)
                        .font(.system(size: 12.5)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, minHeight: 40, alignment: .topLeading)
                        .padding(9)
                        .background(RoundedRectangle(cornerRadius: 8).fill(RO.accent.opacity(0.09)))
                }
                .padding(14)
                Divider()
                SettingRow(title: "Cleanup level",
                           desc: "Fillers and voice commands are always safe; Standard also applies your dictionary and snippets.") {
                    Picker("", selection: $settings.data.cleanupLevel) {
                        ForEach(CleanupLevel.allCases, id: \.self) { Text($0.displayName).tag($0) }
                    }
                    .labelsHidden().frame(maxWidth: 280)
                }
            }

            Card(title: "Hold-to-talk") {
                VStack(spacing: 0) {
                    SettingRow(title: "Hold-to-talk key",
                               desc: "Right ⌘ reports press and release cleanly on every keyboard. Double-tap to lock hands-free; Esc cancels.") {
                        Picker("", selection: $settings.data.holdHotkey) {
                            ForEach(HoldHotkey.allCases, id: \.self) { Text($0.displayName).tag($0) }
                        }
                        .labelsHidden().frame(width: 150)
                        .onChange(of: settings.data.holdHotkey) { DictationController.shared.hotkeys.restart() }
                    }
                    Divider()
                    SettingRow(title: "Smart leading space",
                               desc: "Adds a space before pasted text when the target app needs one.") {
                        Toggle("", isOn: $settings.data.smartLeadingSpace).labelsHidden()
                    }
                }
            }

            Card(title: "Microphone", hint: "input device") {
                SettingRow(title: "Input device", desc: deviceWarning) {
                    HStack(spacing: 6) {
                        Picker("", selection: micBinding) {
                            Text("System default").tag("")
                            ForEach(inputDevices) { Text($0.name).tag($0.uid) }
                        }
                        .labelsHidden().frame(width: 200)
                        Button { inputDevices = AudioInputDevices.list() } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .buttonStyle(.borderless).help("Rescan input devices")
                    }
                }
            }
            .onAppear { inputDevices = AudioInputDevices.list() }
        }
    }

    private var micBinding: Binding<String> {
        Binding(
            get: { settings.data.micDeviceUID ?? "" },
            set: { v in
                settings.data.micDeviceUID = v.isEmpty ? nil : v
                MicCapture.shared.preferredDeviceUID = settings.data.micDeviceUID
            })
    }

    private func miniLabel(_ s: String) -> some View {
        Text(s).font(.system(size: 9.5, weight: .semibold, design: .monospaced))
            .tracking(1).foregroundStyle(.tertiary)
    }
}

// MARK: - Dictionary & Snippets panes (promoted to the Console sidebar)

/// Shared trash button for editable rows.
private func editRemove(_ action: @escaping () -> Void) -> some View {
    Button(action: action) { Image(systemName: "trash") }.buttonStyle(.borderless).help("Remove")
}

/// Shared "add row" button.
private func editAdd(_ title: String, _ action: @escaping () -> Void) -> some View {
    Button(action: action) { Label(title, systemImage: "plus") }
        .buttonStyle(.borderless).padding(.horizontal, 14).padding(.vertical, 8)
}

private struct DictionaryPane: View {
    @EnvironmentObject var settings: SettingsStore

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            PaneHeader(title: "Dictionary", badge: "SPOKEN → WRITTEN",
                       sub: "Fix names, jargon, and brands the transcriber gets wrong. At Standard cleanup, each spoken form is rewritten to its written form (longest match first).")
            Card(title: "Dictionary", hint: "fix names, jargon, brands") {
                VStack(spacing: 0) {
                    ForEach($settings.data.dictionary) { $entry in
                        HStack(spacing: 8) {
                            TextField("Spoken", text: $entry.spoken)
                            Image(systemName: "arrow.right").foregroundStyle(.secondary)
                            TextField("Written", text: $entry.written)
                            editRemove { settings.data.dictionary.removeAll { $0.id == entry.id } }
                        }
                        .textFieldStyle(.roundedBorder)
                        .padding(.horizontal, 14).padding(.vertical, 6)
                    }
                    if settings.data.dictionary.isEmpty {
                        emptyHint("No words yet. Add one to correct a term the transcriber misses.")
                    }
                    editAdd("Add word") {
                        settings.data.dictionary.append(DictionaryEntry(spoken: "", written: ""))
                    }
                }
            }
        }
    }
}

private struct SnippetsPane: View {
    @EnvironmentObject var settings: SettingsStore

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            PaneHeader(title: "Snippets", badge: "SAY A TRIGGER",
                       sub: "Say a trigger phrase alone and it expands to the full text — signatures, addresses, canned replies. Whole-utterance match only, so normal dictation is untouched.")
            Card(title: "Snippets", hint: "trigger → expansion") {
                VStack(spacing: 0) {
                    ForEach($settings.data.snippets) { $snippet in
                        HStack(alignment: .top, spacing: 8) {
                            TextField("Trigger", text: $snippet.trigger).frame(maxWidth: 150)
                            Image(systemName: "arrow.right").foregroundStyle(.secondary).padding(.top, 4)
                            TextField("Expansion", text: $snippet.expansion, axis: .vertical).lineLimit(1...4)
                            editRemove { settings.data.snippets.removeAll { $0.id == snippet.id } }
                        }
                        .textFieldStyle(.roundedBorder)
                        .padding(.horizontal, 14).padding(.vertical, 6)
                    }
                    if settings.data.snippets.isEmpty {
                        emptyHint("No snippets yet. Add one to expand a spoken trigger into saved text.")
                    }
                    editAdd("Add snippet") {
                        settings.data.snippets.append(Snippet(trigger: "", expansion: ""))
                    }
                }
            }
        }
    }
}

private func emptyHint(_ s: String) -> some View {
    Text(s).font(.system(size: 11.5)).foregroundStyle(.tertiary)
        .padding(.horizontal, 15).padding(.vertical, 10)
}

// MARK: - Meetings pane

private struct MeetingsPane: View {
    @EnvironmentObject var settings: SettingsStore

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            PaneHeader(title: "Meetings", badge: "MIC + SYSTEM AUDIO",
                       sub: "One click captures both sides through a Core Audio tap — no bot joins the call. The note is on disk from second zero, and Claude summarizes the moment you stop.")

            Card(title: "Notes folder", hint: "plain markdown · Obsidian-ready") {
                HStack(spacing: 10) {
                    Text(settings.data.notesFolderPath)
                        .font(.system(size: 12, design: .monospaced))
                        .lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button("Change…", action: chooseFolder)
                    Button("Reveal") {
                        NSWorkspace.shared.open(URL(fileURLWithPath: settings.data.notesFolderPath))
                    }
                }
                .padding(14)
            }

            Card(title: "Capture") {
                VStack(spacing: 0) {
                    SettingRow(title: "Auto-start on call",
                               desc: "Begins capture the moment another app uses your mic — Zoom, Meet, Teams, Slack, FaceTime. Your own dictation never triggers it.") {
                        Toggle("", isOn: $settings.data.autoStartOnMic).labelsHidden()
                    }
                    Divider()
                    SettingRow(title: "Auto-summarize on stop",
                               desc: "Claude drafts Summary, Decisions, and Action Items when you end the meeting.") {
                        Toggle("", isOn: $settings.data.autoSummarize).labelsHidden()
                    }
                    Divider()
                    SettingRow(title: "Echo guard",
                               desc: "Filters the far side out of the “Me” channel. Auto turns on for any speakers (built-in or external); headphones give the cleanest transcript.") {
                        Picker("", selection: $settings.data.echoGuardMode) {
                            ForEach(EchoGuardMode.allCases, id: \.self) { Text($0.displayName).tag($0) }
                        }
                        .pickerStyle(.segmented).labelsHidden().frame(width: 180)
                    }
                    Divider()
                    SettingRow(title: "Cancel speaker echo",
                               desc: "Hardware echo cancellation removes the far side coming through your speakers before it’s transcribed, so it isn’t mislabeled as you. Takes effect next meeting.") {
                        Toggle("", isOn: Binding(
                            get: { settings.data.micEchoCancellation },
                            set: { settings.data.micEchoCancellation = $0
                                   MicCapture.shared.voiceProcessing = $0 })).labelsHidden()
                    }
                    Divider()
                    SettingRow(title: "Keep meeting audio",
                               desc: "Off by default. When on, the .m4a stays local next to the note.") {
                        Toggle("", isOn: $settings.data.retainAudio).labelsHidden()
                    }
                }
            }
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: settings.data.notesFolderPath, isDirectory: true)
        if panel.runModal() == .OK, let url = panel.url { settings.data.notesFolderPath = url.path }
    }
}

// MARK: - Intelligence pane

private struct IntelligencePane: View {
    @EnvironmentObject var settings: SettingsStore
    @ObservedObject var health: PermissionHealth
    @State private var apiKeyDraft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            PaneHeader(title: "Intelligence", badge: "CLAUDE",
                       sub: "Summaries and Ask run on your own Claude subscription through the CLI — no API key, no per-token billing. Add a key only if you want lower latency.")

            Card(title: "Engine") {
                VStack(spacing: 0) {
                    SettingRow(title: "Mode",
                               desc: "CLI uses the claude binary you already have. API calls Anthropic directly with a stored key.") {
                        Picker("", selection: $settings.data.claudeMode) {
                            ForEach(ClaudeMode.allCases, id: \.self) { Text($0.displayName).tag($0) }
                        }
                        .labelsHidden().frame(width: 240)
                        .onChange(of: settings.data.claudeMode) { health.refresh() }
                    }
                    Divider()
                    if settings.data.claudeMode == .cli {
                        SettingRow(title: "Model", desc: "sonnet, haiku, or opus.") {
                            TextField("", text: $settings.data.claudeCLIModel)
                                .textFieldStyle(.roundedBorder).frame(width: 150)
                        }
                        Divider()
                        cliStatus
                    } else {
                        SettingRow(title: "API key", desc: "Stored in your Keychain, never in settings.") {
                            SecureField("sk-ant-…", text: $apiKeyDraft)
                                .textFieldStyle(.roundedBorder).frame(width: 220)
                                .onSubmit {
                                    settings.apiKey = apiKeyDraft.isEmpty ? nil : apiKeyDraft
                                    health.refresh()
                                }
                        }
                        Divider()
                        SettingRow(title: "Model") {
                            TextField("", text: $settings.data.apiModel)
                                .textFieldStyle(.roundedBorder).frame(width: 200)
                        }
                    }
                }
            }

            Card(title: "Summary template", hint: "what Claude produces on stop") {
                VStack(alignment: .leading, spacing: 10) {
                    TextEditor(text: $settings.data.summaryTemplate)
                        .font(.system(size: 12, design: .monospaced)).frame(height: 150)
                        .scrollContentBackground(.hidden)
                        .padding(8)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor)))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(nsColor: .separatorColor), lineWidth: 1))
                    HStack {
                        Text("Notes you jot during a meeting are treated as emphasis and marked ✍️.")
                            .font(.system(size: 11.5)).foregroundStyle(.secondary)
                        Spacer()
                        Button("Reset to default") {
                            settings.data.summaryTemplate = SettingsData.defaultSummaryTemplate
                        }
                    }
                }
                .padding(14)
            }
        }
        .onAppear { apiKeyDraft = settings.apiKey ?? "" }
    }

    @ViewBuilder private var cliStatus: some View {
        HStack(spacing: 8) {
            if let path = ClaudeService.shared.cliPath() {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text("CLI found · \(path)").font(.system(size: 11.5, design: .monospaced))
                    .lineLimit(1).truncationMode(.middle)
            } else {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text("claude CLI not found — install Claude Code or switch to API mode.")
                    .font(.system(size: 11.5))
            }
            Spacer()
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }
}

// MARK: - Privacy & Data pane

private struct PrivacyPane: View {
    @EnvironmentObject var settings: SettingsStore
    @ObservedObject var health: PermissionHealth
    @State private var footprint = DataFootprint.Snapshot.empty
    @State private var confirmClear = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            PaneHeader(title: "Privacy & Data", badge: "YOU OWN THE FILES",
                       sub: "There is no account and no cloud. Everything below lives on this Mac in files you can read, move, or delete yourself.")

            Card(title: "Your data", hint: "this Mac only") {
                VStack(spacing: 0) {
                    HStack(spacing: 0) {
                        StatCell(value: "\(footprint.dictations)", label: "Dictations")
                        Divider().frame(height: 44)
                        StatCell(value: "\(footprint.meetings)", label: "Meetings")
                        Divider().frame(height: 44)
                        StatCell(value: DataFootprint.humanSize(footprint.notesBytes), label: "Notes")
                        Divider().frame(height: 44)
                        StatCell(value: DataFootprint.humanSize(footprint.audioBytes), label: "Audio")
                    }
                    Divider()
                    HStack(spacing: 10) {
                        Text(settings.data.notesFolderPath)
                            .font(.system(size: 12, design: .monospaced))
                            .lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button("Reveal in Finder") {
                            NSWorkspace.shared.open(URL(fileURLWithPath: settings.data.notesFolderPath))
                        }
                    }
                    .padding(14)
                }
            }

            Card(title: "History") {
                VStack(spacing: 0) {
                    SettingRow(title: "Keep dictation history",
                               desc: "History powers the Library and Ask. Pasted dictations are marked concealed so clipboard managers skip them.") {
                        Picker("", selection: $settings.data.historyRetention) {
                            ForEach(HistoryRetention.allCases, id: \.self) { Text($0.displayName).tag($0) }
                        }
                        .labelsHidden().frame(width: 210)
                    }
                    Divider()
                    SettingRow(title: "Clear dictation history now",
                               desc: "Deletes the history database and dictation markdown. Meetings are untouched.") {
                        Button("Clear…", role: .destructive) { confirmClear = true }
                    }
                }
            }

            Card(title: "Permissions", hint: "tap Fix to open the right pane") {
                VStack(spacing: 0) {
                    permRow("Microphone", "Hear you dictate and your side of meetings.",
                            health.mic, pane: Permissions.microphonePane)
                    Divider()
                    permRow("Accessibility", "Pastes text at your cursor. While off, text is copied but not pasted.",
                            health.accessibility, pane: Permissions.accessibilityPane)
                    Divider()
                    permRow("Input Monitoring", "Sees your hold-to-talk key.",
                            health.inputMonitoring, pane: Permissions.inputMonitoringPane)
                    Divider()
                    permBoolRow("System Audio Recording", "Captures the other side of meetings.",
                                health.systemAudio, pane: Permissions.audioCapturePane)
                }
            }
        }
        .onAppear { loadFootprint(); health.refresh() }
        .confirmationDialog("Clear all dictation history?", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("Clear history", role: .destructive) { clearHistory() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently deletes your dictation history and daily logs. Meetings are not affected.")
        }
    }

    private func permRow(_ name: String, _ desc: String, _ status: Permissions.Status, pane: String) -> some View {
        HStack(spacing: 12) {
            Circle().fill(status == .granted ? .green : (status == .denied ? .red : .orange))
                .frame(width: 9, height: 9)
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(.system(size: 13))
                Text(desc).font(.system(size: 11.5)).foregroundStyle(.secondary)
            }
            Spacer()
            permStateView(granted: status == .granted, pane: pane)
        }
        .padding(.horizontal, 14).padding(.vertical, 11)
    }

    private func permBoolRow(_ name: String, _ desc: String, _ ok: Bool, pane: String) -> some View {
        HStack(spacing: 12) {
            Circle().fill(ok ? .green : .orange).frame(width: 9, height: 9)
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(.system(size: 13))
                Text(desc).font(.system(size: 11.5)).foregroundStyle(.secondary)
            }
            Spacer()
            permStateView(granted: ok, pane: pane)
        }
        .padding(.horizontal, 14).padding(.vertical, 11)
    }

    @ViewBuilder
    private func permStateView(granted: Bool, pane: String) -> some View {
        if granted {
            Text("GRANTED").font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                .foregroundStyle(.green)
        } else {
            Button("Fix") { Permissions.openSettings(pane: pane) }
                .buttonStyle(.borderedProminent).controlSize(.small).tint(.orange)
        }
    }

    private func loadFootprint() {
        let meetings = NotesStore.shared.meetingsFolder
        let dict = NotesStore.shared.dictationsFolder
        let audio = NotesStore.shared.audioFolder
        let dictCount = HistoryStore.shared.count()
        let meetCount = NotesStore.shared.listMeetings().count
        Task.detached {
            let notesB = DataFootprint.directorySize(meetings) + DataFootprint.directorySize(dict)
            let audioB = DataFootprint.directorySize(audio)
            await MainActor.run {
                footprint = DataFootprint.Snapshot(
                    dictations: dictCount, meetings: meetCount,
                    notesBytes: notesB, audioBytes: audioB)
            }
        }
    }

    private func clearHistory() {
        HistoryStore.shared.deleteAll()
        let folder = NotesStore.shared.dictationsFolder
        if let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) {
            for f in files where f.pathExtension == "md" { try? FileManager.default.removeItem(at: f) }
        }
        loadFootprint()
    }
}

private struct StatCell: View {
    let value: String
    let label: String
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(value).font(.system(size: 20, weight: .semibold, design: .monospaced))
                .monospacedDigit()
            Text(label.uppercased())
                .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                .tracking(1).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
    }
}

// MARK: - General pane

private struct GeneralPane: View {
    @EnvironmentObject var settings: SettingsStore

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            PaneHeader(title: "General", badge: "APP",
                       sub: "How Radio Operator starts up and how it looks.")

            Card(title: "Startup") {
                SettingRow(title: "Launch at login",
                           desc: "Start quietly in the menu bar when you log in, so the hotkey is live after a reboot.") {
                    Toggle("", isOn: $settings.data.launchAtLogin).labelsHidden()
                        .onChange(of: settings.data.launchAtLogin) {
                            LaunchAtLogin.sync(enabled: settings.data.launchAtLogin)
                        }
                }
            }

            Card(title: "Appearance") {
                SettingRow(title: "Theme", desc: "Auto follows macOS.") {
                    Picker("", selection: $settings.data.appearance) {
                        ForEach(AppearanceMode.allCases, id: \.self) { Text($0.displayName).tag($0) }
                    }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 200)
                    .onChange(of: settings.data.appearance) {
                        Appearance.apply(settings.data.appearance)
                    }
                }
            }
        }
    }
}
