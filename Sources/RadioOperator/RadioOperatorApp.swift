import AppKit
import SwiftUI
import Combine
import UserNotifications

@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static func main() {
        if TestRunner.handleIfRequested() { return }
        if ProbeRunner.handleIfRequested() { return }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }

    private var statusItem: NSStatusItem!
    private var cancellables = Set<AnyCancellable>()
    private var elapsedMenuTimer: Timer?

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

        // Route capture to the user's chosen microphone (nil = system default).
        MicCapture.shared.preferredDeviceUID = SettingsStore.shared.data.micDeviceUID

        // Reconcile the login item with the setting (registration can be
        // dropped externally via System Settings).
        LaunchAtLogin.sync(enabled: SettingsStore.shared.data.launchAtLogin)

        // Honor the saved appearance preference across every window.
        Appearance.apply(SettingsStore.shared.data.appearance)

        // 24-hour retention: prune anything a crash or sleep let linger.
        if SettingsStore.shared.data.historyRetention == .day {
            HistoryStore.shared.prune(olderThan: Date(timeIntervalSinceNow: -86_400))
            NotesStore.pruneDictationLogs(in: NotesStore.shared.dictationsFolder, keepingDays: 1)
        }

        // Pre-warm the speech format query so the first hotkey press is fast.
        let prewarmLocale = SettingsStore.shared.data.transcriptionLocale
        Task.detached { _ = await Transcriber.preferredFormat(locale: prewarmLocale) }

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
    /// The glyph is the Radio Operator spade-signal mark (vector, template).
    static func icon(for state: AppState) -> NSImage? {
        let capturing = state.meetingActive || {
            if case .recording = state.dictationPhase { return true }
            return false
        }()
        return MenuBarIcon.image(capturing: capturing)
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

    @objc private func openLibraryAction() { openLibrary() }
    @objc private func openOnboardingAction() { openOnboarding() }

    private func openLibrary() { openHub(.library) }

    @objc private func openAsk() { openHub(.ask) }

    @objc private func openSettings() { openHub(.dictation) }

    /// Library, Ask, and Settings all live in one hub window; the menu item just
    /// selects which section it lands on (an already-open hub navigates live).
    private func openHub(_ section: HubSection) {
        HubState.shared.section = section
        WindowRouter.shared.show(id: "hub", title: "Radio Operator",
                                 size: NSSize(width: 980, height: 660)) {
            HubView().environmentObject(SettingsStore.shared)
        }
    }

    private func openOnboarding() {
        WindowRouter.shared.show(id: "onboarding", title: "Welcome to Radio Operator",
                                 size: NSSize(width: 640, height: 640)) {
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
