import SwiftUI
import AppKit
import UserNotifications

/// First-run walkthrough in two stages: dictation permissions now, system
/// audio deferred to the first meeting (it never blocks). Statuses poll on a
/// 1s timer so the dots go green the moment the user flips a toggle in
/// System Settings.
struct OnboardingView: View {
    @EnvironmentObject var settings: SettingsStore

    @State private var micStatus: Permissions.Status = .notDetermined
    @State private var axStatus: Permissions.Status = .notDetermined
    @State private var imStatus: Permissions.Status = .notDetermined
    @State private var systemAudioGranted = false
    @State private var showRelaunchNote = false
    @State private var didInitialSnapshot = false
    @State private var testText = ""
    @State private var preflight: PreflightReport?

    private let poll = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                systemCheckSection
                dictationSection
                testArea
                meetingsSection
                footer
            }
            .padding(24)
        }
        .frame(minWidth: 540, minHeight: 640)
        .onAppear(perform: refreshStatuses)
        .onReceive(poll) { _ in refreshStatuses() }
    }

    // MARK: - System Check (Preflight)

    private var systemCheckSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("System Check")
                    .font(.headline)
                if let preflight {
                    Text(preflight.hasFailure
                         ? "needs attention"
                         : (preflight.dictationReady ? "ready" : "almost ready"))
                        .font(.caption)
                        .foregroundStyle(preflight.hasFailure ? .red : .secondary)
                }
            }
            VStack(spacing: 0) {
                if let preflight {
                    ForEach(preflight.checks) { check in
                        SystemCheckRow(check: check)
                        if check.id != preflight.checks.last?.id {
                            Divider().padding(.leading, 12)
                        }
                    }
                } else {
                    Text("Checking…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(12)
                }
            }
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Radio Operator")
                .font(.largeTitle.bold())
            Text("Speak anywhere. Capture every meeting. Nothing leaves this Mac.")
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Section 1: Dictation

    private var dictationSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Dictation — needed now")
                .font(.headline)
            PermissionCard(
                icon: "mic.fill",
                name: "Microphone",
                why: "Hear you",
                status: micStatus,
                grant: { Task { _ = await Permissions.requestMicrophone() } })
            PermissionCard(
                icon: "cursorarrow.click",
                name: "Accessibility",
                why: "Paste at your cursor",
                status: axStatus,
                grant: { Permissions.promptAccessibility() },
                settingsPane: Permissions.accessibilityPane)
            PermissionCard(
                icon: "keyboard",
                name: "Input Monitoring",
                why: "See your hold-to-talk key",
                status: imStatus,
                grant: { Permissions.requestInputMonitoring() },
                settingsPane: Permissions.inputMonitoringPane)
            if showRelaunchNote {
                HStack(spacing: 8) {
                    Text("If the hotkey doesn't respond, relaunch Radio Operator.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Relaunch", action: relaunch)
                        .controlSize(.small)
                }
            }
        }
    }

    // MARK: - Test area

    private var testArea: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Try it: hold \(hotkeyName) and speak")
                .font(.callout)
            TextEditor(text: $testText)
                .font(.body)
                .frame(minHeight: 60)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
        }
    }

    private var hotkeyName: String {
        settings.data.holdHotkey.displayName.replacingOccurrences(of: "Hold ", with: "")
    }

    // MARK: - Section 2: Meetings

    private var meetingsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Meetings — grant when you start your first meeting")
                .font(.headline)
                .foregroundStyle(.secondary)
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "speaker.wave.2")
                    .font(.title2)
                    .frame(width: 32)
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text("System Audio Recording")
                            .font(.subheadline.weight(.medium))
                        Text(systemAudioGranted ? "granted once" : "will prompt at first meeting")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Text("macOS will ask the first time you start a meeting. You can also grant it now:")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Open Settings") {
                    Permissions.openSettings(pane: Permissions.audioCapturePane)
                }
                .controlSize(.small)
            }
            .padding(12)
            .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 10))
            .opacity(0.85)
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            Spacer()
            Button("Done", action: finish)
                .keyboardShortcut(.defaultAction)
        }
    }

    private func finish() {
        UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .provisional]) { _, _ in }
        settings.data.hasCompletedOnboarding = true
        NSApp.keyWindow?.close()
    }

    // MARK: - Status polling

    private func refreshStatuses() {
        let mic = Permissions.microphone
        let ax = Permissions.accessibility
        let im = Permissions.inputMonitoring
        // A hotkey-relevant permission just flipped to granted: rebuild the
        // event taps so the user doesn't have to relaunch (usually).
        if didInitialSnapshot {
            let newlyGranted = (axStatus != .granted && ax == .granted)
                || (imStatus != .granted && im == .granted)
            if newlyGranted {
                DictationController.shared.hotkeys.restart()
                showRelaunchNote = true
            }
        }
        didInitialSnapshot = true
        micStatus = mic
        axStatus = ax
        imStatus = im
        systemAudioGranted = Permissions.systemAudioLikelyGranted
        Task { @MainActor in
            preflight = await Preflight.run()
        }
    }

    /// TCC grants only fully apply to a fresh process; re-open ourselves after
    /// this instance has exited.
    private func relaunch() {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/sh")
        proc.arguments = ["-c", "sleep 0.5; open \"\(Bundle.main.bundlePath)\""]
        try? proc.run()
        NSApp.terminate(nil)
    }
}

/// One preflight check line in the System Check card, using the same
/// glowing status-dot look as the hub's SIGNAL ribbon chips.
private struct SystemCheckRow: View {
    let check: PreflightReport.Check

    var body: some View {
        HStack(spacing: 10) {
            Circle().fill(color).frame(width: 8, height: 8)
                .shadow(color: color.opacity(0.6), radius: 2.5)
            Text(check.title)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 128, alignment: .leading)
            Text(check.detail)
                .font(.system(size: 11.5))
                .foregroundStyle(check.isFail ? Color.primary : Color.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
    }

    private var color: Color {
        switch check.verdict {
        case .pass: return .green
        case .warn: return .orange
        case .fail: return .red
        }
    }
}

private struct PermissionCard: View {
    let icon: String
    let name: String
    let why: String
    let status: Permissions.Status
    let grant: () -> Void
    var settingsPane: String? = nil

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.title2)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(.headline)
                Text(why)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Circle()
                .fill(dotColor)
                .frame(width: 10, height: 10)
            if status == .granted {
                Text("Granted")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Button("Grant", action: grant)
                if let pane = settingsPane {
                    Button("Open Settings") {
                        Permissions.openSettings(pane: pane)
                    }
                    .buttonStyle(.link)
                }
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
    }

    private var dotColor: Color {
        switch status {
        case .granted: return .green
        case .denied: return .orange
        case .notDetermined: return .gray
        }
    }
}
