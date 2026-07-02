import Foundation
import AVFoundation
import AudioToolbox

/// Microphone capture as a ref-counted broadcaster: one AVAudioEngine input
/// tap fanned out to any number of subscribers (dictation + meeting can run
/// simultaneously). The engine runs only while at least one subscriber is
/// active. Buffer callbacks fire on the audio thread — subscribers must be
/// fast (they should just yield into an AsyncStream).
final class MicCapture: @unchecked Sendable {
    static let shared = MicCapture()

    struct Subscriber {
        let onBuffer: @Sendable (AVAudioPCMBuffer) -> Void
        let onLevel: (@Sendable (Float) -> Void)?
    }

    private var engine = AVAudioEngine()
    private let lock = NSLock()
    private var subscribers: [UUID: Subscriber] = [:]
    private var converter: AVAudioConverter?
    private var outputFormat: AVAudioFormat?
    private(set) var lastBufferAt: Date?
    private var configObserver: NSObjectProtocol?
    private var _preferredDeviceUID: String?

    private init() {}

    /// UID of the input device to capture from (nil = system default).
    /// Changing it while capturing rebuilds the engine on the new device;
    /// subscribers keep receiving buffers uninterrupted.
    var preferredDeviceUID: String? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _preferredDeviceUID
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            guard _preferredDeviceUID != newValue else { return }
            _preferredDeviceUID = newValue
            if !subscribers.isEmpty {
                stopEngineLocked(clearFormat: false)
                try? startEngineLocked()
            }
        }
    }

    /// Subscribe for converted buffers in `format`. First subscriber starts the
    /// engine. All subscribers must request the same format (the SpeechAnalyzer
    /// preferred format).
    func subscribe(format: AVAudioFormat,
                   onBuffer: @escaping @Sendable (AVAudioPCMBuffer) -> Void,
                   onLevel: (@Sendable (Float) -> Void)? = nil) throws -> UUID {
        lock.lock()
        defer { lock.unlock() }
        if let existing = outputFormat, existing != format {
            NSLog("MicCapture: subscriber format mismatch — using first subscriber's format")
        }
        let id = UUID()
        subscribers[id] = Subscriber(onBuffer: onBuffer, onLevel: onLevel)
        if subscribers.count == 1 {
            outputFormat = format
            try startEngineLocked()
        }
        return id
    }

    func unsubscribe(_ id: UUID) {
        lock.lock()
        defer { lock.unlock() }
        subscribers.removeValue(forKey: id)
        if subscribers.isEmpty {
            stopEngineLocked(clearFormat: true)
        }
    }

    private func startEngineLocked() throws {
        guard let outputFormat else { return }
        // Fresh engine every start: retargeting a reused engine's input
        // device is unreliable.
        engine = AVAudioEngine()
        let input = engine.inputNode
        applyPreferredDeviceLocked(to: input)
        let inFormat = input.inputFormat(forBus: 0)
        guard inFormat.sampleRate > 0 else {
            subscribers.removeAll()
            throw NSError(domain: "RadioOperator.MicCapture", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "No microphone input available."])
        }
        converter = AVAudioConverter(from: inFormat, to: outputFormat)

        input.installTap(onBus: 0, bufferSize: 4096, format: inFormat) { [weak self] buffer, _ in
            self?.broadcast(buffer)
        }
        engine.prepare()
        try engine.start()

        // Mic route/format changes (AirPods connect mid-capture) reconfigure
        // the engine; rebuild the tap and converter, keep subscribers.
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { [weak self] _ in
            self?.handleConfigChange()
        }
    }

    /// Routes the engine's input to the user-chosen device. Falls back to the
    /// system default (loudly, in the log) when the device is missing.
    private func applyPreferredDeviceLocked(to input: AVAudioInputNode) {
        guard let uid = _preferredDeviceUID else { return }
        guard let device = AudioInputDevices.device(forUID: uid) else {
            NSLog("MicCapture: preferred mic \(uid) not found — using system default")
            return
        }
        guard let audioUnit = input.audioUnit else {
            NSLog("MicCapture: no audioUnit on input node — using system default")
            return
        }
        var deviceID = device.id
        let status = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &deviceID,
            UInt32(MemoryLayout<AudioDeviceID>.size))
        if status != noErr {
            NSLog("MicCapture: failed to select mic \(device.name) (\(status)) — using system default")
        }
    }

    private func stopEngineLocked(clearFormat: Bool) {
        if let configObserver {
            NotificationCenter.default.removeObserver(configObserver)
            self.configObserver = nil
        }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        converter = nil
        if clearFormat {
            outputFormat = nil
        }
        lastBufferAt = nil
    }

    private func handleConfigChange() {
        lock.lock()
        defer { lock.unlock() }
        guard !subscribers.isEmpty, let outputFormat else { return }
        engine.inputNode.removeTap(onBus: 0)
        let inFormat = engine.inputNode.inputFormat(forBus: 0)
        guard inFormat.sampleRate > 0 else { return }
        converter = AVAudioConverter(from: inFormat, to: outputFormat)
        engine.inputNode.installTap(onBus: 0, bufferSize: 4096, format: inFormat) { [weak self] buffer, _ in
            self?.broadcast(buffer)
        }
        if !engine.isRunning {
            try? engine.start()
        }
    }

    private func broadcast(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        let subs = subscribers
        let converter = self.converter
        let outputFormat = self.outputFormat
        lastBufferAt = Date()
        lock.unlock()
        guard !subs.isEmpty, let converter, let outputFormat else { return }

        let level = MicCapture.rmsLevel(buffer)
        guard let converted = MicCapture.convert(buffer, with: converter, to: outputFormat) else {
            for sub in subs.values { sub.onLevel?(level) }
            return
        }
        for sub in subs.values {
            sub.onLevel?(level)
            sub.onBuffer(converted)
        }
    }

    static func convert(_ buffer: AVAudioPCMBuffer, with converter: AVAudioConverter,
                        to format: AVAudioFormat) -> AVAudioPCMBuffer? {
        if buffer.format == format { return buffer }
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
        var fed = false
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, outStatus in
            if fed {
                outStatus.pointee = .noDataNow
                return nil
            }
            fed = true
            outStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, error == nil, out.frameLength > 0 else { return nil }
        return out
    }

    static func rmsLevel(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let data = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return 0 }
        let n = Int(buffer.frameLength)
        var sum: Float = 0
        var count = 0
        var i = 0
        while i < n {
            let v = data[i]
            sum += v * v
            count += 1
            i += 8 // sample every 8th frame; a level meter doesn't need precision
        }
        guard count > 0 else { return 0 }
        let rms = sqrtf(sum / Float(count))
        return min(1, rms * 12)
    }
}
