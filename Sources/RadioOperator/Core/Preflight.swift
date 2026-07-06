import Foundation

/// First-run robustness: turns the app's silent assumptions — speech model
/// present, permissions granted, Claude CLI on PATH and signed in, notes
/// folder writable, disk not full — into explicit, degradable checks that
/// onboarding can show as a System Check card.
///
/// Split on purpose: `gatherInputs()` touches the live system (MainActor);
/// `report(_:)` is PURE aggregation over those raw inputs, so the verdict
/// matrix is unit-tested in the core tier without hardware or TCC.
struct PreflightReport: Equatable {
    struct Check: Equatable, Identifiable {
        enum Kind: String, CaseIterable {
            case speechModel, microphone, accessibility, inputMonitoring
            case claudeCLI, claudeAuth, notesFolder, diskSpace
        }
        /// fail = a core feature is broken; warn = degraded or will prompt.
        enum Verdict: Equatable {
            case pass(String)
            case warn(String)
            case fail(String)
        }

        let kind: Kind
        let verdict: Verdict
        var id: Kind { kind }

        var title: String {
            switch kind {
            case .speechModel: return "Speech model"
            case .microphone: return "Microphone"
            case .accessibility: return "Accessibility"
            case .inputMonitoring: return "Input Monitoring"
            case .claudeCLI: return "Claude CLI"
            case .claudeAuth: return "Claude sign-in"
            case .notesFolder: return "Notes folder"
            case .diskSpace: return "Free disk"
            }
        }

        var detail: String {
            switch verdict {
            case .pass(let s), .warn(let s), .fail(let s): return s
            }
        }

        var isPass: Bool { if case .pass = verdict { return true }; return false }
        var isFail: Bool { if case .fail = verdict { return true }; return false }
    }

    let checks: [Check]

    /// Everything dictation needs end-to-end (model + the three TCC grants).
    var dictationReady: Bool {
        let needed: Set<Check.Kind> = [.speechModel, .microphone, .accessibility, .inputMonitoring]
        return checks.filter { needed.contains($0.kind) }.allSatisfy(\.isPass)
    }

    var hasFailure: Bool { checks.contains(where: \.isFail) }

    func check(_ kind: Check.Kind) -> Check? {
        checks.first { $0.kind == kind }
    }
}

enum Preflight {
    /// Raw system facts, decoupled from how they were read so the
    /// aggregation below stays deterministic and offline-testable.
    struct Inputs: Equatable {
        var speechModelAvailable: Bool
        var microphone: Permissions.Status
        var accessibility: Permissions.Status
        var inputMonitoring: Permissions.Status
        var claudeMode: ClaudeMode
        var apiKeyPresent: Bool
        var cliPresent: Bool
        var cliAuthed: Bool
        var notesFolderWritable: Bool
        /// nil = capacity query failed (surfaced as warn, never silently ok).
        var freeDiskBytes: Int64?
    }

    static let minFreeDiskBytes: Int64 = 1_000_000_000

    /// PURE verdict matrix. Permission denials, a missing speech model, an
    /// unwritable notes folder, and a full disk are failures (core features
    /// break); intelligence gaps (no CLI, signed out, no API key) are warns
    /// (the app degrades — dictation still works).
    static func report(_ i: Inputs) -> PreflightReport {
        var checks: [PreflightReport.Check] = []

        checks.append(.init(kind: .speechModel, verdict: i.speechModelAvailable
            ? .pass("On-device model ready")
            : .fail("Speech model unavailable — dictation can't transcribe")))

        checks.append(.init(kind: .microphone, verdict: permissionVerdict(i.microphone)))
        checks.append(.init(kind: .accessibility, verdict: permissionVerdict(i.accessibility)))
        checks.append(.init(kind: .inputMonitoring, verdict: permissionVerdict(i.inputMonitoring)))

        switch i.claudeMode {
        case .api:
            checks.append(.init(kind: .claudeCLI,
                                verdict: .pass("Not needed — API mode")))
            checks.append(.init(kind: .claudeAuth, verdict: i.apiKeyPresent
                ? .pass("API key set")
                : .warn("API mode with no key — summaries and Ask are off")))
        case .cli:
            checks.append(.init(kind: .claudeCLI, verdict: i.cliPresent
                ? .pass("claude binary found")
                : .warn("claude CLI not found — install Claude Code or switch to API mode")))
            if !i.cliPresent {
                checks.append(.init(kind: .claudeAuth,
                                    verdict: .warn("Install the CLI first")))
            } else {
                checks.append(.init(kind: .claudeAuth, verdict: i.cliAuthed
                    ? .pass("Signed in")
                    : .warn("Signed out — run `claude auth login` in Terminal")))
            }
        }

        checks.append(.init(kind: .notesFolder, verdict: i.notesFolderWritable
            ? .pass("Writable")
            : .fail("Notes folder isn't writable — pick another in Settings → Meetings")))

        if let free = i.freeDiskBytes {
            checks.append(.init(kind: .diskSpace, verdict: free >= minFreeDiskBytes
                ? .pass("\(DataFootprint.humanSize(free)) free")
                : .fail("Only \(DataFootprint.humanSize(free)) free — need at least 1 GB")))
        } else {
            checks.append(.init(kind: .diskSpace,
                                verdict: .warn("Couldn't determine free space")))
        }

        return PreflightReport(checks: checks)
    }

    private static func permissionVerdict(_ s: Permissions.Status) -> PreflightReport.Check.Verdict {
        switch s {
        case .granted: return .pass("Granted")
        case .notDetermined: return .warn("Will prompt on first use")
        case .denied: return .fail("Denied — grant it below or in System Settings")
        }
    }

    /// Live read of every input. MainActor: it touches SettingsStore and the
    /// Permissions checks. `cliPath()`/`cliAuthOK()` are cached inside
    /// ClaudeService, so polling this stays cheap after the first call.
    @MainActor
    static func gatherInputs() async -> Inputs {
        let settings = SettingsStore.shared
        let locale = settings.data.transcriptionLocale
        let format = await Transcriber.preferredFormat(locale: locale)

        let notesURL = settings.notesFolderURL // creates the folder if missing
        let writable = FileManager.default.isWritableFile(atPath: notesURL.path)
        let free = (try? notesURL.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage

        return Inputs(
            speechModelAvailable: format != nil,
            microphone: Permissions.microphone,
            accessibility: Permissions.accessibility,
            inputMonitoring: Permissions.inputMonitoring,
            claudeMode: settings.data.claudeMode,
            apiKeyPresent: (settings.apiKey ?? "").isEmpty == false,
            cliPresent: ClaudeService.shared.cliPath() != nil,
            cliAuthed: ClaudeService.shared.cliAuthOK(),
            notesFolderWritable: writable,
            freeDiskBytes: free)
    }

    /// One-call convenience for the UI.
    @MainActor
    static func run() async -> PreflightReport {
        report(await gatherInputs())
    }
}
