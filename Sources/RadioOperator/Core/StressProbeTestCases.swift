import Foundation
import AVFoundation

/// Core-tier tests for the D9 leak-verdict logic behind `--probe-churn` /
/// `--probe-soak`. The probes themselves are device-tier (real mic, real
/// SpeechAnalyzer sessions — docs/device-checklist.md); the RULE that decides
/// PASS/FAIL is pure and must be provably flap-resistant: FAIL only when
/// growth exceeds 50% on EVERY one of 3-5 post-warm-up samples.
enum StressProbeTestCases {
    static func run(_ t: TestContext) {
        t.test("growth percent math") { t in
            t.expectEqual(ProbeRunner.growthPercent(baselineBytes: 100, sampleBytes: 150), 50, "+50%")
            t.expectEqual(ProbeRunner.growthPercent(baselineBytes: 200, sampleBytes: 100), -50, "-50%")
            t.expectEqual(ProbeRunner.growthPercent(baselineBytes: 100, sampleBytes: 100), 0, "flat")
            t.expectEqual(ProbeRunner.growthPercent(baselineBytes: 0, sampleBytes: 999), 0,
                          "zero baseline never divides")
        }

        t.test("under 3 samples is undecided, never FAIL") { t in
            let v = ProbeRunner.leakVerdict(baselineBytes: 100, sampleBytes: [400, 400])
            t.expect(!v.decided, "2 samples cannot decide")
            t.expect(!v.fail, "undecided is not a failure")
            let none = ProbeRunner.leakVerdict(baselineBytes: 100, sampleBytes: [])
            t.expect(!none.decided && !none.fail, "no samples cannot decide")
        }

        t.test("zero baseline is undecided") { t in
            let v = ProbeRunner.leakVerdict(baselineBytes: 0, sampleBytes: [100, 100, 100])
            t.expect(!v.decided && !v.fail, "no baseline, no verdict")
        }

        t.test("FAIL only when every sample exceeds 50%") { t in
            let v = ProbeRunner.leakVerdict(baselineBytes: 100, sampleBytes: [151, 200, 300])
            t.expect(v.decided, "3 samples decide")
            t.expect(v.fail, "all three over threshold → leak proven")
        }

        t.test("one sub-threshold sample (flap) blocks FAIL") { t in
            // The flapping-monitor lesson: a reading that dips back under the
            // threshold means the growth is not monotonic-proven — PASS.
            let v = ProbeRunner.leakVerdict(baselineBytes: 100, sampleBytes: [200, 149, 300, 400])
            t.expect(v.decided, "4 samples decide")
            t.expect(!v.fail, "one recovered sample → not a proven leak")
        }

        t.test("exactly 50% growth does not fail (strictly greater)") { t in
            let v = ProbeRunner.leakVerdict(baselineBytes: 100, sampleBytes: [150, 150, 150])
            t.expect(v.decided && !v.fail, "boundary is > not >=")
        }

        t.test("healthy plateau passes") { t in
            let v = ProbeRunner.leakVerdict(baselineBytes: 1_000_000,
                                            sampleBytes: [1_020_000, 990_000, 1_050_000, 1_010_000, 1_000_000])
            t.expect(v.decided && !v.fail, "steady RSS passes")
        }

        t.test("silence buffer is zero-filled at the requested length") { t in
            guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000,
                                             channels: 1, interleaved: false),
                  let buf = ProbeRunner.silenceBuffer(format: format, frames: 1600) else {
                t.expect(false, "format/buffer creation failed")
                return
            }
            t.expectEqual(buf.frameLength, 1600, "frameLength set")
            if let data = buf.floatChannelData?[0] {
                var nonZero = 0
                for i in 0..<Int(buf.frameLength) where data[i] != 0 { nonZero += 1 }
                t.expectEqual(nonZero, 0, "all frames silent")
            } else {
                t.expect(false, "no channel data")
            }
        }

        t.test("current RSS reads a plausible value") { t in
            let rss = ProbeRunner.currentRSSBytes()
            t.expect(rss > 1_000_000, "a running Swift process is over 1 MB resident")
        }
    }
}
