import SwiftUI
import AppKit

struct SettingsView: View {
    @EnvironmentObject var settings: SettingsStore
    @State private var apiKeyDraft = ""

    var body: some View {
        Form {
            hotkeySection
            cleanupSection
            dictionarySection
            snippetsSection
            meetingsSection
            claudeSection
            aboutSection
        }
        .formStyle(.grouped)
        .frame(minWidth: 540, minHeight: 560)
        .onAppear { apiKeyDraft = settings.apiKey ?? "" }
    }

    // MARK: - Hotkey

    private var hotkeySection: some View {
        Section {
            Picker("Hold-to-talk key", selection: $settings.data.holdHotkey) {
                ForEach(HoldHotkey.allCases, id: \.self) {
                    Text($0.displayName).tag($0)
                }
            }
            .onChange(of: settings.data.holdHotkey) {
                DictationController.shared.hotkeys.restart()
            }
        } header: {
            Text("Hotkey")
        } footer: {
            Text("Hold to talk, release to paste. Press Escape while recording to cancel.")
        }
    }

    // MARK: - Cleanup

    private var cleanupSection: some View {
        Section("Cleanup") {
            Picker("Level", selection: $settings.data.cleanupLevel) {
                ForEach(CleanupLevel.allCases, id: \.self) {
                    Text($0.displayName).tag($0)
                }
            }
            Toggle("Smart leading space", isOn: $settings.data.smartLeadingSpace)
        }
    }

    // MARK: - Dictionary

    private var dictionarySection: some View {
        Section {
            ForEach($settings.data.dictionary) { $entry in
                HStack(spacing: 8) {
                    TextField("Spoken", text: $entry.spoken)
                    Image(systemName: "arrow.right")
                        .foregroundStyle(.secondary)
                    TextField("Written", text: $entry.written)
                    Button {
                        settings.data.dictionary.removeAll { $0.id == entry.id }
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                    .help("Remove")
                }
            }
            Button {
                settings.data.dictionary.append(DictionaryEntry(spoken: "", written: ""))
            } label: {
                Label("Add Word", systemImage: "plus")
            }
        } header: {
            Text("Dictionary")
        } footer: {
            Text("Fix words the transcriber gets wrong — jargon, names, brands.")
        }
    }

    // MARK: - Snippets

    private var snippetsSection: some View {
        Section {
            ForEach($settings.data.snippets) { $snippet in
                HStack(alignment: .top, spacing: 8) {
                    TextField("Trigger", text: $snippet.trigger)
                        .frame(maxWidth: 160)
                    Image(systemName: "arrow.right")
                        .foregroundStyle(.secondary)
                        .padding(.top, 4)
                    TextField("Expansion", text: $snippet.expansion, axis: .vertical)
                        .lineLimit(1...4)
                    Button {
                        settings.data.snippets.removeAll { $0.id == snippet.id }
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                    .help("Remove")
                }
            }
            Button {
                settings.data.snippets.append(Snippet(trigger: "", expansion: ""))
            } label: {
                Label("Add Snippet", systemImage: "plus")
            }
        } header: {
            Text("Snippets")
        } footer: {
            Text("Say a trigger phrase alone to paste the whole snippet.")
        }
    }

    // MARK: - Meetings

    private var meetingsSection: some View {
        Section {
            HStack {
                Text(settings.data.notesFolderPath)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button("Change…", action: chooseNotesFolder)
            }
            Toggle("Keep meeting audio (local only)", isOn: $settings.data.retainAudio)
        } header: {
            Text("Meetings")
        } footer: {
            Text("Notes are plain markdown with YAML frontmatter — point this at an Obsidian vault folder and your meetings appear there.")
        }
    }

    private func chooseNotesFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: settings.data.notesFolderPath, isDirectory: true)
        if panel.runModal() == .OK, let url = panel.url {
            settings.data.notesFolderPath = url.path
        }
    }

    // MARK: - Claude

    private var claudeSection: some View {
        Section("Claude") {
            Picker("Mode", selection: $settings.data.claudeMode) {
                ForEach(ClaudeMode.allCases, id: \.self) {
                    Text($0.displayName).tag($0)
                }
            }
            if settings.data.claudeMode == .cli {
                HStack(spacing: 6) {
                    if let path = ClaudeService.shared.cliPath() {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Text("CLI found: \(path)")
                            .lineLimit(1)
                            .truncationMode(.middle)
                    } else {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text("claude CLI not found")
                    }
                }
                .font(.callout)
                TextField("Model", text: $settings.data.claudeCLIModel)
                Text("sonnet, haiku, or opus")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                SecureField("API key", text: $apiKeyDraft)
                    .onSubmit {
                        settings.apiKey = apiKeyDraft.isEmpty ? nil : apiKeyDraft
                    }
                TextField("Model", text: $settings.data.apiModel)
            }
        }
    }

    // MARK: - About

    private var aboutSection: some View {
        Section("About") {
            LabeledContent("Version", value: "0.1.0")
            Text("Built in the War Room. Local-first: audio and transcripts never leave this Mac unless you ask Claude.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
