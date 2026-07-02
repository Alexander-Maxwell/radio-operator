import Foundation
import AVFoundation

/// Headless probes runnable without TCC prompts: `RadioOperator --probe-transcribe
/// <audiofile>` pushes a file through the production Transcriber path and
/// prints events. Used to validate the SpeechAnalyzer contract in CI/dev.
enum ProbeRunner {
    /// Returns true if a probe was requested and handled (caller exits).
    static func handleIfRequested() -> Bool {
        let args = CommandLine.arguments
        if let flagIndex = args.firstIndex(of: "--probe-transcribe") {
            guard args.count > flagIndex + 1 else {
                print("usage: RadioOperator --probe-transcribe <audiofile>")
                exit(2)
            }
            let path = args[flagIndex + 1]
            let semaphore = DispatchSemaphore(value: 0)
            Task {
                await transcribeFile(path: path)
                semaphore.signal()
            }
            semaphore.wait()
            exit(0)
        }
        if args.contains("--probe-mics") {
            let def = AudioInputDevices.defaultInput()
            print("default input: \(def?.name ?? "none") [\(def?.uid ?? "-")]")
            for d in AudioInputDevices.list() {
                print("device: \(d.name) | uid: \(d.uid) | channels: \(d.inputChannels)")
            }
            exit(0)
        }
        if let flagIndex = args.firstIndex(of: "--probe-dual") {
            guard args.count > flagIndex + 2 else {
                print("usage: RadioOperator --probe-dual <file1> <file2>")
                exit(2)
            }
            let a = args[flagIndex + 1], b = args[flagIndex + 2]
            let semaphore = DispatchSemaphore(value: 0)
            Task {
                // Meeting-mode shape: two concurrent SpeechAnalyzer sessions.
                async let first: Void = transcribeFile(path: a)
                async let second: Void = transcribeFile(path: b)
                _ = await (first, second)
                semaphore.signal()
            }
            semaphore.wait()
            exit(0)
        }
        return false
    }

    static func transcribeFile(path: String) async {
        do {
            guard let format = await Transcriber.preferredFormat() else {
                print("PROBE-FAIL: no preferred format")
                return
            }
            print("PROBE: analyzer format \(format)")
            let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
            guard let converter = AVAudioConverter(from: file.processingFormat, to: format) else {
                print("PROBE-FAIL: no converter")
                return
            }

            let transcriber = Transcriber(channel: .me)
            var finals: [String] = []
            let lock = NSLock()
            transcriber.onEvent = { event in
                lock.lock()
                defer { lock.unlock() }
                if event.isFinal {
                    finals.append(event.text)
                    print("FINAL: \(event.text)")
                } else {
                    print("volatile: \(event.text)")
                }
            }
            transcriber.onError = { print("PROBE-ERROR: \($0)") }

            // Feed in ~0.5s chunks like live capture, BEFORE start() completes
            // for the first chunks (validates pre-roll buffering).
            let feedTask = Task {
                let chunkFrames = AVAudioFrameCount(file.processingFormat.sampleRate / 2)
                while file.framePosition < file.length {
                    guard let inBuf = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                                       frameCapacity: chunkFrames) else { break }
                    try? file.read(into: inBuf, frameCount: chunkFrames)
                    if inBuf.frameLength == 0 { break }
                    if let out = MicCapture.convert(inBuf, with: converter, to: format) {
                        transcriber.feed(out)
                    }
                }
            }

            let started = Date()
            try await transcriber.start()
            await feedTask.value
            let completed = await transcriber.finishAndWait(timeout: 10.0)
            let elapsed = Date().timeIntervalSince(started)
            lock.lock()
            let text = finals.joined(separator: " ")
            lock.unlock()
            print("PROBE-RESULT completed=\(completed) elapsed=\(String(format: "%.2f", elapsed))s")
            print("PROBE-TEXT: \(text)")
        } catch {
            print("PROBE-FAIL: \(error)")
        }
    }
}
