import Foundation
import Combine
import Security

enum HoldHotkey: String, Codable, CaseIterable, Sendable {
    case rightCommand
    case rightOption
    case fn
    case off

    var displayName: String {
        switch self {
        case .rightCommand: return "Hold Right ⌘"
        case .rightOption: return "Hold Right ⌥"
        case .fn: return "Hold Fn (Globe)"
        case .off: return "Off"
        }
    }
}

enum CleanupLevel: String, Codable, CaseIterable, Sendable {
    case off
    case light
    case standard

    var displayName: String {
        switch self {
        case .off: return "Off — raw transcript"
        case .light: return "Light — fillers + voice commands"
        case .standard: return "Standard — fillers, commands, dictionary, snippets"
        }
    }
}

enum HistoryRetention: String, Codable, CaseIterable, Sendable {
    case keep
    case day
    case never

    var displayName: String {
        switch self {
        case .keep: return "Keep everything"
        case .day: return "Auto-delete after 24 hours"
        case .never: return "Don't store history"
        }
    }
}

struct DictionaryEntry: Codable, Identifiable, Hashable, Sendable {
    var id: UUID
    var spoken: String
    var written: String

    init(id: UUID = UUID(), spoken: String, written: String) {
        self.id = id
        self.spoken = spoken
        self.written = written
    }
}

struct Snippet: Codable, Identifiable, Hashable, Sendable {
    var id: UUID
    var trigger: String
    var expansion: String

    init(id: UUID = UUID(), trigger: String, expansion: String) {
        self.id = id
        self.trigger = trigger
        self.expansion = expansion
    }
}

/// A named meeting-summary template (the output spec Claude fills in).
/// Generalizes the old single `summaryTemplate` string: the legacy field
/// migrates into `templates[0]` "Default" on first decode.
struct NamedTemplate: Codable, Identifiable, Hashable, Sendable {
    var id: UUID
    var name: String
    var body: String

    init(id: UUID = UUID(), name: String, body: String) {
        self.id = id
        self.name = name
        self.body = body
    }
}

/// A per-app writing style, keyed on the target app's bundle id (the same
/// identifier dictation history already records). Resolved ONLY for Command
/// Mode transforms and — behind an explicit default-off toggle — meeting
/// summaries. NEVER for dictation: the dictation hot path is deterministic
/// and gains zero work from these rules existing.
struct AppRule: Codable, Identifiable, Hashable, Sendable {
    var id: UUID
    /// Exact bundle id (case-insensitive), or "*" to match any app.
    var bundleID: String
    /// Free-text style instruction, e.g. "formal, no emoji, short sentences".
    var style: String

    init(id: UUID = UUID(), bundleID: String, style: String) {
        self.id = id
        self.bundleID = bundleID
        self.style = style
    }

    static let wildcard = "*"

    /// Pure resolution: first exact (case-insensitive) bundle match wins,
    /// then the first "*" rule; rules with a blank style never match. A nil
    /// bundle id (unknown target, meeting summaries) can only match "*".
    static func resolveStyle(bundleID: String?, rules: [AppRule]) -> String? {
        let usable = rules.filter {
            !$0.style.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        if let bundleID {
            let needle = bundleID.trimmingCharacters(in: .whitespaces).lowercased()
            if !needle.isEmpty,
               let exact = usable.first(where: {
                   $0.bundleID.trimmingCharacters(in: .whitespaces).lowercased() == needle
               }) {
                return exact.style
            }
        }
        if let wild = usable.first(where: {
            $0.bundleID.trimmingCharacters(in: .whitespaces) == wildcard
        }) {
            return wild.style
        }
        return nil
    }
}

enum ClaudeMode: String, Codable, CaseIterable, Sendable {
    case cli
    case api

    var displayName: String {
        switch self {
        case .cli: return "Claude Code CLI (your subscription)"
        case .api: return "Anthropic API (key required)"
        }
    }
}

enum AppearanceMode: String, Codable, CaseIterable, Sendable {
    case system
    case light
    case dark

    var displayName: String {
        switch self {
        case .system: return "Auto"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }
}

enum EchoGuardMode: String, Codable, CaseIterable, Sendable {
    case auto
    case on
    case off

    var displayName: String {
        switch self {
        case .auto: return "Auto"
        case .on: return "On"
        case .off: return "Off"
        }
    }

    /// Whether the transcript assembler should filter the user's own voice out
    /// of the "Them" channel. Auto turns on only when the output is speakers
    /// (own voice leaks through the room into the system tap).
    func resolved(onSpeakers: Bool) -> Bool {
        switch self {
        case .on: return true
        case .off: return false
        case .auto: return onSpeakers
        }
    }
}

struct SettingsData: Codable, Sendable {
    var holdHotkey: HoldHotkey = .rightCommand
    var cleanupLevel: CleanupLevel = .standard
    var dictionary: [DictionaryEntry] = []
    var snippets: [Snippet] = []
    var notesFolderPath: String = SettingsData.defaultNotesFolder
    var retainAudio: Bool = false
    var claudeMode: ClaudeMode = .cli
    var claudeCLIModel: String = "sonnet"
    var apiModel: String = "claude-haiku-4-5"
    var smartLeadingSpace: Bool = true
    var hasCompletedOnboarding: Bool = false
    var echoGuardMode: EchoGuardMode = .auto
    var autoSummarize: Bool = true
    var appearance: AppearanceMode = .system

    /// Named summary templates. Never empty in practice: decode falls back to
    /// one "Default" template, and the legacy single `summaryTemplate` string
    /// migrates into `templates[0]`.
    var summaryTemplates: [NamedTemplate] = [
        NamedTemplate(name: "Default", body: SettingsData.defaultSummaryTemplate),
    ]
    /// Which template summaries use; nil or unknown resolves to the first.
    var selectedTemplateID: UUID? = nil

    /// Per-app writing styles (Command Mode + opt-in summaries; never dictation).
    var appRules: [AppRule] = []
    /// When on, a "*" AppRule's style also shapes meeting summaries. Default
    /// OFF — summaries stay style-free unless explicitly opted in.
    var applyStyleToSummaries: Bool = false
    /// Persistent UID of the preferred input device; nil = system default.
    var micDeviceUID: String? = nil
    var historyRetention: HistoryRetention = .keep
    var launchAtLogin: Bool = false
    /// Auto-start a meeting the instant another app grabs the microphone
    /// (Zoom, Meet, Teams, Slack, FaceTime). We only fire while idle, so our
    /// own dictation or meeting capture never self-triggers.
    var autoStartOnMic: Bool = true
    /// Hardware echo cancellation (Apple Voice-Processing I/O) on the mic, so
    /// the far side coming through the speakers is removed before transcription
    /// and never mislabeled as "Me". OFF by default: VPIO is a duplex unit that
    /// also DUCKS/seizes system OUTPUT (you stop hearing the meeting) and gates
    /// multi-channel mics to silence. The software echo guard already filters
    /// speaker bleed from the transcript without touching the audio you hear.
    /// Opt in only if you record on speakers and accept the output ducking;
    /// headphones make it moot.
    var micEchoCancellation: Bool = false
    /// BCP-47 identifier for the transcription language. No picker UI yet
    /// (D3: English-only for now) — parameterized so the engine isn't
    /// hardcoded and a future picker is pure UI. The default lives in ONE
    /// place: `Transcriber.defaultLocale`.
    var transcriptionLocaleIdentifier: String = Transcriber.defaultLocale.identifier

    /// The resolved transcription locale.
    var transcriptionLocale: Locale { Locale(identifier: transcriptionLocaleIdentifier) }

    /// Hold-to-command key for Command Mode (D6b: single hold modifier,
    /// default Fn). A collision with the dictation hold key resolves to off —
    /// one physical key must never drive two state machines.
    var commandHotkey: HoldHotkey = .fn

    /// The Command Mode key that is actually armed. Pure so the collision
    /// rule is unit-testable.
    static func resolvedCommandHotkey(command: HoldHotkey,
                                      dictation: HoldHotkey) -> HoldHotkey {
        command == dictation ? .off : command
    }

    var resolvedCommandHotkey: HoldHotkey {
        SettingsData.resolvedCommandHotkey(command: commandHotkey, dictation: holdHotkey)
    }

    static var defaultNotesFolder: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/Radio Operator").path
    }

    /// The output spec Claude fills in for a meeting. Editable in Settings;
    /// a blank template falls back to this.
    static let defaultSummaryTemplate = """
    ## Summary
    (3-6 tight bullets of what the meeting covered)

    ## Decisions
    (bullets of decisions actually made; write "- None" if none)

    ## Action Items
    (checkboxes like "- [ ] task — owner, due date"; owner/due only if stated; write "- None" if none)

    ## Follow-ups
    (questions left open and things promised but not yet done; write "- None" if none)
    """

    /// The pre-0.3.0 default (no Follow-ups). A legacy `summaryTemplate` that
    /// still equals this verbatim was never customized, so migration upgrades
    /// it to the current default instead of freezing the old spec forever.
    static let legacyDefaultSummaryTemplate = """
    ## Summary
    (3-6 tight bullets of what the meeting covered)

    ## Decisions
    (bullets of decisions actually made; write "- None" if none)

    ## Action Items
    (checkboxes like "- [ ] task — owner, due date"; owner/due only if stated; write "- None" if none)
    """

    /// Pure selection rule: a known id wins, anything else falls back to the
    /// first template (so a deleted selection can never orphan summaries).
    static func selectedTemplate(in templates: [NamedTemplate], id: UUID?) -> NamedTemplate? {
        if let id, let match = templates.first(where: { $0.id == id }) { return match }
        return templates.first
    }

    var selectedTemplate: NamedTemplate? {
        SettingsData.selectedTemplate(in: summaryTemplates, id: selectedTemplateID)
    }

    /// The template body summaries actually use. Blank/empty template lists
    /// fall back to the built-in default so a summary is never spec-less.
    var activeSummaryTemplateBody: String {
        let body = selectedTemplate?.body ?? ""
        return body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? SettingsData.defaultSummaryTemplate : body
    }

    mutating func setSelectedTemplateBody(_ body: String) {
        guard let sel = selectedTemplate,
              let idx = summaryTemplates.firstIndex(where: { $0.id == sel.id }) else {
            summaryTemplates = [NamedTemplate(name: "Default", body: body)]
            return
        }
        summaryTemplates[idx].body = body
    }

    mutating func setSelectedTemplateName(_ name: String) {
        guard let sel = selectedTemplate,
              let idx = summaryTemplates.firstIndex(where: { $0.id == sel.id }) else { return }
        summaryTemplates[idx].name = name
    }

    init() {}

    // Resilient decoding: missing keys fall back to defaults so settings
    // survive schema evolution across versions.
    enum CodingKeys: String, CodingKey {
        case holdHotkey, cleanupLevel, dictionary, snippets, notesFolderPath
        case retainAudio, claudeMode, claudeCLIModel, apiModel
        case smartLeadingSpace, hasCompletedOnboarding, echoGuardMode, micDeviceUID
        case historyRetention, launchAtLogin
        case autoSummarize, appearance, summaryTemplates, selectedTemplateID
        case appRules, applyStyleToSummaries
        case transcriptionLocaleIdentifier
        case autoStartOnMic, micEchoCancellation
        case commandHotkey
    }

    /// Decode-only keys from retired schema versions (never re-encoded).
    private enum LegacyKeys: String, CodingKey {
        case summaryTemplate
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = SettingsData()
        holdHotkey = (try? c.decodeIfPresent(HoldHotkey.self, forKey: .holdHotkey)) ?? d.holdHotkey
        cleanupLevel = (try? c.decodeIfPresent(CleanupLevel.self, forKey: .cleanupLevel)) ?? d.cleanupLevel
        dictionary = (try? c.decodeIfPresent([DictionaryEntry].self, forKey: .dictionary)) ?? d.dictionary
        snippets = (try? c.decodeIfPresent([Snippet].self, forKey: .snippets)) ?? d.snippets
        notesFolderPath = (try? c.decodeIfPresent(String.self, forKey: .notesFolderPath)) ?? d.notesFolderPath
        retainAudio = (try? c.decodeIfPresent(Bool.self, forKey: .retainAudio)) ?? d.retainAudio
        claudeMode = (try? c.decodeIfPresent(ClaudeMode.self, forKey: .claudeMode)) ?? d.claudeMode
        claudeCLIModel = (try? c.decodeIfPresent(String.self, forKey: .claudeCLIModel)) ?? d.claudeCLIModel
        apiModel = (try? c.decodeIfPresent(String.self, forKey: .apiModel)) ?? d.apiModel
        smartLeadingSpace = (try? c.decodeIfPresent(Bool.self, forKey: .smartLeadingSpace)) ?? d.smartLeadingSpace
        hasCompletedOnboarding = (try? c.decodeIfPresent(Bool.self, forKey: .hasCompletedOnboarding)) ?? d.hasCompletedOnboarding
        echoGuardMode = (try? c.decodeIfPresent(EchoGuardMode.self, forKey: .echoGuardMode)) ?? d.echoGuardMode
        micDeviceUID = (try? c.decodeIfPresent(String.self, forKey: .micDeviceUID)) ?? d.micDeviceUID
        historyRetention = (try? c.decodeIfPresent(HistoryRetention.self, forKey: .historyRetention)) ?? d.historyRetention
        launchAtLogin = (try? c.decodeIfPresent(Bool.self, forKey: .launchAtLogin)) ?? d.launchAtLogin
        autoSummarize = (try? c.decodeIfPresent(Bool.self, forKey: .autoSummarize)) ?? d.autoSummarize
        appearance = (try? c.decodeIfPresent(AppearanceMode.self, forKey: .appearance)) ?? d.appearance
        // Templates, three eras: named list (current) → legacy single string
        // (migrated into templates[0] "Default"; an uncustomized legacy
        // default upgrades to the current default so it gains Follow-ups) →
        // nothing (fresh default).
        if let list = try? c.decodeIfPresent([NamedTemplate].self, forKey: .summaryTemplates),
           !list.isEmpty {
            summaryTemplates = list
        } else if let legacyC = try? decoder.container(keyedBy: LegacyKeys.self),
                  let old = try? legacyC.decodeIfPresent(String.self, forKey: .summaryTemplate),
                  !old.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let body = old == SettingsData.legacyDefaultSummaryTemplate
                ? SettingsData.defaultSummaryTemplate : old
            summaryTemplates = [NamedTemplate(name: "Default", body: body)]
        } else {
            summaryTemplates = d.summaryTemplates
        }
        selectedTemplateID = (try? c.decodeIfPresent(UUID.self, forKey: .selectedTemplateID)) ?? nil
        appRules = (try? c.decodeIfPresent([AppRule].self, forKey: .appRules)) ?? d.appRules
        applyStyleToSummaries = (try? c.decodeIfPresent(Bool.self, forKey: .applyStyleToSummaries))
            ?? d.applyStyleToSummaries
        transcriptionLocaleIdentifier = (try? c.decodeIfPresent(String.self, forKey: .transcriptionLocaleIdentifier))
            ?? d.transcriptionLocaleIdentifier
        autoStartOnMic = (try? c.decodeIfPresent(Bool.self, forKey: .autoStartOnMic)) ?? d.autoStartOnMic
        micEchoCancellation = (try? c.decodeIfPresent(Bool.self, forKey: .micEchoCancellation)) ?? d.micEchoCancellation
        commandHotkey = (try? c.decodeIfPresent(HoldHotkey.self, forKey: .commandHotkey)) ?? d.commandHotkey
    }
}

/// Owns the persisted settings. Main-actor bound; saves are debounced.
@MainActor
final class SettingsStore: ObservableObject {
    static let shared = SettingsStore()

    @Published var data: SettingsData {
        didSet { scheduleSave() }
    }

    private var saveTask: Task<Void, Never>?

    private static var fileURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Radio Operator", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("settings.json")
    }

    private init() {
        if let raw = try? Data(contentsOf: SettingsStore.fileURL),
           let decoded = try? JSONDecoder().decode(SettingsData.self, from: raw) {
            data = decoded
        } else {
            data = SettingsData()
        }
    }

    var notesFolderURL: URL {
        let url = URL(fileURLWithPath: data.notesFolderPath, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func scheduleSave() {
        saveTask?.cancel()
        let snapshot = data
        saveTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            if let encoded = try? enc.encode(snapshot) {
                try? encoded.write(to: SettingsStore.fileURL, options: .atomic)
            }
        }
    }

    func saveNow() {
        saveTask?.cancel()
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let encoded = try? enc.encode(data) {
            try? encoded.write(to: SettingsStore.fileURL, options: .atomic)
        }
    }

    // MARK: - Anthropic API key (Keychain)

    private static let keychainService = "com.warroom.radiooperator"
    private static let keychainAccount = "anthropic-api-key"

    var apiKey: String? {
        get {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: SettingsStore.keychainService,
                kSecAttrAccount as String: SettingsStore.keychainAccount,
                kSecReturnData as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne,
            ]
            var item: CFTypeRef?
            guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
                  let data = item as? Data,
                  let key = String(data: data, encoding: .utf8), !key.isEmpty else { return nil }
            return key
        }
        set {
            let base: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: SettingsStore.keychainService,
                kSecAttrAccount as String: SettingsStore.keychainAccount,
            ]
            SecItemDelete(base as CFDictionary)
            guard let newValue, !newValue.isEmpty else {
                objectWillChange.send()
                return
            }
            var add = base
            add[kSecValueData as String] = Data(newValue.utf8)
            // Stored in the login Keychain as a non-synchronizable generic
            // password: encrypted with the login password, never iCloud-synced.
            // (kSecAttrAccessible protection classes are honored only by the
            // data-protection Keychain, which needs an application-identifier
            // entitlement this self-signed build lacks — so it is not set here.)
            SecItemAdd(add as CFDictionary, nil)
            objectWillChange.send()
        }
    }
}
