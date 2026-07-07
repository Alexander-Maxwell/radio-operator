import Foundation
import CoreAudio

/// Watches whether the default input device is in use *by another app*, so a
/// meeting can auto-arm the moment a call starts — Zoom, Google Meet, Teams,
/// Slack huddles and FaceTime all light up the mic. It fires only on the
/// idle→running edge; the consumer decides whether to act and, crucially, skips
/// when our own dictation/meeting capture is the reason the mic is hot (see
/// `shouldAutoStart`), so we never trigger on ourselves.
///
/// All mutable state is touched only on `queue` (a serial queue), matching the
/// raw-CoreAudio style of `SystemAudioTap`/`AudioInputDevices`.
final class MicActivityMonitor: @unchecked Sendable {
    /// Invoked (on `queue`) on each not-running → running edge. Keep it cheap;
    /// hop to the main actor inside.
    var onActivated: (@Sendable () -> Void)?

    private let queue = DispatchQueue(label: "com.warroom.radiooperator.mic-activity")
    private var deviceID = AudioObjectID(kAudioObjectUnknown)
    private var runningListener: AudioObjectPropertyListenerBlock?
    private var defaultListener: AudioObjectPropertyListenerBlock?
    private var lastRunning = false

    func start() {
        let defaultBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.retarget()
        }
        defaultListener = defaultBlock
        var addr = Self.defaultInputAddress()
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &addr, queue, defaultBlock)
        queue.async { [weak self] in self?.attach() }
    }

    // MARK: - Private (all on `queue`)

    private func attach() {
        deviceID = Self.currentDefaultInput()
        lastRunning = Self.isRunning(deviceID)
        guard deviceID != kAudioObjectUnknown else { return }
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.evaluate()
        }
        runningListener = block
        var addr = Self.runningAddress()
        AudioObjectAddPropertyListenerBlock(deviceID, &addr, queue, block)
    }

    private func evaluate() {
        let running = Self.isRunning(deviceID)
        defer { lastRunning = running }
        guard running, !lastRunning else { return } // rising edge only
        onActivated?()
    }

    private func retarget() {
        queue.async { [weak self] in
            guard let self else { return }
            if self.deviceID != kAudioObjectUnknown, let block = self.runningListener {
                var addr = Self.runningAddress()
                AudioObjectRemovePropertyListenerBlock(self.deviceID, &addr, self.queue, block)
            }
            self.runningListener = nil
            self.attach()
        }
    }

    // MARK: - CoreAudio reads (nonisolated helpers)

    private static func defaultInputAddress() -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
    }

    private static func runningAddress() -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
    }

    static func currentDefaultInput() -> AudioObjectID {
        var id = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var addr = defaultInputAddress()
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id) == noErr else {
            return kAudioObjectUnknown
        }
        return id
    }

    static func isRunning(_ deviceID: AudioObjectID) -> Bool {
        guard deviceID != kAudioObjectUnknown else { return false }
        var running: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        var addr = runningAddress()
        guard AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, &running) == noErr else { return false }
        return running != 0
    }

    /// Pure decision (unit-tested): an idle→running mic edge should auto-start a
    /// meeting only when the feature is on, we aren't already capturing (so our
    /// own dictation/meeting never self-triggers), no meeting is live, AND a
    /// known conferencing app is actually running. The last clause is what stops
    /// a bare mic-open — a website's permission check, Photo Booth, or our own
    /// out-of-process `--probe-capture` smoke test — from arming a phantom
    /// recording (`weAreCapturing` only sees this process's own capture).
    static func shouldAutoStart(settingEnabled: Bool, weAreCapturing: Bool,
                                meetingActive: Bool, conferencingAppRunning: Bool) -> Bool {
        settingEnabled && !weAreCapturing && !meetingActive && conferencingAppRunning
    }
}
