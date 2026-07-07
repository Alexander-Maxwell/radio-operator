import SwiftUI
import AppKit

// MARK: - Reusable building blocks

/// 1px internal card divider.
private func cardDivider() -> some View {
    Rectangle().fill(Theme.lift(0.06)).frame(height: 1)
}

/// Pane title block: display title + mono badge, optional trailing accessory
/// (e.g. an add button), and a dim subtitle underneath.
private struct PaneHeader<Accessory: View>: View {
    let title: String
    let badge: String
    let sub: String
    let accessory: Accessory

    init(title: String, badge: String, sub: String,
         @ViewBuilder accessory: () -> Accessory) {
        self.title = title; self.badge = badge; self.sub = sub
        self.accessory = accessory()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(title)
                    .font(Theme.display(20, .semibold))
                    .foregroundStyle(Theme.textMax)
                Spacer()
                Text(badge)
                    .font(Theme.mono(10, .medium))
                    .tracking(1.2)
                    .foregroundStyle(Theme.textMono)
                accessory
            }
            Text(sub)
                .font(Theme.display(12.5))
                .foregroundStyle(Theme.textDim)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

extension PaneHeader where Accessory == EmptyView {
    init(title: String, badge: String, sub: String) {
        self.init(title: title, badge: badge, sub: sub) { EmptyView() }
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
                Eyebrow(text: title.uppercased(), size: 10, tracking: 1.6,
                        color: Theme.textMono)
                Spacer()
                if let hint {
                    Text(hint).font(Theme.display(11)).foregroundStyle(Theme.textGhost)
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            cardDivider()
            content
        }
        .roCard()
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
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(Theme.display(13))
                    .foregroundStyle(Theme.textHi)
                if let desc {
                    Text(desc)
                        .font(Theme.display(11.5))
                        .foregroundStyle(Theme.textFaint)
                        .lineSpacing(1.5)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            control
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }
}

/// TextEditor well: faint fill + hairline, shared by preview and templates.
private struct EditorWell: ViewModifier {
    func body(content: Content) -> some View {
        content
            .scrollContentBackground(.hidden)
            .background(RoundedRectangle(cornerRadius: 8).fill(Theme.lift(0.04)))
            .overlay(RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Theme.hairline(0.08), lineWidth: 1))
    }
}

// MARK: - Dictation pane

struct DictationPane: View {
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
                        .font(Theme.display(12.5))
                        .frame(height: 62)
                        .padding(7)
                        .modifier(EditorWell())
                    miniLabel("PASTED (CLEANED)")
                    Text(cleaned.isEmpty ? "—" : cleaned)
                        .font(Theme.display(12.5))
                        .foregroundStyle(Theme.textHi)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, minHeight: 40, alignment: .topLeading)
                        .padding(9)
                        .background(RoundedRectangle(cornerRadius: 8)
                            .fill(Theme.green.opacity(0.08)))
                }
                .padding(14)
                cardDivider()
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
                    cardDivider()
                    SettingRow(title: "Smart leading space",
                               desc: "Adds a space before pasted text when the target app needs one.") {
                        Toggle("", isOn: $settings.data.smartLeadingSpace).labelsHidden()
                    }
                }
            }

            Card(title: "Command Mode", hint: "hold · speak · release") {
                SettingRow(title: "Hold-to-command key", desc: commandKeyDesc) {
                    Picker("", selection: $settings.data.commandHotkey) {
                        ForEach(HoldHotkey.allCases, id: \.self) { Text($0.displayName).tag($0) }
                    }
                    .labelsHidden().frame(width: 150)
                    .onChange(of: settings.data.commandHotkey) { CommandController.shared.hotkeys.restart() }
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
                        HoverIconButton(systemName: "arrow.clockwise",
                                        help: "Rescan input devices") {
                            inputDevices = AudioInputDevices.list()
                        }
                    }
                }
            }
            .onAppear { inputDevices = AudioInputDevices.list() }
        }
    }

    private var commandKeyDesc: String {
        if settings.data.commandHotkey != .off, settings.data.resolvedCommandHotkey == .off {
            return "This is already the hold-to-talk key — Command Mode stays off until they differ."
        }
        return "Hold, speak an instruction (“make this shorter”), release. The selection is transformed in place; with nothing selected the result lands at your cursor. ⌘Z undoes. Off in terminals and secure fields."
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
        Text(s).font(Theme.mono(9.5, .medium))
            .tracking(1).foregroundStyle(Theme.textMono)
    }
}

// MARK: - Dictionary & Snippets panes (capture-tuning config)

/// Shared trash button for editable rows.
private func editRemove(_ action: @escaping () -> Void) -> some View {
    HoverIconButton(systemName: "trash", help: "Remove", action: action)
}

/// Shared "add row" button.
private func editAdd(_ title: String, _ action: @escaping () -> Void) -> some View {
    Button(action: action) { Label(title, systemImage: "plus") }
        .buttonStyle(DimButtonStyle())
        .padding(.horizontal, 14).padding(.vertical, 10)
}

/// Bordered table shell: 12px radius, hairline, clipped row fills.
private struct TableShell: ViewModifier {
    func body(content: Content) -> some View {
        content
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Theme.hairline(0.08), lineWidth: 1))
    }
}

/// 1px divider between table rows (fainter than card dividers).
private func rowDivider() -> some View {
    Rectangle().fill(Theme.lift(0.04)).frame(height: 1)
}

struct DictionaryPane: View {
    @EnvironmentObject var settings: SettingsStore

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            PaneHeader(title: "Dictionary", badge: "SPOKEN → WRITTEN",
                       sub: "Fix names, jargon, and brands the transcriber gets wrong. At Standard cleanup, each spoken form is rewritten to its written form (longest match first).") {
                Button {
                    settings.data.dictionary.append(DictionaryEntry(spoken: "", written: ""))
                } label: {
                    Label("Add term", systemImage: "plus")
                }
                .buttonStyle(DimButtonStyle())
            }

            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    Eyebrow(text: "WRITTEN TERM", size: 10, tracking: 1.2, color: Theme.textMono)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Eyebrow(text: "SPOKEN FORM", size: 10, tracking: 1.2, color: Theme.textMono)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Color.clear.frame(width: 44, height: 1)
                }
                .padding(.horizontal, 16).padding(.vertical, 10)
                .background(Theme.lift(0.02))
                cardDivider()

                ForEach($settings.data.dictionary) { $entry in
                    DictionaryRow(entry: $entry,
                                  isLast: entry.id == settings.data.dictionary.last?.id) {
                        settings.data.dictionary.removeAll { $0.id == entry.id }
                    }
                }
                if settings.data.dictionary.isEmpty {
                    emptyHint("No words yet. Add one to correct a term the transcriber misses.")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .modifier(TableShell())
        }
    }
}

private struct DictionaryRow: View {
    @Binding var entry: DictionaryEntry
    let isLast: Bool
    let remove: () -> Void

    @State private var hovering = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                TextField("Written", text: $entry.written)
                    .textFieldStyle(.plain)
                    .font(Theme.display(14, .medium))
                    .foregroundStyle(Theme.textHi)
                    .frame(maxWidth: .infinity, alignment: .leading)
                TextField("Spoken", text: $entry.spoken)
                    .textFieldStyle(.plain)
                    .font(Theme.mono(12.5))
                    .foregroundStyle(Theme.textFaint)
                    .frame(maxWidth: .infinity, alignment: .leading)
                editRemove(remove)
                    .opacity(hovering ? 1 : 0)
                    .frame(width: 44, alignment: .trailing)
            }
            .padding(.horizontal, 16).padding(.vertical, 8)
            if !isLast { rowDivider() }
        }
        .background(hovering ? Theme.lift(0.02) : .clear)
        .onHover { hovering = $0 }
    }
}

struct SnippetsPane: View {
    @EnvironmentObject var settings: SettingsStore

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            PaneHeader(title: "Snippets", badge: "SAY A TRIGGER",
                       sub: "Say a trigger phrase alone and it expands to the full text — signatures, addresses, canned replies. Whole-utterance match only, so normal dictation is untouched.") {
                Button {
                    settings.data.snippets.append(Snippet(trigger: "", expansion: ""))
                } label: {
                    Label("Add snippet", systemImage: "plus")
                }
                .buttonStyle(DimButtonStyle())
            }

            VStack(spacing: 0) {
                ForEach($settings.data.snippets) { $snippet in
                    SnippetRow(snippet: $snippet,
                               isLast: snippet.id == settings.data.snippets.last?.id) {
                        settings.data.snippets.removeAll { $0.id == snippet.id }
                    }
                }
                if settings.data.snippets.isEmpty {
                    emptyHint("No snippets yet. Add one to expand a spoken trigger into saved text.")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .modifier(TableShell())
        }
    }
}

private struct SnippetRow: View {
    @Binding var snippet: Snippet
    let isLast: Bool
    let remove: () -> Void

    @State private var hovering = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 14) {
                TextField("Trigger", text: $snippet.trigger)
                    .textFieldStyle(.plain)
                    .font(Theme.mono(12.5))
                    .foregroundStyle(Theme.green)
                    .frame(width: 140, alignment: .leading)
                    .padding(.top, 7)
                Image(systemName: "arrow.right")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.textMono)
                    .padding(.top, 9)
                TextField("Expansion", text: $snippet.expansion, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...4)
                    .font(Theme.display(13))
                    .foregroundStyle(Theme.textBody)
                    .padding(.top, 7)
                editRemove(remove)
                    .opacity(hovering ? 1 : 0)
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
            if !isLast { rowDivider() }
        }
        .background(hovering ? Theme.lift(0.02) : .clear)
        .onHover { hovering = $0 }
    }
}

private func emptyHint(_ s: String) -> some View {
    Text(s).font(Theme.display(11.5)).foregroundStyle(Theme.textMeta)
        .padding(.horizontal, 15).padding(.vertical, 12)
}

// MARK: - Meetings pane

struct MeetingsPane: View {
    @EnvironmentObject var settings: SettingsStore
    @State private var audioMoveStatus: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            PaneHeader(title: "Meetings", badge: "MIC + SYSTEM AUDIO",
                       sub: "One click captures both sides through a Core Audio tap — no bot joins the call. The note is on disk from second zero, and Claude summarizes the moment you stop.")

            Card(title: "Notes folder", hint: "plain markdown · Obsidian-ready") {
                HStack(spacing: 10) {
                    Text(settings.data.notesFolderPath)
                        .font(Theme.mono(12))
                        .foregroundStyle(Theme.textBody)
                        .lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button("Change…", action: chooseFolder)
                        .buttonStyle(DimButtonStyle())
                    Button("Reveal") {
                        NSWorkspace.shared.open(URL(fileURLWithPath: settings.data.notesFolderPath))
                    }
                    .buttonStyle(DimButtonStyle())
                }
                .padding(14)
            }

            Card(title: "Recordings folder", hint: "kept out of the notes vault") {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 10) {
                        Text(settings.data.audioFolderPath)
                            .font(Theme.mono(12))
                            .foregroundStyle(Theme.textBody)
                            .lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button("Change…", action: chooseAudioFolder)
                            .buttonStyle(DimButtonStyle())
                        Button("Reveal") {
                            NSWorkspace.shared.open(settings.audioFolderURL)
                        }
                        .buttonStyle(DimButtonStyle())
                    }
                    .padding(14)
                    if let audioMoveStatus {
                        cardDivider()
                        Text(audioMoveStatus)
                            .font(Theme.display(11.5))
                            .foregroundStyle(Theme.textFaint)
                            .padding(.horizontal, 14).padding(.vertical, 9)
                    }
                }
            }

            Card(title: "Capture") {
                VStack(spacing: 0) {
                    SettingRow(title: "Auto-start on call",
                               desc: "Begins capture the moment another app uses your mic — Zoom, Meet, Teams, Slack, FaceTime. Your own dictation never triggers it.") {
                        Toggle("", isOn: $settings.data.autoStartOnMic).labelsHidden()
                    }
                    cardDivider()
                    SettingRow(title: "Auto-summarize on stop",
                               desc: "Claude drafts Summary, Decisions, Action Items, and Follow-ups when you end the meeting.") {
                        Toggle("", isOn: $settings.data.autoSummarize).labelsHidden()
                    }
                    cardDivider()
                    SettingRow(title: "Summary template",
                               desc: "Which template the summary follows. Edit template contents in Intelligence.") {
                        Picker("", selection: meetingTemplateBinding) {
                            ForEach(settings.data.summaryTemplates) { tpl in
                                Text(tpl.name).tag(Optional(tpl.id))
                            }
                        }
                        .labelsHidden().frame(width: 200)
                    }
                    cardDivider()
                    SettingRow(title: "Echo guard",
                               desc: "Filters the far side out of the “Me” channel. Auto turns on for any speakers (built-in or external); headphones give the cleanest transcript.") {
                        Picker("", selection: $settings.data.echoGuardMode) {
                            ForEach(EchoGuardMode.allCases, id: \.self) { Text($0.displayName).tag($0) }
                        }
                        .pickerStyle(.segmented).labelsHidden().frame(width: 180)
                    }
                    cardDivider()
                    SettingRow(title: "Cancel speaker echo",
                               desc: "Hardware echo cancellation removes the far side coming through your speakers before it’s transcribed, so it isn’t mislabeled as you. Takes effect next meeting.") {
                        Toggle("", isOn: Binding(
                            get: { settings.data.micEchoCancellation },
                            set: { settings.data.micEchoCancellation = $0
                                   MicCapture.shared.voiceProcessing = $0 })).labelsHidden()
                    }
                    cardDivider()
                    SettingRow(title: "Keep meeting audio",
                               desc: "Off by default. When on, both tracks (.m4a) are saved to the Recordings folder above — local, and separate from your notes.") {
                        Toggle("", isOn: $settings.data.retainAudio).labelsHidden()
                    }
                }
            }
        }
    }

    private var meetingTemplateBinding: Binding<UUID?> {
        Binding(
            get: { settings.data.selectedTemplate?.id },
            set: { settings.data.selectedTemplateID = $0 })
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: settings.data.notesFolderPath, isDirectory: true)
        if panel.runModal() == .OK, let url = panel.url { settings.data.notesFolderPath = url.path }
    }

    /// Pick a new recordings archive, then move existing .m4a there so old
    /// meetings' audio still plays and nothing is orphaned.
    private func chooseAudioFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Use Folder"
        panel.message = "Choose where meeting recordings are stored."
        panel.directoryURL = settings.audioFolderURL
        guard panel.runModal() == .OK, let dest = panel.url else { return }
        let old = settings.audioFolderURL
        guard dest.standardizedFileURL != old.standardizedFileURL else { return }
        settings.data.audioFolderPath = dest.path
        audioMoveStatus = "Moving existing recordings…"
        Task.detached(priority: .userInitiated) {
            let moved = NotesStore.relocateAudioFiles(from: old, to: dest)
            await MainActor.run {
                audioMoveStatus = moved == 0
                    ? "New recordings will be saved here."
                    : "Moved \(moved) recording file\(moved == 1 ? "" : "s") here."
            }
        }
    }
}

// MARK: - Intelligence pane

struct IntelligencePane: View {
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
                    cardDivider()
                    if settings.data.claudeMode == .cli {
                        SettingRow(title: "Model", desc: "sonnet, haiku, or opus.") {
                            TextField("", text: $settings.data.claudeCLIModel)
                                .textFieldStyle(.roundedBorder).frame(width: 150)
                        }
                        cardDivider()
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
                        cardDivider()
                        SettingRow(title: "Model") {
                            TextField("", text: $settings.data.apiModel)
                                .textFieldStyle(.roundedBorder).frame(width: 200)
                        }
                    }
                }
            }

            Card(title: "Summary templates", hint: "what Claude produces on stop") {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        Picker("", selection: selectedTemplateBinding) {
                            ForEach(settings.data.summaryTemplates) { tpl in
                                Text(tpl.name).tag(Optional(tpl.id))
                            }
                        }
                        .labelsHidden().frame(width: 170)
                        TextField("Name", text: templateNameBinding)
                            .textFieldStyle(.roundedBorder).frame(width: 150)
                        Spacer()
                        HoverIconButton(systemName: "plus", help: "Add a template") {
                            let tpl = NamedTemplate(name: "New template",
                                                    body: SettingsData.defaultSummaryTemplate)
                            settings.data.summaryTemplates.append(tpl)
                            settings.data.selectedTemplateID = tpl.id
                        }
                        HoverIconButton(systemName: "trash", help: "Delete this template") {
                            guard let sel = settings.data.selectedTemplate else { return }
                            settings.data.summaryTemplates.removeAll { $0.id == sel.id }
                            settings.data.selectedTemplateID = settings.data.summaryTemplates.first?.id
                        }
                        .disabled(settings.data.summaryTemplates.count <= 1)
                    }
                    TextEditor(text: templateBodyBinding)
                        .font(Theme.mono(12)).frame(height: 150)
                        .padding(8)
                        .modifier(EditorWell())
                    HStack {
                        Text("Summaries use the selected template. Notes you jot during a meeting are treated as emphasis and marked ✍️.")
                            .font(Theme.display(11.5)).foregroundStyle(Theme.textFaint)
                        Spacer()
                        Button("Reset to default") {
                            settings.data.setSelectedTemplateBody(SettingsData.defaultSummaryTemplate)
                        }
                        .buttonStyle(DimButtonStyle())
                    }
                }
                .padding(14)
            }

            Card(title: "Per-app writing styles", hint: "Command Mode + opt-in summaries · never dictation") {
                VStack(spacing: 0) {
                    ForEach($settings.data.appRules) { $rule in
                        HStack(spacing: 8) {
                            TextField("Bundle ID (e.g. com.apple.mail) or *", text: $rule.bundleID)
                                .frame(maxWidth: 240)
                            Image(systemName: "arrow.right").foregroundStyle(Theme.textMono)
                            TextField("Style (e.g. formal, no emoji, short sentences)", text: $rule.style)
                            editRemove { settings.data.appRules.removeAll { $0.id == rule.id } }
                        }
                        .textFieldStyle(.roundedBorder)
                        .padding(.horizontal, 14).padding(.vertical, 6)
                    }
                    if settings.data.appRules.isEmpty {
                        emptyHint("No rules yet. Add one to give Command Mode a writing style per app; use * to match every app.")
                    }
                    editAdd("Add rule") {
                        settings.data.appRules.append(AppRule(bundleID: "", style: ""))
                    }
                    cardDivider()
                    SettingRow(title: "Apply to meeting summaries",
                               desc: "Off by default. When on, a * rule's style also shapes meeting summaries. Dictation is never styled — it stays deterministic.") {
                        Toggle("", isOn: $settings.data.applyStyleToSummaries).labelsHidden()
                    }
                }
            }
        }
        .onAppear { apiKeyDraft = settings.apiKey ?? "" }
    }

    /// Selection resolves through the same rule summaries use (unknown/nil →
    /// first), so the picker can never point at a template that isn't used.
    private var selectedTemplateBinding: Binding<UUID?> {
        Binding(
            get: { settings.data.selectedTemplate?.id },
            set: { settings.data.selectedTemplateID = $0 })
    }

    private var templateNameBinding: Binding<String> {
        Binding(
            get: { settings.data.selectedTemplate?.name ?? "" },
            set: { settings.data.setSelectedTemplateName($0) })
    }

    private var templateBodyBinding: Binding<String> {
        Binding(
            get: { settings.data.selectedTemplate?.body ?? "" },
            set: { settings.data.setSelectedTemplateBody($0) })
    }

    @ViewBuilder private var cliStatus: some View {
        HStack(spacing: 8) {
            if let path = ClaudeService.shared.cliPath() {
                if ClaudeService.shared.cliAuthOK() {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.green)
                    Text("CLI found · \(path)").font(Theme.mono(11.5))
                        .foregroundStyle(Theme.textFaint)
                        .lineLimit(1).truncationMode(.middle)
                } else {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.amber)
                    Text("CLI found but signed out — run  claude auth login  in Terminal, then Retry.")
                        .font(Theme.display(11.5)).foregroundStyle(Theme.textBody)
                        .textSelection(.enabled)
                }
            } else {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.amber)
                Text("claude CLI not found — install Claude Code or switch to API mode.")
                    .font(Theme.display(11.5)).foregroundStyle(Theme.textBody)
            }
            Spacer()
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }
}

// MARK: - Privacy & Data pane

struct PrivacyPane: View {
    @EnvironmentObject var settings: SettingsStore
    @ObservedObject var health: PermissionHealth
    @State private var footprint = DataFootprint.Snapshot.empty
    @State private var confirmClear = false
    @State private var diagnosticsStatus: String?
    @State private var confirmPanic = false
    @State private var panicIncludeNotes = false
    @State private var panicStatus: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            PaneHeader(title: "Privacy & Data", badge: "YOU OWN THE FILES",
                       sub: "There is no account and no cloud. Everything below lives on this Mac in files you can read, move, or delete yourself.")

            Card(title: "Your data", hint: "this Mac only") {
                VStack(spacing: 0) {
                    HStack(spacing: 0) {
                        StatCell(value: "\(footprint.dictations)", label: "Dictations")
                        statDivider
                        StatCell(value: "\(footprint.meetings)", label: "Meetings")
                        statDivider
                        StatCell(value: DataFootprint.humanSize(footprint.notesBytes), label: "Notes")
                        statDivider
                        StatCell(value: DataFootprint.humanSize(footprint.audioBytes), label: "Audio")
                    }
                    cardDivider()
                    HStack(spacing: 10) {
                        Text(settings.data.notesFolderPath)
                            .font(Theme.mono(12))
                            .foregroundStyle(Theme.textBody)
                            .lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button("Reveal in Finder") {
                            NSWorkspace.shared.open(URL(fileURLWithPath: settings.data.notesFolderPath))
                        }
                        .buttonStyle(DimButtonStyle())
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
                    cardDivider()
                    SettingRow(title: "Clear dictation history now",
                               desc: "Deletes the history database and dictation markdown. Meetings are untouched.") {
                        destructiveButton("Clear…") { confirmClear = true }
                    }
                }
            }

            Card(title: "Panic wipe", hint: "cryptographic erase · D8") {
                VStack(spacing: 0) {
                    SettingRow(title: "Panic Wipe…",
                               desc: "Clears the history database and destroys its encryption key in your Keychain — every encrypted transcript anywhere becomes permanently unreadable. A fresh key is created at next launch.") {
                        destructiveButton("Panic Wipe…") { confirmPanic = true }
                    }
                    cardDivider()
                    SettingRow(title: "Also delete notes and audio files",
                               desc: "Off by default. When on, the wipe also empties Meetings, Dictations, and Audio — your markdown notes and any retained recordings.") {
                        Toggle("", isOn: $panicIncludeNotes).labelsHidden()
                    }
                    if let panicStatus {
                        cardDivider()
                        Text(panicStatus)
                            .font(Theme.display(11.5)).foregroundStyle(Theme.textFaint)
                            .padding(.horizontal, 14).padding(.vertical, 8)
                    }
                }
            }
            .confirmationDialog(
                panicIncludeNotes
                    ? "Erase dictation history AND delete all notes and audio?"
                    : "Erase all dictation history?",
                isPresented: $confirmPanic, titleVisibility: .visible
            ) {
                Button(panicIncludeNotes ? "Erase history, notes & audio" : "Erase history & key",
                       role: .destructive) { runPanicWipe() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(panicIncludeNotes
                    ? "The history database and its Keychain key are destroyed (nothing recoverable), and everything in Meetings, Dictations, and Audio is deleted. This cannot be undone."
                    : "The history database and its Keychain key are destroyed — no transcript is recoverable, even from copies of the database. Notes and audio files are NOT touched. This cannot be undone.")
            }

            Card(title: "Diagnostics", hint: "local-only · never uploaded") {
                VStack(spacing: 0) {
                    SettingRow(title: "Export Diagnostics…",
                               desc: "Writes the last 24 hours of this app's own log messages (status lines only — dictation content is never logged) to a file you choose. Nothing is transmitted; share it yourself if you want to.") {
                        Button("Export…") { exportDiagnostics() }
                            .buttonStyle(DimButtonStyle())
                    }
                    if let diagnosticsStatus {
                        cardDivider()
                        Text(diagnosticsStatus)
                            .font(Theme.display(11.5)).foregroundStyle(Theme.textFaint)
                            .padding(.horizontal, 14).padding(.vertical, 8)
                    }
                }
            }

            Card(title: "Permissions", hint: "tap Fix to open the right pane") {
                VStack(spacing: 0) {
                    permRow("Microphone", "Hear you dictate and your side of meetings.",
                            health.mic, pane: Permissions.microphonePane)
                    cardDivider()
                    permRow("Accessibility", "Pastes text at your cursor. While off, text is copied but not pasted.",
                            health.accessibility, pane: Permissions.accessibilityPane)
                    cardDivider()
                    permRow("Input Monitoring", "Sees your hold-to-talk key.",
                            health.inputMonitoring, pane: Permissions.inputMonitoringPane)
                    cardDivider()
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

    private var statDivider: some View {
        Rectangle().fill(Theme.lift(0.06)).frame(width: 1, height: 44)
    }

    private func destructiveButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).foregroundStyle(Theme.alertRed)
        }
        .buttonStyle(DimButtonStyle())
    }

    private func permRow(_ name: String, _ desc: String, _ status: Permissions.Status, pane: String) -> some View {
        HStack(spacing: 12) {
            GlowDot(color: status == .granted ? Theme.green
                    : (status == .denied ? Theme.alertRed : Theme.amber), size: 7)
            VStack(alignment: .leading, spacing: 3) {
                Text(name).font(Theme.display(13)).foregroundStyle(Theme.textHi)
                Text(desc).font(Theme.display(11.5)).foregroundStyle(Theme.textFaint)
            }
            Spacer()
            permStateView(granted: status == .granted, pane: pane)
        }
        .padding(.horizontal, 14).padding(.vertical, 11)
    }

    private func permBoolRow(_ name: String, _ desc: String, _ ok: Bool, pane: String) -> some View {
        HStack(spacing: 12) {
            GlowDot(color: ok ? Theme.green : Theme.amber, size: 7)
            VStack(alignment: .leading, spacing: 3) {
                Text(name).font(Theme.display(13)).foregroundStyle(Theme.textHi)
                Text(desc).font(Theme.display(11.5)).foregroundStyle(Theme.textFaint)
            }
            Spacer()
            permStateView(granted: ok, pane: pane)
        }
        .padding(.horizontal, 14).padding(.vertical, 11)
    }

    @ViewBuilder
    private func permStateView(granted: Bool, pane: String) -> some View {
        if granted {
            Text("GRANTED").font(Theme.mono(10, .medium)).tracking(0.8)
                .foregroundStyle(Theme.green)
        } else {
            Button("Fix") { Permissions.openSettings(pane: pane) }
                .buttonStyle(.borderedProminent).controlSize(.small).tint(Theme.amber)
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

    /// Confirmation-gated D8 wipe. Blocking work (VACUUM, file removals)
    /// runs off the main thread; the plan is resolved on the MainActor so
    /// the notes root comes from live settings.
    private func runPanicWipe() {
        let plan = PanicWipe.plan(alsoDeleteNotesAndAudio: panicIncludeNotes,
                                  notesRoot: settings.notesFolderURL)
        let includedNotes = panicIncludeNotes
        panicStatus = "Wiping…"
        Task.detached(priority: .userInitiated) {
            let rekeyed = PanicWipe.execute(plan: plan, history: HistoryStore.shared)
            await MainActor.run {
                let scope = includedNotes
                    ? "History, key, notes, and audio wiped."
                    : "History and key wiped."
                panicStatus = rekeyed
                    ? scope + " A fresh encryption key is active."
                    : scope + " Keychain unavailable — new dictations are UNENCRYPTED until it returns."
                loadFootprint()
            }
        }
    }

    /// Opt-in, local-only: collect this process's app-emitted log entries for
    /// the last 24h and write them wherever the user chooses. No network.
    private func exportDiagnostics() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = DiagnosticsExport.suggestedFilename()
        panel.title = "Export Diagnostics"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        diagnosticsStatus = "Collecting…"
        Task.detached(priority: .userInitiated) {
            let status: String
            do {
                let lines = try DiagnosticsExport.collect()
                let rendered = DiagnosticsExport.render(lines: lines, generatedAt: Date())
                try rendered.write(to: url, atomically: true, encoding: .utf8)
                status = "Exported \(lines.count) log entries to \(url.lastPathComponent). Review before sharing."
            } catch {
                status = "Export failed: \(error.localizedDescription)"
            }
            await MainActor.run { diagnosticsStatus = status }
        }
    }
}

private struct StatCell: View {
    let value: String
    let label: String
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(value).font(Theme.mono(20, .semibold))
                .monospacedDigit()
                .foregroundStyle(Theme.textMax)
            Text(label.uppercased())
                .font(Theme.mono(9.5, .medium))
                .tracking(1).foregroundStyle(Theme.textMeta)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
    }
}

// MARK: - General pane

struct GeneralPane: View {
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
