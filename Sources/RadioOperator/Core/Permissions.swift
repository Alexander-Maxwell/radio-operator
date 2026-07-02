import Foundation
import AVFoundation
import ApplicationServices
import AppKit
import IOKit.hid

/// TCC permission checks and System Settings deep links.
@MainActor
enum Permissions {
    enum Status: Equatable {
        case granted
        case denied
        case notDetermined
    }

    // MARK: Microphone

    static var microphone: Status {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return .granted
        case .denied, .restricted: return .denied
        case .notDetermined: return .notDetermined
        @unknown default: return .notDetermined
        }
    }

    static func requestMicrophone() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }

    // MARK: Accessibility (paste via CGEvent + app activation)

    static var accessibility: Status {
        AXIsProcessTrusted() ? .granted : .denied
    }

    static func promptAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    // MARK: Input Monitoring (global key state for push-to-talk)

    static var inputMonitoring: Status {
        switch IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) {
        case kIOHIDAccessTypeGranted: return .granted
        case kIOHIDAccessTypeDenied: return .denied
        default: return .notDetermined
        }
    }

    static func requestInputMonitoring() {
        IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
    }

    // MARK: System Audio Recording (process tap)

    private static let tapProbeKey = "systemAudioPermissionSeen"

    /// There is no public TCC query for system-audio capture; we track whether
    /// a tap read has ever succeeded and expose that.
    static var systemAudioLikelyGranted: Bool {
        UserDefaults.standard.bool(forKey: tapProbeKey)
    }

    static func markSystemAudioGranted() {
        UserDefaults.standard.set(true, forKey: tapProbeKey)
    }

    // MARK: Deep links

    static func openSettings(pane: String) {
        if let url = URL(string: pane) {
            NSWorkspace.shared.open(url)
        }
    }

    static let microphonePane = "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
    static let accessibilityPane = "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
    static let inputMonitoringPane = "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent"
    static let audioCapturePane = "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture"
}
