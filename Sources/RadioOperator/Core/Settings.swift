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
        case .light: return "Light — fillers only"
        case .standard: return "Standard — fillers + dictionary + snippets"
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
    var echoGuard: Bool = false
    /// Persistent UID of the preferred input device; nil = system default.
    var micDeviceUID: String? = nil

    static var defaultNotesFolder: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/Radio Operator").path
    }

    init() {}

    // Resilient decoding: missing keys fall back to defaults so settings
    // survive schema evolution across versions.
    enum CodingKeys: String, CodingKey {
        case holdHotkey, cleanupLevel, dictionary, snippets, notesFolderPath
        case retainAudio, claudeMode, claudeCLIModel, apiModel
        case smartLeadingSpace, hasCompletedOnboarding, echoGuard, micDeviceUID
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
        echoGuard = (try? c.decodeIfPresent(Bool.self, forKey: .echoGuard)) ?? d.echoGuard
        micDeviceUID = (try? c.decodeIfPresent(String.self, forKey: .micDeviceUID)) ?? d.micDeviceUID
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
            SecItemAdd(add as CFDictionary, nil)
            objectWillChange.send()
        }
    }
}
