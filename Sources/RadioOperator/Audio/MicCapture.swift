import Foundation
import AVFoundation
import AudioToolbox

/// Microphone capture as a ref-counted broadcaster: one AVAudioEngine input
/// tap fanned out to any number of subscribers (dictation + meeting can run
/// simultaneously). The engine runs only while at least one subscriber is
/// active. Buffer callbacks fire on the audio thread — subscribers must be
/// fast (they should just yield into an AsyncStream).
extension Notification.Name {
    /// Posted when capture keeps returning pure silence even after voice
    /// processing was cleared — i.e. we could not auto-recover the mic.
    static let micCapturePersistentSilence = Notification.Name("MicCapturePersistentSilence")
}

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
    // OFF by default. VPIO is opt-in per capture session (dictation forces it
    // off; a meeting sets it from micEchoCancellation). A default of `true`
    // meant any path that started the engine before a controller set the flag
    // (auto-start / the mic monitor) latched VPIO onto the shared device and
    // silenced the next dictation.
    private var _voiceProcessing = false

    // Start-of-capture silence watchdog state (see CaptureSilenceCheck). Guarded
    // by `lock`; `_engineGeneration` invalidates a pending check after a rebuild.
    private var _engineVoiceProcessing = false
    private var _engineGeneration = 0
    private var _sawSignalThisEngine = false
    private var _healedThisSession = false

    private init() {}

    /// True while at least one subscriber is capturing — i.e. the mic is hot
    /// *because of us* (dictation or a meeting). The auto-start monitor reads
    /// this to avoid triggering on our own capture.
    var isCapturing: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !subscribers.isEmpty
    }

    /// Enables Apple's Voice-Processing I/O (hardware AEC + noise suppression)
    /// on the input, so far-end audio leaking from speakers is cancelled before
    /// transcription. Applied on the next engine start; set it from the main
    /// actor to mirror the `micEchoCancellation` setting.
    var voiceProcessing: Bool {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _voiceProcessing
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            _voiceProcessing = newValue
        }
    }

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
            _healedThisSession = false
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
        do {
            try buildEngineLocked(outputFormat: outputFormat, voiceProcessing: _voiceProcessing)
        } catch {
            // Voice processing can be incompatible with some device chains
            // (aggregates, certain USB interfaces). It must never break plain
            // capture — fall back to an unprocessed engine.
            if _voiceProcessing {
                NSLog("MicCapture: voice-processing start failed (\(error.localizedDescription)) — retrying without it")
                try buildEngineLocked(outputFormat: outputFormat, voiceProcessing: false)
            } else {
                throw error
            }
        }
    }

    private func buildEngineLocked(outputFormat: AVAudioFormat, voiceProcessing: Bool) throws {
        // Fresh engine every start: retargeting a reused engine's input
        // device is unreliable.
        engine = AVAudioEngine()
        _engineVoiceProcessing = voiceProcessing
        _engineGeneration &+= 1
        _sawSignalThisEngine = false
        let input = engine.inputNode
        // Voice-Processing I/O (hardware AEC) is a STICKY, device-level change:
        // a fresh engine that merely omits the enable can inherit a VPIO state
        // left latched by a prior meeting (or a crashed/killed capture) and gate
        // a multi-channel mic to pure silence. Set it EXPLICITLY both ways so
        // `false` actively CLEARS any latch. Before touching the format/device —
        // it reconfigures the input unit.
        do {
            try input.setVoiceProcessingEnabled(voiceProcessing)
        } catch {
            // Enabling can fail on some device chains (aggregates, certain USB
            // interfaces); let startEngineLocked's fallback retry without it.
            // Disabling must never block plain capture — if it throws, the unit
            // isn't in VPIO mode anyway, so proceed.
            if voiceProcessing { throw error }
            NSLog("MicCapture: setVoiceProcessingEnabled(false) threw (\(error.localizedDescription)) — proceeding without VPIO")
        }
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

        scheduleSilenceWatchdogLocked()
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

    /// After each engine start, verify the mic is actually delivering audio and
    /// not just silent buffers (the VPIO/AEC-silences-mic signature). Self-heals
    /// by rebuilding without voice processing; if it still can't, surfaces it.
    private func scheduleSilenceWatchdogLocked() {
        let generation = _engineGeneration
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1.3) { [weak self] in
            self?.runSilenceWatchdog(generation: generation)
        }
    }

    private func runSilenceWatchdog(generation: Int) {
        lock.lock()
        guard generation == _engineGeneration, !subscribers.isEmpty else { lock.unlock(); return }
        let action = CaptureSilenceCheck.decide(
            buffersArrived: lastBufferAt != nil,
            sawSignal: _sawSignalThisEngine,
            voiceProcessingActive: _engineVoiceProcessing,
            alreadyHealed: _healedThisSession)
        switch action {
        case .ok, .waiting:
            lock.unlock()
        case .selfHeal:
            _healedThisSession = true
            _voiceProcessing = false
            NSLog("MicCapture: mic delivered only silence with VPIO on — self-healing (rebuild without voice processing)")
            stopEngineLocked(clearFormat: false)
            do { try startEngineLocked() }
            catch { NSLog("MicCapture: self-heal rebuild failed — \(error.localizedDescription)") }
            lock.unlock()
        case .reportSilent:
            NSLog("MicCapture: mic still silent after voice processing cleared — check the input device or mute switch")
            lock.unlock()
            NotificationCenter.default.post(name: .micCapturePersistentSilence, object: nil)
        }
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
        let needSignalCheck = !_sawSignalThisEngine
        lock.unlock()
        // Watchdog: latch the first non-silent buffer of this engine. Runs only
        // until signal is seen, so it costs nothing in the steady state.
        if needSignalCheck && MicCapture.amplitude(of: buffer).peak > 0.0005 {
            lock.lock(); _sawSignalThisEngine = true; lock.unlock()
        }
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

    /// Peak and RMS amplitude of a buffer, normalized to [0, 1] and read from
    /// whichever channel format is populated — float32, int16, or int32. Unlike
    /// `rmsLevel` (a gained UI meter that assumes the native float tap), this is
    /// an accurate measurement usable on the analyzer buffer too, which is
    /// int16. That format gap is exactly what silently zeroed the first cut of
    /// the `--probe-capture` smoke gate; keeping the logic here, tested by
    /// `AudioLevelTestCases`, means the gate can't misread audio as silence
    /// again. Returns (0, 0) for an empty or unreadable buffer.
    static func amplitude(of buffer: AVAudioPCMBuffer) -> (peak: Float, rms: Float) {
        let n = Int(buffer.frameLength)
        guard n > 0 else { return (0, 0) }
        var peak: Float = 0
        var sumSquares: Double = 0
        func accumulate(_ value: Float) {
            let a = abs(value)
            if a > peak { peak = a }
            sumSquares += Double(a) * Double(a)
        }
        if let ch = buffer.floatChannelData?.pointee {
            for i in 0..<n { accumulate(ch[i]) }
        } else if let ch = buffer.int16ChannelData?.pointee {
            for i in 0..<n { accumulate(Float(ch[i]) / 32768.0) }
        } else if let ch = buffer.int32ChannelData?.pointee {
            for i in 0..<n { accumulate(Float(Double(ch[i]) / 2_147_483_648.0)) }
        } else {
            return (0, 0)
        }
        let rms = Float((sumSquares / Double(n)).squareRoot())
        return (peak, rms)
    }
}
