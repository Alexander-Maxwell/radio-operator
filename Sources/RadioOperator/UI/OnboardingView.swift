import SwiftUI
import AppKit
import UserNotifications

/// First-run walkthrough: three cards (welcome pitch, the four TCC grants,
/// engine preflight) over a ready banner and a live test strip. Statuses poll
/// on a 1s timer so rows flip green the moment the user grants a permission
/// in System Settings; newly-granted hotkey permissions restart the event
/// taps so a relaunch is usually unnecessary.
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
            VStack(alignment: .leading, spacing: 18) {
                header
                cards
                readyBanner
                testArea
                footer
            }
            .frame(maxWidth: 880)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 28).padding(.vertical, 26)
        }
        .frame(minWidth: 640, minHeight: 640)
        .background(Theme.bgApp)
        .environment(\.colorScheme, .light)
        .onAppear(perform: refreshStatuses)
        .onReceive(poll) { _ in refreshStatuses() }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Radio Operator")
                .font(Theme.display(28, .bold))
                .foregroundStyle(Theme.textMax)
            Text("Speak anywhere. Capture every meeting. Nothing leaves this Mac.")
                .font(Theme.display(13))
                .foregroundStyle(Theme.textDim)
        }
    }

    // MARK: - The three cards

    private var cards: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 250), spacing: 14, alignment: .top)],
                  alignment: .leading, spacing: 14) {
            welcomeCard
            accessCard
            engineCard
        }
    }

    private var welcomeCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            Eyebrow(text: "01 · WELCOME", size: 10, tracking: 1.8, color: Theme.green)
                .padding(.bottom, 18)
            RoundedRectangle(cornerRadius: 14)
                .fill(Theme.green.opacity(0.1))
                .frame(width: 52, height: 52)
                .overlay(RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(Theme.green.opacity(0.25), lineWidth: 1))
                .overlay(Image(systemName: "waveform.circle")
                    .font(.system(size: 26, weight: .regular))
                    .foregroundStyle(Theme.green))
                .padding(.bottom, 16)
            Text("Everything runs on this Mac.")
                .font(Theme.display(20, .semibold))
                .foregroundStyle(Theme.textMax)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 9)
            Text("Dictation and two-track meeting notes, transcribed entirely on-device. No cloud account — just markdown files you own. Summaries and Ask use your own Claude sign-in.")
                .font(Theme.display(12.5))
                .foregroundStyle(Theme.textDim)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .roCard(fill: Theme.green.opacity(0.06), radius: 16,
                border: Theme.green.opacity(0.25))
    }

    private var accessCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            Eyebrow(text: "02 · ACCESS", size: 10, tracking: 1.8)
                .padding(.bottom, 18)
            Text("The permissions. That's all.")
                .font(Theme.display(20, .semibold))
                .foregroundStyle(Theme.textMax)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 14)
            VStack(spacing: 8) {
                PermissionRow(
                    icon: "mic.fill",
                    name: "Microphone",
                    why: "Hear you",
                    granted: micStatus == .granted,
                    allow: allowMicrophone)
                PermissionRow(
                    icon: "cursorarrow.click",
                    name: "Accessibility",
                    why: "Paste at your cursor",
                    granted: axStatus == .granted,
                    allow: {
                        Permissions.promptAccessibility()
                        Permissions.openSettings(pane: Permissions.accessibilityPane)
                    })
                PermissionRow(
                    icon: "keyboard",
                    name: "Input Monitoring",
                    why: "See your hold-to-talk key",
                    granted: imStatus == .granted,
                    allow: {
                        Permissions.requestInputMonitoring()
                        Permissions.openSettings(pane: Permissions.inputMonitoringPane)
                    })
                PermissionRow(
                    icon: "speaker.wave.2",
                    name: "System audio",
                    why: "The other side of meetings — macOS asks at your first meeting",
                    granted: systemAudioGranted,
                    allow: { Permissions.openSettings(pane: Permissions.audioCapturePane) })
            }
            if showRelaunchNote {
                HStack(spacing: 8) {
                    Text("If the hotkey doesn't respond, relaunch Radio Operator.")
                        .font(Theme.display(11))
                        .foregroundStyle(Theme.textMeta)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Relaunch", action: relaunch)
                        .buttonStyle(DimButtonStyle())
                }
                .padding(.top, 12)
            }
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "info.circle")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textMeta)
                    .padding(.top, 1)
                Text("macOS shows its own confirmation — click Allow when it appears.")
                    .font(Theme.display(11))
                    .foregroundStyle(Theme.textMeta)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 14)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .roCard(fill: Theme.lift(0.015), radius: 16,
                border: Theme.hairline(0.09))
    }

    private var engineCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            Eyebrow(text: "03 · ENGINE", size: 10, tracking: 1.8)
                .padding(.bottom, 18)
            Text("On-device speech + your Claude")
                .font(Theme.display(20, .semibold))
                .foregroundStyle(Theme.textMax)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 14)
            if let preflight {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(preflight.checks) { check in
                        SystemCheckRow(check: check)
                    }
                }
            } else {
                Text("CHECKING…")
                    .font(Theme.mono(10.5, .medium))
                    .tracking(1)
                    .foregroundStyle(Theme.textMeta)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .roCard(fill: Theme.lift(0.015), radius: 16,
                border: Theme.hairline(0.09))
    }

    /// Denied mic never re-prompts; send the user to the pane instead.
    private func allowMicrophone() {
        switch Permissions.microphone {
        case .notDetermined:
            Task { _ = await Permissions.requestMicrophone() }
        default:
            Permissions.openSettings(pane: Permissions.microphonePane)
        }
    }

    // MARK: - Ready banner

    @ViewBuilder private var readyBanner: some View {
        if let preflight {
            if preflight.dictationReady {
                HStack(spacing: 10) {
                    Spacer(minLength: 0)
                    GlowDot(color: Theme.green, size: 9)
                    Text("You're ready.")
                        .font(Theme.display(14))
                        .foregroundStyle(Theme.textBright)
                    Text("Hold")
                        .font(Theme.display(14))
                        .foregroundStyle(Theme.textFaint)
                    Keycap(text: hotkeyName)
                    Text("and speak, anywhere.")
                        .font(Theme.display(14))
                        .foregroundStyle(Theme.textFaint)
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 15).padding(.horizontal, 16)
                .roCard(fill: Theme.green.opacity(0.05), radius: 14,
                        border: Theme.green.opacity(0.22))
            } else {
                HStack(spacing: 10) {
                    Spacer(minLength: 0)
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.amber)
                    Text("Almost there — grant the highlighted permission above.")
                        .font(Theme.display(14))
                        .foregroundStyle(Theme.amber)
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 15).padding(.horizontal, 16)
                .roCard(fill: Theme.amber.opacity(0.05), radius: 14,
                        border: Theme.amber.opacity(0.22))
            }
        }
    }

    // MARK: - Test area

    private var testArea: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Text("Try it: hold")
                    .font(Theme.display(13))
                    .foregroundStyle(Theme.textBody)
                Keycap(text: hotkeyName)
                Text("and speak")
                    .font(Theme.display(13))
                    .foregroundStyle(Theme.textBody)
            }
            TextEditor(text: $testText)
                .font(Theme.display(13))
                .foregroundStyle(Theme.textHi)
                .scrollContentBackground(.hidden)
                .frame(minHeight: 64)
                .padding(6)
                .background(Theme.lift(0.02), in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Theme.hairline(0.08), lineWidth: 1))
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .roCard(fill: Theme.lift(0.03), radius: 13,
                border: Theme.hairline(0.08))
    }

    private var hotkeyName: String {
        settings.data.holdHotkey.displayName.replacingOccurrences(of: "Hold ", with: "")
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            Spacer()
            Button("Done", action: finish)
                .buttonStyle(GreenButtonStyle())
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

// MARK: - Permission row

/// One grant in the ACCESS card: green-tinted with a mono ✓ ON chip when
/// granted, neutral with an Allow button when pending.
private struct PermissionRow: View {
    let icon: String
    let name: String
    let why: String
    let granted: Bool
    let allow: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 11) {
            RoundedRectangle(cornerRadius: 9)
                .fill(Theme.lift(0.05))
                .frame(width: 34, height: 34)
                .overlay(Image(systemName: icon)
                    .font(.system(size: 14, weight: .regular))
                    .foregroundStyle(Theme.textBody))
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(Theme.display(13.5, .semibold))
                    .foregroundStyle(Theme.textHi)
                Text(why)
                    .font(Theme.display(11.5))
                    .foregroundStyle(Theme.textFaint)
                    .lineSpacing(1)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if granted {
                HStack(spacing: 4) {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .bold))
                    Text("ON")
                        .font(Theme.mono(9.5, .medium))
                        .tracking(0.6)
                }
                .foregroundStyle(Theme.green)
            } else {
                Button("Allow", action: allow)
                    .buttonStyle(AllowButtonStyle())
            }
        }
        .padding(12)
        .background(granted ? Theme.green.opacity(0.05) : Theme.lift(0.025),
                    in: RoundedRectangle(cornerRadius: 11))
        .overlay(RoundedRectangle(cornerRadius: 11)
            .strokeBorder(granted ? Theme.green.opacity(0.18) : Theme.hairline(0.08),
                          lineWidth: 1))
    }
}

/// Small primary Allow button: violet fill, cream ink, hover-darkens.
private struct AllowButtonStyle: ButtonStyle {
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.display(11.5, .semibold))
            .foregroundStyle(Theme.greenInk)
            .padding(.horizontal, 13).padding(.vertical, 6)
            .background(hovering ? Theme.greenBtnHover : Theme.green,
                        in: RoundedRectangle(cornerRadius: 8))
            .opacity(configuration.isPressed ? 0.85 : 1)
            .onHover { hovering = $0 }
    }
}

// MARK: - System check row

/// One preflight check in the ENGINE card: verdict dot + mono title + detail.
private struct SystemCheckRow: View {
    let check: PreflightReport.Check

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            GlowDot(color: color, size: 7)
                .padding(.top, 3)
            VStack(alignment: .leading, spacing: 2) {
                Text(check.title.uppercased())
                    .font(Theme.mono(10.5, .medium))
                    .tracking(0.8)
                    .foregroundStyle(Theme.textFaint)
                Text(check.detail)
                    .font(Theme.display(11.5))
                    .foregroundStyle(check.isFail ? Theme.textBright : Theme.textDim)
                    .lineSpacing(1)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }

    private var color: Color {
        switch check.verdict {
        case .pass: return Theme.green
        case .warn: return Theme.amber
        case .fail: return Theme.alertRed
        }
    }
}
