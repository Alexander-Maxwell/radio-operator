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
                async let first = transcribeFile(path: a)
                async let second = transcribeFile(path: b)
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
        if let flagIndex = args.firstIndex(of: "--probe-wer") {
            guard args.count > flagIndex + 1 else {
                print("usage: RadioOperator --probe-wer <manifest.json>")
                print("       manifest: JSON array of {\"audio\": path, \"reference\": text, \"locale\"?: id}")
                exit(2)
            }
            let manifestPath = args[flagIndex + 1]
            let semaphore = DispatchSemaphore(value: 0)
            let box = ResultBox()
            Task {
                box.ok = await probeWER(manifestPath: manifestPath)
                semaphore.signal()
            }
            semaphore.wait()
            exit(box.ok ? 0 : 1)
        }
        return false
    }

    /// Crosses the Task/semaphore boundary in the probe entry points.
    private final class ResultBox: @unchecked Sendable {
        var ok = false
    }

    // MARK: - WER benchmark

    struct WERClip: Decodable {
        let audio: String
        let reference: String
        let locale: String?
    }

    /// Runs every clip in the manifest through the production Transcriber path
    /// and scores it against the reference transcript. Relative audio paths
    /// resolve against the manifest's directory, so a clip set can live
    /// anywhere as a folder. Prints per-clip and aggregate WER/CER plus one
    /// machine-readable `WER-JSON` line for tooling.
    static func probeWER(manifestPath: String) async -> Bool {
        guard let data = FileManager.default.contents(atPath: manifestPath),
              let clips = try? JSONDecoder().decode([WERClip].self, from: data),
              !clips.isEmpty else {
            print("PROBE-FAIL: manifest unreadable or empty — expected a JSON array of {audio, reference, locale?}")
            return false
        }
        let manifestDir = URL(fileURLWithPath: manifestPath).deletingLastPathComponent()

        var aggregateWER = WordErrorRate.Score()
        var aggregateCER = WordErrorRate.Score()
        var perClip: [[String: Any]] = []
        var transcriptionFailures = 0

        for clip in clips {
            let audioURL = clip.audio.hasPrefix("/")
                ? URL(fileURLWithPath: clip.audio)
                : manifestDir.appendingPathComponent(clip.audio)
            let locale = Locale(identifier: clip.locale ?? "en_US")
            guard let hypothesis = await transcribeFile(path: audioURL.path, locale: locale,
                                                        verbose: false) else {
                print("CLIP \(clip.audio): TRANSCRIPTION FAILED")
                transcriptionFailures += 1
                continue
            }
            let wer = WordErrorRate.score(reference: clip.reference, hypothesis: hypothesis)
            let cer = WordErrorRate.characterScore(reference: clip.reference, hypothesis: hypothesis)
            aggregateWER.add(wer)
            aggregateCER.add(cer)
            print("CLIP \(clip.audio): WER \(WordErrorRate.percent(wer.rate)) "
                + "(S\(wer.substitutions) D\(wer.deletions) I\(wer.insertions) / \(wer.referenceCount) words) "
                + "CER \(WordErrorRate.percent(cer.rate))")
            perClip.append([
                "audio": clip.audio,
                "wer": wer.rate,
                "cer": cer.rate,
                "sub": wer.substitutions, "del": wer.deletions, "ins": wer.insertions,
                "refWords": wer.referenceCount,
            ])
        }

        guard !perClip.isEmpty else {
            print("PROBE-FAIL: no clip transcribed")
            return false
        }
        print("AGGREGATE: WER \(WordErrorRate.percent(aggregateWER.rate)) "
            + "over \(aggregateWER.referenceCount) reference words in \(perClip.count) clips"
            + (transcriptionFailures > 0 ? " (\(transcriptionFailures) clips FAILED to transcribe)" : "")
            + " | CER \(WordErrorRate.percent(aggregateCER.rate))")
        let summary: [String: Any] = [
            "aggregateWER": aggregateWER.rate,
            "aggregateCER": aggregateCER.rate,
            "clips": perClip,
            "failures": transcriptionFailures,
        ]
        if let json = try? JSONSerialization.data(withJSONObject: summary, options: [.sortedKeys]),
           let line = String(data: json, encoding: .utf8) {
            print("WER-JSON \(line)")
        }
        return transcriptionFailures == 0
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

    /// Pushes an audio file through the production Transcriber path. Returns
    /// the joined final transcript, or nil on failure. `verbose` prints the
    /// live event stream (the classic --probe-transcribe behavior); the WER
    /// probe runs quiet.
    @discardableResult
    static func transcribeFile(path: String, locale: Locale = Locale(identifier: "en_US"),
                               verbose: Bool = true) async -> String? {
        do {
            guard let format = await Transcriber.preferredFormat(locale: locale) else {
                print("PROBE-FAIL: no preferred format for \(locale.identifier)")
                return nil
            }
            if verbose { print("PROBE: analyzer format \(format)") }
            let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
            guard let converter = AVAudioConverter(from: file.processingFormat, to: format) else {
                print("PROBE-FAIL: no converter")
                return nil
            }

            let transcriber = Transcriber(channel: .me)
            var finals: [String] = []
            let lock = NSLock()
            transcriber.onEvent = { event in
                lock.lock()
                defer { lock.unlock() }
                if event.isFinal {
                    finals.append(event.text)
                    if verbose { print("FINAL: \(event.text)") }
                } else if verbose {
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
            try await transcriber.start(locale: locale)
            await feedTask.value
            let completed = await transcriber.finishAndWait(timeout: 10.0)
            let elapsed = Date().timeIntervalSince(started)
            lock.lock()
            let text = finals.joined(separator: " ")
            lock.unlock()
            if verbose {
                print("PROBE-RESULT completed=\(completed) elapsed=\(String(format: "%.2f", elapsed))s")
                print("PROBE-TEXT: \(text)")
            }
            return text
        } catch {
            print("PROBE-FAIL: \(error)")
            return nil
        }
    }
}
