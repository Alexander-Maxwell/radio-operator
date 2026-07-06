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
        if let flagIndex = args.firstIndex(of: "--probe-churn") {
            guard args.count > flagIndex + 1, let cycles = Int(args[flagIndex + 1]), cycles >= 1 else {
                print("usage: RadioOperator --probe-churn <cycles>   (>= 8 recommended for a D9 verdict)")
                exit(2)
            }
            let semaphore = DispatchSemaphore(value: 0)
            let box = ResultBox()
            Task {
                box.ok = await probeChurn(cycles: cycles)
                semaphore.signal()
            }
            semaphore.wait()
            exit(box.ok ? 0 : 1)
        }
        if let flagIndex = args.firstIndex(of: "--probe-soak") {
            guard args.count > flagIndex + 1, let seconds = Int(args[flagIndex + 1]), seconds >= 20 else {
                print("usage: RadioOperator --probe-soak <seconds>   (>= 20; 300 recommended)")
                exit(2)
            }
            let semaphore = DispatchSemaphore(value: 0)
            let box = ResultBox()
            Task {
                box.ok = await probeSoak(seconds: seconds)
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
            let locale = clip.locale.map { Locale(identifier: $0) } ?? Transcriber.defaultLocale
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

    // MARK: - Stress modes (device tier, manual — docs/device-checklist.md)

    /// D9 leak decision: FAIL only when RSS growth versus the post-warm-up
    /// baseline exceeds `thresholdPercent` on EVERY one of at least 3 samples.
    /// One sub-threshold sample means the signal is flapping, not proven — a
    /// single reading must never convict (the flapping-monitor lesson).
    /// Pure so the rule itself is unit-tested in the core tier.
    struct LeakVerdict: Equatable {
        /// False when there were not enough samples (< 3) or no baseline.
        let decided: Bool
        let fail: Bool
    }

    static func leakVerdict(baselineBytes: UInt64, sampleBytes: [UInt64],
                            thresholdPercent: Double = 50) -> LeakVerdict {
        guard baselineBytes > 0, sampleBytes.count >= 3 else {
            return LeakVerdict(decided: false, fail: false)
        }
        let allOver = sampleBytes.allSatisfy {
            growthPercent(baselineBytes: baselineBytes, sampleBytes: $0) > thresholdPercent
        }
        return LeakVerdict(decided: true, fail: allOver)
    }

    /// RSS growth of one sample over the baseline, in percent (can be negative).
    static func growthPercent(baselineBytes: UInt64, sampleBytes: UInt64) -> Double {
        guard baselineBytes > 0 else { return 0 }
        return (Double(sampleBytes) - Double(baselineBytes)) / Double(baselineBytes) * 100
    }

    /// Current resident set size via task_info(MACH_TASK_BASIC_INFO), or 0 on
    /// failure (which the verdict treats as undecidable, never as a FAIL).
    static func currentRSSBytes() -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let kr: kern_return_t = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return kr == KERN_SUCCESS ? info.resident_size : 0
    }

    /// A zero-filled PCM buffer in `format` — synthetic silence so churn/soak
    /// exercise the feed path even when the mic is unavailable or muted.
    static func silenceBuffer(format: AVAudioFormat, frames: AVAudioFrameCount) -> AVAudioPCMBuffer? {
        guard let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return nil }
        buf.frameLength = frames // AVAudioPCMBuffer allocations are zeroed
        return buf
    }

    private static func mbString(_ bytes: UInt64) -> String {
        String(format: "%.1f MB", Double(bytes) / 1_000_000)
    }

    private static func printSample(_ index: Int, of total: Int, rss: UInt64, baseline: UInt64) {
        let growth = growthPercent(baselineBytes: baseline, sampleBytes: rss)
        print(String(format: "PROBE-SAMPLE %d/%d RSS %@ (%+.1f%% vs baseline)",
                     index, total, mbString(rss), growth))
    }

    private static func printLeakVerdict(_ v: LeakVerdict, baseline: UInt64, samples: [UInt64]) -> Bool {
        guard v.decided else {
            print("PROBE-RESULT PASS (inconclusive — need a baseline plus 3-5 post-warm-up samples, D9)")
            return true
        }
        let growths = samples.map { growthPercent(baselineBytes: baseline, sampleBytes: $0) }
        let minG = growths.min() ?? 0
        let maxG = growths.max() ?? 0
        if v.fail {
            print(String(format: "PROBE-RESULT FAIL — RSS growth exceeded 50%% on every sample "
                + "(min %+.1f%%, max %+.1f%%) vs the post-warm-up baseline (D9)", minG, maxG))
            return false
        }
        print(String(format: "PROBE-RESULT PASS — RSS growth min %+.1f%%, max %+.1f%% "
            + "(FAIL requires >50%% on every one of 3-5 samples, D9); judge flapping from the samples above",
            minG, maxG))
        return true
    }

    /// `--probe-churn <n>`: n cycles of MicCapture subscribe → feed →
    /// unsubscribe plus Transcriber start → cancel, the teardown paths where
    /// session leaks hide. RSS baselined after warm-up cycles, then sampled
    /// 3-5 times across the measured cycles (D9).
    static func probeChurn(cycles: Int) async -> Bool {
        let locale = Transcriber.defaultLocale
        guard let format = await Transcriber.preferredFormat(locale: locale) else {
            print("PROBE-FAIL: no speech model/format for \(locale.identifier)")
            return false
        }
        let warmup = min(3, cycles)
        let measured = cycles - warmup
        print("PROBE-CHURN \(cycles) cycles (\(warmup) warm-up + \(measured) measured) — "
            + "MicCapture subscribe/feed/unsubscribe + Transcriber start/cancel per cycle")
        for i in 0..<warmup {
            await churnCycle(format: format, locale: locale, first: i == 0)
        }
        let baseline = currentRSSBytes()
        print("PROBE-BASELINE RSS \(mbString(baseline)) after \(warmup) warm-up cycles")
        guard measured > 0 else {
            return printLeakVerdict(LeakVerdict(decided: false, fail: false),
                                    baseline: baseline, samples: [])
        }
        let sampleCount = min(5, measured)
        let interval = max(1, Int((Double(measured) / Double(sampleCount)).rounded(.up)))
        var samples: [UInt64] = []
        for j in 1...measured {
            await churnCycle(format: format, locale: locale, first: false)
            if (j % interval == 0 || j == measured) && samples.count < 5 {
                let rss = currentRSSBytes()
                samples.append(rss)
                printSample(samples.count, of: sampleCount, rss: rss, baseline: baseline)
            }
        }
        return printLeakVerdict(leakVerdict(baselineBytes: baseline, sampleBytes: samples),
                                baseline: baseline, samples: samples)
    }

    /// One full session churn: subscribe the mic, spin up a real Transcriber,
    /// feed it (live buffers if the mic engine started, synthetic silence
    /// regardless), then tear both down.
    private static func churnCycle(format: AVAudioFormat, locale: Locale, first: Bool) async {
        let transcriber: any TranscriptionEngine = Transcriber(channel: .me)
        transcriber.onEvent = { _ in }
        transcriber.onError = { _ in } // session errors are expected noise under churn
        var token: UUID?
        do {
            token = try MicCapture.shared.subscribe(format: format, onBuffer: { buffer in
                transcriber.feed(buffer)
            })
        } catch {
            if first {
                print("PROBE-CHURN note: mic unavailable (\(error.localizedDescription)) — synthetic buffers only")
            }
        }
        do {
            try await transcriber.start(locale: locale)
        } catch {
            if first {
                print("PROBE-CHURN note: transcriber start failed (\(error.localizedDescription))")
            }
        }
        if let buf = silenceBuffer(format: format,
                                   frames: AVAudioFrameCount(max(1, Int(format.sampleRate / 10)))) {
            transcriber.feed(buf)
        }
        try? await Task.sleep(nanoseconds: 30_000_000)
        if let token { MicCapture.shared.unsubscribe(token) }
        transcriber.cancel()
    }

    /// `--probe-soak <seconds>`: hold one mic subscription + one live
    /// Transcriber session for the whole window and watch RSS. Baseline after
    /// a warm-up, then 3-5 evenly spaced samples; verdict per D9.
    static func probeSoak(seconds: Int) async -> Bool {
        let locale = Transcriber.defaultLocale
        guard let format = await Transcriber.preferredFormat(locale: locale) else {
            print("PROBE-FAIL: no speech model/format for \(locale.identifier)")
            return false
        }
        let transcriber: any TranscriptionEngine = Transcriber(channel: .me)
        transcriber.onEvent = { _ in }
        transcriber.onError = { message in print("PROBE-SOAK transcriber error: \(message)") }

        var token: UUID?
        do {
            token = try MicCapture.shared.subscribe(format: format, onBuffer: { buffer in
                transcriber.feed(buffer)
            })
        } catch {
            print("PROBE-SOAK note: mic unavailable (\(error.localizedDescription)) — feeding synthetic silence")
        }
        // No mic: feed real-time-rate silence so the session processes audio
        // for the whole soak instead of idling.
        var feeder: Task<Void, Never>?
        if token == nil {
            feeder = Task {
                let frames = AVAudioFrameCount(max(1, Int(format.sampleRate / 10)))
                while !Task.isCancelled {
                    if let buf = silenceBuffer(format: format, frames: frames) {
                        transcriber.feed(buf)
                    }
                    try? await Task.sleep(nanoseconds: 100_000_000)
                }
            }
        }
        do {
            try await transcriber.start(locale: locale)
        } catch {
            print("PROBE-FAIL: transcriber start failed (\(error.localizedDescription))")
            feeder?.cancel()
            if let token { MicCapture.shared.unsubscribe(token) }
            return false
        }

        let warmup = min(15, max(5, seconds / 5))
        let remaining = seconds - warmup
        print("PROBE-SOAK \(seconds)s (\(warmup)s warm-up + \(remaining)s measured), "
            + "mic \(token != nil ? "live" : "synthetic")")
        try? await Task.sleep(nanoseconds: UInt64(warmup) * 1_000_000_000)
        let baseline = currentRSSBytes()
        print("PROBE-BASELINE RSS \(mbString(baseline)) after \(warmup)s warm-up")

        let sampleCount = min(5, max(3, remaining / 10))
        let interval = Double(remaining) / Double(sampleCount)
        var samples: [UInt64] = []
        for k in 1...sampleCount {
            try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            let rss = currentRSSBytes()
            samples.append(rss)
            printSample(k, of: sampleCount, rss: rss, baseline: baseline)
        }

        feeder?.cancel()
        if let token { MicCapture.shared.unsubscribe(token) }
        _ = await transcriber.finishAndWait(timeout: 5.0)
        return printLeakVerdict(leakVerdict(baselineBytes: baseline, sampleBytes: samples),
                                baseline: baseline, samples: samples)
    }

    /// Pushes an audio file through the production Transcriber path. Returns
    /// the joined final transcript, or nil on failure. `verbose` prints the
    /// live event stream (the classic --probe-transcribe behavior); the WER
    /// probe runs quiet.
    @discardableResult
    static func transcribeFile(path: String, locale: Locale = Transcriber.defaultLocale,
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

            let transcriber: any TranscriptionEngine = Transcriber(channel: .me)
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
