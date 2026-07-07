import AppKit
import SwiftUI
import Combine
import UserNotifications

/// What a `radiooperator://` URL asks the app to do. Parsed by the pure
/// `AppDelegate.parseURLCommand(_:)` so the mapping is unit-testable without
/// AppKit. Junk input maps to `.unknown` (a no-op), never a crash.
enum URLCommand: Equatable {
    case dictateToggle
    case meetingStart
    case meetingStop
    case hub(HubSection)
    case unknown
}

@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static func main() {
        if TestRunner.handleIfRequested() { return }
        if ProbeRunner.handleIfRequested() { return }
        if MCPRunner.handleIfRequested() { return }
        ThemeFonts.register()
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }

    private var statusItem: NSStatusItem!
    private var cancellables = Set<AnyCancellable>()
    private var elapsedMenuTimer: Timer?
    private var micActivityMonitor: MicActivityMonitor?

    /// Posted when another app starts using the mic (a call begins). Nonisolated
    /// so the mic monitor's `@Sendable` callback can reference it off the main actor.
    nonisolated static let micActivatedNote = Notification.Name("radiooperator.micActivated")

    /// URL-scheme automation (`radiooperator://…`, Shortcuts-callable via
    /// "Open URLs"). The kAEGetURL handler must be registered here — by
    /// `applicationDidFinishLaunching` a launch-triggering URL event has
    /// already been delivered and would be dropped.
    func applicationWillFinishLaunching(_ notification: Notification) {
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleGetURL(_:withReplyEvent:)),
            forEventClass: AEEventClass(kInternetEventClass),
            andEventID: AEEventID(kAEGetURL))
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = AppDelegate.icon(for: AppState.shared)
        statusItem.menu = buildMenu()

        // Icon reflects the most urgent state; recompute on any state change.
        AppState.shared.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                DispatchQueue.main.async {
                    self?.statusItem.button?.image = AppDelegate.icon(for: AppState.shared)
                    self?.refreshMenuTitles()
                }
            }
            .store(in: &cancellables)

        DictationController.shared.startListening()
        CommandController.shared.startListening()

        // Route capture to the user's chosen microphone (nil = system default).
        MicCapture.shared.preferredDeviceUID = SettingsStore.shared.data.micDeviceUID

        // Voice-Processing I/O (hardware AEC) is a meeting-only concern and is
        // set per-capture-session by the controllers (dictation = off, meeting =
        // the micEchoCancellation setting). Default off so a first dictation
        // before any meeting never inherits it.
        MicCapture.shared.voiceProcessing = false

        // Auto-start a meeting when another app grabs the mic (a call begins).
        let monitor = MicActivityMonitor()
        monitor.onActivated = {
            NotificationCenter.default.post(name: AppDelegate.micActivatedNote, object: nil)
        }
        monitor.start()
        micActivityMonitor = monitor
        NotificationCenter.default.addObserver(
            forName: AppDelegate.micActivatedNote, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.autoStartMeetingIfIdle() }
        }

        // Reconcile the login item with the setting (registration can be
        // dropped externally via System Settings).
        LaunchAtLogin.sync(enabled: SettingsStore.shared.data.launchAtLogin)

        // Honor the saved appearance preference across every window.
        Appearance.apply(SettingsStore.shared.data.appearance)

        // Pre-warm the speech format query so the first hotkey press is fast.
        let prewarmLocale = SettingsStore.shared.data.transcriptionLocale
        Task.detached { _ = await Transcriber.preferredFormat(locale: prewarmLocale) }

        // Warm the history store off the main thread so the Keychain read +
        // one-time encryption sweep + VACUUM never run on the MainActor. The
        // 24-hour retention prune materializes the store too, so fold it into the
        // same detached task — otherwise it would force store init back onto the
        // MainActor. The store is internally serialized, so a concurrent first
        // dictation just waits on its queue.
        let retention = SettingsStore.shared.data.historyRetention
        let dictationsFolder = NotesStore.shared.dictationsFolder
        if retention != .never {
            Task.detached(priority: .utility) {
                if retention == .day {
                    HistoryStore.shared.prune(olderThan: Date(timeIntervalSinceNow: -86_400))
                    NotesStore.pruneDictationLogs(in: dictationsFolder, keepingDays: 1)
                } else {
                    _ = HistoryStore.shared.count()
                }
            }
        }

        // Library empty-state "Start a Meeting" button.
        NotificationCenter.default.addObserver(
            forName: Notification.Name("radiooperator.startMeeting"), object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, !MeetingController.shared.isActive else { return }
                self.toggleMeeting()
            }
        }

        // First launch (or incomplete permissions): open onboarding, visibly.
        if !SettingsStore.shared.data.hasCompletedOnboarding {
            openOnboarding()
        }
    }

    /// Reopening the app (Finder double-click while running) re-presents
    /// onboarding when permissions are incomplete — the "launched into
    /// nothing" fix.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !SettingsStore.shared.data.hasCompletedOnboarding {
            openOnboarding()
        } else {
            openLibrary()
        }
        return true
    }

    /// Quit guard: a live meeting must never die to a stray ⌘Q.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard MeetingController.shared.isActive else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "A meeting is being recorded"
        alert.informativeText = "Stop the meeting and save the transcript before quitting?"
        alert.addButton(withTitle: "Stop Meeting & Quit")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            MeetingController.shared.stop()
            // Give the stop path a moment to flush the transcript to disk.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                NSApp.terminate(nil)
            }
        }
        return .terminateCancel
    }

    // MARK: - Menu

    private var startDictationItem: NSMenuItem!
    private var meetingItem: NSMenuItem!

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()

        startDictationItem = NSMenuItem(title: "Start Dictation",
                                        action: #selector(toggleDictation), keyEquivalent: "")
        startDictationItem.target = self
        menu.addItem(startDictationItem)

        meetingItem = NSMenuItem(title: "Start Meeting",
                                 action: #selector(toggleMeeting), keyEquivalent: "m")
        meetingItem.target = self
        menu.addItem(meetingItem)

        menu.addItem(.separator())

        let library = NSMenuItem(title: "Library", action: #selector(openLibraryAction), keyEquivalent: "l")
        library.target = self
        menu.addItem(library)

        let ask = NSMenuItem(title: "Ask Radio Operator…", action: #selector(openAsk), keyEquivalent: "k")
        ask.target = self
        menu.addItem(ask)

        menu.addItem(.separator())

        let settings = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)

        let onboarding = NSMenuItem(title: "Setup & Permissions…",
                                    action: #selector(openOnboardingAction), keyEquivalent: "")
        onboarding.target = self
        menu.addItem(onboarding)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit Radio Operator", action: #selector(NSApplication.terminate(_:)),
                              keyEquivalent: "q")
        menu.addItem(quit)

        return menu
    }

    private func refreshMenuTitles() {
        let state = AppState.shared
        if state.meetingActive {
            meetingItem.title = "Stop Meeting — \(MeetingController.shared.elapsedText)"
        } else {
            meetingItem.title = "Start Meeting"
        }
        switch state.dictationPhase {
        case .recording, .finalizing, .pasting:
            startDictationItem.title = "Stop Dictation"
        default:
            let hotkey = SettingsStore.shared.data.holdHotkey
            startDictationItem.title = hotkey == .off
                ? "Start Dictation"
                : "Start Dictation (\(hotkey.displayName))"
        }
    }

    /// Red while capturing is the load-bearing rule: color = live microphone.
    /// Command Mode's instruction recording counts — its mic is just as hot.
    /// The glyph is the Radio Operator spade-signal mark (vector, template).
    static func icon(for state: AppState) -> NSImage? {
        let capturing = state.meetingActive
            || state.commandPhase == .recording
            || {
                if case .recording = state.dictationPhase { return true }
                return false
            }()
        return MenuBarIcon.image(capturing: capturing)
    }

    // MARK: - URL scheme (radiooperator://)

    @objc private func handleGetURL(_ event: NSAppleEventDescriptor,
                                    withReplyEvent reply: NSAppleEventDescriptor) {
        guard let urlString = event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))?.stringValue,
              let url = URL(string: urlString) else { return }
        route(AppDelegate.parseURLCommand(url))
    }

    /// Pure URL → command mapping. Nonisolated and side-effect-free on purpose:
    /// tested by URLCommandTestCases without an NSApplication.
    ///
    /// Accepted forms (scheme/host/path case-insensitive, trailing slash ok):
    ///   radiooperator://dictate
    ///   radiooperator://meeting/start | radiooperator://meeting/stop
    ///   radiooperator://hub/dictations|meetings|ask|dictionary|snippets|settings
    ///   (legacy: hub/library → Dictations)
    nonisolated static func parseURLCommand(_ url: URL) -> URLCommand {
        guard url.scheme?.lowercased() == "radiooperator" else { return .unknown }
        let host = url.host?.lowercased() ?? ""
        let segments = url.pathComponents
            .filter { $0 != "/" && !$0.isEmpty }
            .map { $0.lowercased() }
        switch (host, segments.count) {
        case ("dictate", 0):
            return .dictateToggle
        case ("meeting", 1):
            switch segments[0] {
            case "start": return .meetingStart
            case "stop":  return .meetingStop
            default:      return .unknown
            }
        case ("hub", 1):
            switch segments[0] {
            case "dictations": return .hub(.dictations)
            case "meetings":   return .hub(.meetings)
            case "ask":        return .hub(.ask)
            case "dictionary": return .hub(.dictionary)
            case "snippets":   return .hub(.snippets)
            // Same landing section as the "Settings…" menu item.
            case "settings":   return .hub(.dictationSettings)
            // Pre-0.4.0 route: the Library became the Dictations destination.
            case "library":    return .hub(.dictations)
            default:           return .unknown
            }
        default:
            return .unknown
        }
    }

    /// Routes a parsed command to the existing menu actions — no new
    /// controller paths, so URL triggers behave exactly like menu clicks.
    /// Meeting start/stop are idempotent: a redundant trigger (e.g. a
    /// Shortcut firing "start" while already recording) is a no-op instead
    /// of a toggle in the wrong direction.
    private func route(_ command: URLCommand) {
        switch command {
        case .dictateToggle:
            toggleDictation()
        case .meetingStart:
            if !MeetingController.shared.isActive { toggleMeeting() }
        case .meetingStop:
            if MeetingController.shared.isActive { toggleMeeting() }
        case .hub(let section):
            openHub(section)
        case .unknown:
            break
        }
    }

    // MARK: - Actions

    @objc private func toggleDictation() {
        DictationController.shared.toggle()
    }

    @objc private func toggleMeeting() {
        if MeetingController.shared.isActive {
            MeetingController.shared.stop()
        } else {
            MeetingController.shared.start()
            openMeetingWindow()
            requestNotificationAuthIfNeeded()
        }
    }

    /// Mic-activity auto-start. Fires on the idle→running edge; we skip when our
    /// own capture is the cause (dictation/meeting) so it never self-triggers,
    /// then re-confirm a beat later to ignore transient mic probes.
    @MainActor private func autoStartMeetingIfIdle() {
        guard MicActivityMonitor.shouldAutoStart(
            settingEnabled: SettingsStore.shared.data.autoStartOnMic,
            weAreCapturing: MicCapture.shared.isCapturing,
            meetingActive: MeetingController.shared.isActive) else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            guard let self,
                  MicActivityMonitor.shouldAutoStart(
                    settingEnabled: SettingsStore.shared.data.autoStartOnMic,
                    weAreCapturing: MicCapture.shared.isCapturing,
                    meetingActive: MeetingController.shared.isActive),
                  MicActivityMonitor.isRunning(MicActivityMonitor.currentDefaultInput())
            else { return }
            self.toggleMeeting()
        }
    }

    @objc private func openLibraryAction() { openLibrary() }
    @objc private func openOnboardingAction() { openOnboarding() }

    private func openLibrary() { openHub(.dictations) }

    @objc private func openAsk() { openHub(.ask) }

    @objc private func openSettings() { openHub(.dictationSettings) }

    /// Dictations, Meetings, Ask, and Settings all live in one hub window; the
    /// menu item just selects which section it lands on (an already-open hub
    /// navigates live).
    private func openHub(_ section: HubSection) {
        HubWindow.open(section)
    }

    private func openOnboarding() {
        WindowRouter.shared.show(id: "onboarding", title: "Welcome to Radio Operator",
                                 size: NSSize(width: 940, height: 760),
                                 darkChrome: true) {
            OnboardingView().environmentObject(SettingsStore.shared)
        }
    }

    private func openMeetingWindow() {
        WindowRouter.shared.show(id: "meeting", title: "Meeting",
                                 size: NSSize(width: 560, height: 520)) {
            MeetingWindowView().environmentObject(AppState.shared)
        }
    }

    private func requestNotificationAuthIfNeeded() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .provisional]) { _, _ in }
    }
}
