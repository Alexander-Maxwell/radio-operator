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
        if args.contains("--probe-ask") {
            let semaphore = DispatchSemaphore(value: 0)
            Task {
                await probeAsk()
                semaphore.signal()
            }
            semaphore.wait()
            exit(0)
        }
        return false
    }

    /// Exercises the full Ask round-trip: seeds a throwaway meeting note, runs
    /// ClaudeService.ask against it via the real CLI/API path, and asserts a
    /// non-empty answer. Requires this machine's Claude auth (subscription or
    /// API key). Prints PROBE-RESULT PASS/FAIL. NOT part of `--run-tests`
    /// (needs network + auth + is slow).
    static func probeAsk() async {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("ro-probe-ask-\(UUID().uuidString)")
        let meetings = root.appendingPathComponent("Meetings")
        try? fm.createDirectory(at: meetings, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let note = """
        ---
        title: SIP Launch Sync
        date: 2026-07-02T14:00:00Z
        summary: done
        tags: [meeting]
        ---
        # SIP Launch Sync
        ## Decisions
        - White Claw Pineapple PHL launch moved to July 15 to align with the BevMo distributor.
        ## Action Items
        - [ ] Confirm the 11 PHL doors with the distributor — Maxwell
        ## Transcript
        **Me**: Are we still targeting the 8th for the White Claw launch?
        **Them**: No, we pushed it to July 15 so the BevMo distributor is ready.
        """
        try? note.write(to: meetings.appendingPathComponent("2026-07-02-1400 SIP Launch Sync.md"),
                        atomically: true, encoding: .utf8)

        let q = "What did we decide about the White Claw launch date, and who owns the follow-up?"
        print("PROBE-ASK question: \(q)")
        print("PROBE-ASK notesFolder: \(root.path)")
        do {
            let answer = try await ClaudeService.shared.ask(question: q, notesFolder: root, scope: .all)
            let ok = !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            print("PROBE-ASK answer:\n\(answer)")
            print("PROBE-RESULT \(ok ? "PASS" : "FAIL") — answer \(ok ? "non-empty" : "EMPTY")")
        } catch {
            print("PROBE-ASK error: \(error.localizedDescription)")
            print("PROBE-RESULT FAIL — ask threw (needs Claude auth/CLI in this session)")
        }
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
