import Foundation
import AppKit

/// Known real-time conferencing apps. Auto-start only arms when the mic goes
/// hot AND one of these is actually running — a bare mic-open (a website's
/// permission check, Photo Booth, Continuity, or our own `--probe-capture`
/// smoke test) must never trigger a recording. Browser-tab calls (Meet in a
/// tab) aren't detectable as calls, so those need a manual Record; that's the
/// deliberate trade for never surprise-recording.
enum ConferencingApps {
    /// Native call apps whose presence + an open mic ≈ a live call.
    static let bundleIDs: Set<String> = [
        "us.zoom.xos",                 // Zoom
        "com.microsoft.teams",         // Microsoft Teams (classic)
        "com.microsoft.teams2",        // Microsoft Teams (new)
        "com.tinyspeck.slackmacgap",   // Slack (huddles)
        "com.apple.FaceTime",          // FaceTime
        "com.cisco.webexmeetingsapp",  // Webex Meetings
        "com.webex.meetingmanager",    // Webex (alt)
        "com.hnc.Discord",             // Discord
        "com.citrixonline.GoToMeeting",// GoToMeeting
        "us.zoom.ZoomClips",           // Zoom (alt)
        "com.ringcentral.RingCentral", // RingCentral
        "com.bluejeansnet.BlueJeans",  // BlueJeans
    ]

    /// True if any known conferencing app is among the given running bundle
    /// IDs. `running` is injected so the decision is pure and unit-testable.
    static func isCallAppRunning(_ running: [String]) -> Bool {
        running.contains { bundleIDs.contains($0) }
    }

    /// Live query: bundle IDs of everything currently running.
    @MainActor
    static func runningBundleIDs() -> [String] {
        NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier)
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
