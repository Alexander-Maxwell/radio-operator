import Foundation
import CoreAudio
import AudioToolbox
import AVFoundation

/// Captures system audio (everything other apps play — the "Them" side of a
/// meeting) via a Core Audio process tap + private aggregate device.
/// No bot, no virtual driver. Requires the "System Audio Recording" TCC
/// permission (NSAudioCaptureUsageDescription), prompted on first real read.
final class SystemAudioTap: @unchecked Sendable {
    enum TapError: LocalizedError {
        case tapCreation(OSStatus)
        case formatRead(OSStatus)
        case aggregateCreation(OSStatus)
        case ioProc(OSStatus)
        case start(OSStatus)

        var errorDescription: String? {
            switch self {
            case .tapCreation(let s): return "Couldn't create system audio tap (\(s)). Check System Audio Recording permission."
            case .formatRead(let s): return "Couldn't read tap format (\(s))."
            case .aggregateCreation(let s): return "Couldn't create capture device (\(s))."
            case .ioProc(let s): return "Couldn't attach audio reader (\(s))."
            case .start(let s): return "Couldn't start system audio capture (\(s))."
            }
        }
    }

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var converter: AVAudioConverter?
    private var tapFormat: AVAudioFormat?
    private var outputFormat: AVAudioFormat?
    private let stateLock = NSLock()
    private var running = false
    private(set) var lastBufferAt: Date?

    var onBuffer: (@Sendable (AVAudioPCMBuffer) -> Void)?

    /// Creates the tap chain and starts delivering converted buffers.
    /// Throws a typed TapError; callers degrade to mic-only with a banner.
    func start(outputFormat: AVAudioFormat) throws {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard !running else { return }
        self.outputFormat = outputFormat

        // Exclude our own process so dictation playback/cues never loop back.
        let ownProcessObject = SystemAudioTap.translatePID(pid: ProcessInfo.processInfo.processIdentifier)
        let exclude: [AudioObjectID] = ownProcessObject != kAudioObjectUnknown
            ? [ownProcessObject] : []

        let desc = CATapDescription(stereoGlobalTapButExcludeProcesses: exclude)
        desc.muteBehavior = .unmuted
        desc.isPrivate = true
        desc.name = "Radio Operator Meeting Tap"

        var newTapID = AudioObjectID(kAudioObjectUnknown)
        let tapStatus = AudioHardwareCreateProcessTap(desc, &newTapID)
        guard tapStatus == noErr, newTapID != kAudioObjectUnknown else {
            throw TapError.tapCreation(tapStatus)
        }
        tapID = newTapID

        // Read the tap's stream format.
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        let fmtStatus = AudioObjectGetPropertyData(tapID, &addr, 0, nil, &size, &asbd)
        guard fmtStatus == noErr, let format = AVAudioFormat(streamDescription: &asbd) else {
            teardownLocked()
            throw TapError.formatRead(fmtStatus)
        }
        tapFormat = format
        converter = AVAudioConverter(from: format, to: outputFormat)

        // Private aggregate device wrapping the tap.
        let aggUID = "com.warroom.radiooperator.tap.agg"
        let aggDesc: [String: Any] = [
            kAudioAggregateDeviceNameKey as String: "Radio Operator Tap",
            kAudioAggregateDeviceUIDKey as String: aggUID,
            kAudioAggregateDeviceIsPrivateKey as String: true,
            kAudioAggregateDeviceIsStackedKey as String: false,
            kAudioAggregateDeviceTapAutoStartKey as String: true,
            kAudioAggregateDeviceSubDeviceListKey as String: [Any](),
            kAudioAggregateDeviceTapListKey as String: [
                [
                    kAudioSubTapUIDKey as String: desc.uuid.uuidString,
                    kAudioSubTapDriftCompensationKey as String: true,
                ]
            ],
        ]
        var newAggID = AudioObjectID(kAudioObjectUnknown)
        let aggStatus = AudioHardwareCreateAggregateDevice(aggDesc as CFDictionary, &newAggID)
        guard aggStatus == noErr, newAggID != kAudioObjectUnknown else {
            teardownLocked()
            throw TapError.aggregateCreation(aggStatus)
        }
        aggregateID = newAggID

        // IO proc on a dedicated dispatch queue; convert + deep-copy before
        // leaving the callback (the ABL memory is only valid inside it).
        let queue = DispatchQueue(label: "com.warroom.radiooperator.tap-io", qos: .userInitiated)
        var newProcID: AudioDeviceIOProcID?
        let ioStatus = AudioDeviceCreateIOProcIDWithBlock(&newProcID, aggregateID, queue) {
            [weak self] _, inInputData, _, _, _ in
            self?.handleIO(inInputData)
        }
        guard ioStatus == noErr, let procID = newProcID else {
            teardownLocked()
            throw TapError.ioProc(ioStatus)
        }
        ioProcID = procID

        let startStatus = AudioDeviceStart(aggregateID, procID)
        guard startStatus == noErr else {
            teardownLocked()
            throw TapError.start(startStatus)
        }
        running = true
    }

    func stop() {
        stateLock.lock()
        defer { stateLock.unlock() }
        teardownLocked()
    }

    /// Teardown in strict reverse order: stop device → destroy IOProc →
    /// destroy aggregate → destroy tap.
    private func teardownLocked() {
        running = false
        if let procID = ioProcID, aggregateID != kAudioObjectUnknown {
            AudioDeviceStop(aggregateID, procID)
            AudioDeviceDestroyIOProcID(aggregateID, procID)
        }
        ioProcID = nil
        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = kAudioObjectUnknown
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = kAudioObjectUnknown
        }
        converter = nil
        tapFormat = nil
        lastBufferAt = nil
    }

    private func handleIO(_ inInputData: UnsafePointer<AudioBufferList>) {
        guard running, let tapFormat, let converter, let outputFormat else { return }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: tapFormat,
                                            bufferListNoCopy: inInputData,
                                            deallocator: nil) else { return }
        lastBufferAt = Date()
        // Converter output is freshly allocated — safe beyond the callback.
        guard let converted = MicCapture.convert(buffer, with: converter, to: outputFormat),
              converted.frameLength > 0 else { return }
        onBuffer?(converted)
    }

    private static func translatePID(pid: pid_t) -> AudioObjectID {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var processObject = AudioObjectID(kAudioObjectUnknown)
        var pidValue = pid
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = withUnsafeMutablePointer(to: &pidValue) { pidPtr in
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject), &address,
                UInt32(MemoryLayout<pid_t>.size), pidPtr, &size, &processObject)
        }
        return status == noErr ? processObject : AudioObjectID(kAudioObjectUnknown)
    }
}
