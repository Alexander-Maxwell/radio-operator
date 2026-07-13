import Foundation
import AppKit

/// Conferencing apps whose mere *presence* implies an active call — the signal
/// auto-start keys off. Deliberately ONLY per-call apps: ones a user launches
/// for a call and quits after, so "running" ≈ "on a call".
///
/// Always-on apps (Slack, Teams, Discord) are intentionally excluded: they sit
/// running all day, so their presence says nothing about whether you're in a
/// call. Including them made auto-start fire on *any* mic-open (a website's
/// permission check, Photo Booth, our own `--probe-capture` smoke test) for
/// anyone who keeps Slack open — which is what made recording feel random.
/// Slack huddles / Teams calls therefore need a manual Record; detecting an
/// active huddle is future work. Browser-tab calls (Meet) likewise aren't
/// detectable as calls. That's the deliberate trade for never surprise-recording.
enum ConferencingApps {
    /// Per-call native apps: launched for a call, quit after. Running ≈ a call.
    static let autoStartBundleIDs: Set<String> = [
        "us.zoom.xos",                 // Zoom
        "us.zoom.ZoomClips",           // Zoom (alt)
        "com.apple.FaceTime",          // FaceTime
        "com.cisco.webexmeetingsapp",  // Webex Meetings
        "com.webex.meetingmanager",    // Webex (alt)
        "com.citrixonline.GoToMeeting",// GoToMeeting
        "com.bluejeansnet.BlueJeans",  // BlueJeans
        "com.ringcentral.RingCentral", // RingCentral
        // Google Meet installed as a Chrome PWA ("Google Meet.app"). The app id
        // is derived from Meet's start URL, so it's stable across machines, and
        // the PWA is opened per-call — running ≈ on a Meet call. (Meet in a plain
        // browser tab is NOT this and stays undetectable; use the broad setting.)
        "com.google.Chrome.app.kjgfgldnnfoeklkmfkjfagphfepbbdan",
    ]

    /// True if a per-call conferencing app is among the given running bundle
    /// IDs. `running` is injected so the decision is pure and unit-testable.
    /// An always-on app (Slack/Teams/Discord) or our own process is never a
    /// match, so neither can arm a recording on its own.
    static func isCallAppRunning(_ running: [String]) -> Bool {
        running.contains { autoStartBundleIDs.contains($0) }
    }

    /// Live query: bundle IDs of everything currently running.
    @MainActor
    static func runningBundleIDs() -> [String] {
        NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier)
    }

    /// The per-call apps running right now (for decision logging).
    @MainActor
    static func runningCallApps() -> [String] {
        runningBundleIDs().filter { autoStartBundleIDs.contains($0) }
    }

    /// Convenience: is a call app running right now?
    @MainActor
    static func aCallAppIsRunning() -> Bool {
        isCallAppRunning(runningBundleIDs())
    }
}

/// Decides whether an auto-started meeting is a phantom — the mic opened (a
/// call app was up) but no conversation followed within the grace window — and
/// should be discarded rather than left as an empty "Meeting in progress" note.
/// Manual meetings are never auto-discarded; the user chose to start them.
enum MeetingAutoCancel {
    /// Grace period before a silent auto-start is judged a phantom.
    static let graceWindow: TimeInterval = 15

    static func shouldDiscard(autoStarted: Bool, elapsed: TimeInterval,
                              sawSpeech: Bool, graceWindow: TimeInterval = graceWindow) -> Bool {
        autoStarted && !sawSpeech && elapsed >= graceWindow
    }
}
