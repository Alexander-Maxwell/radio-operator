import Foundation
import AVFoundation

/// Tests for MicCapture.convert — the 48k→16k mono resample every dictation
/// buffer passes through on its way to the transcriber. Deterministic and
/// offline: buffers are synthesized, no engine, no mic, no TCC.
enum MicConvertTestCases {
    private static func format(rate: Double) -> AVAudioFormat {
        AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate,
                      channels: 1, interleaved: false)!
    }

    private static func buffer(rate: Double, frames: AVAudioFrameCount,
                               fill: Float? = nil) -> AVAudioPCMBuffer {
        let buf = AVAudioPCMBuffer(pcmFormat: format(rate: rate), frameCapacity: max(frames, 1))!
        buf.frameLength = frames
        if let fill, let data = buf.floatChannelData?[0] {
            for i in 0..<Int(frames) { data[i] = fill }
        }
        return buf
    }

    static func run(_ t: TestContext) {
        t.test("48k to 16k mono downsample") { t in
            let inFmt = format(rate: 48_000)
            let outFmt = format(rate: 16_000)
            guard let converter = AVAudioConverter(from: inFmt, to: outFmt) else {
                t.expect(false, "converter creation failed")
                return
            }
            let input = buffer(rate: 48_000, frames: 4800, fill: 0.25)
            guard let out = MicCapture.convert(input, with: converter, to: outFmt) else {
                t.expect(false, "conversion returned nil")
                return
            }
            t.expectEqual(out.format.sampleRate, 16_000, "output sample rate")
            t.expectEqual(out.format.channelCount, 1, "mono output")
            // 4800 @ 48k is 100ms → ~1600 frames @ 16k, minus resampler priming.
            t.expect(out.frameLength > 800 && out.frameLength <= 1664,
                     "frame count near 1600 — got \(out.frameLength)")
        }

        t.test("zero-length buffer does not crash and yields nothing") { t in
            let inFmt = format(rate: 48_000)
            let outFmt = format(rate: 16_000)
            guard let converter = AVAudioConverter(from: inFmt, to: outFmt) else {
                t.expect(false, "converter creation failed")
                return
            }
            let empty = buffer(rate: 48_000, frames: 0)
            let out = MicCapture.convert(empty, with: converter, to: outFmt)
            t.expect(out == nil || out!.frameLength == 0, "no frames from an empty buffer")
        }

        t.test("full-scale input stays finite and unclipped") { t in
            let inFmt = format(rate: 48_000)
            let outFmt = format(rate: 16_000)
            guard let converter = AVAudioConverter(from: inFmt, to: outFmt) else {
                t.expect(false, "converter creation failed")
                return
            }
            let loud = buffer(rate: 48_000, frames: 4800, fill: 1.0)
            guard let out = MicCapture.convert(loud, with: converter, to: outFmt),
                  let data = out.floatChannelData?[0] else {
                t.expect(false, "conversion returned nil")
                return
            }
            var allFinite = true
            var maxMagnitude: Float = 0
            for i in 0..<Int(out.frameLength) {
                let v = data[i]
                if !v.isFinite { allFinite = false }
                maxMagnitude = max(maxMagnitude, abs(v))
            }
            t.expect(allFinite, "no NaN/inf in resampled full-scale audio")
            // DC at 1.0 passes through; allow small resampler-filter overshoot.
            t.expect(maxMagnitude <= 1.5, "no runaway amplitude — got \(maxMagnitude)")
        }

        t.test("matching format short-circuits to the same buffer") { t in
            let fmt = format(rate: 16_000)
            guard let converter = AVAudioConverter(from: fmt, to: fmt) else {
                t.expect(false, "converter creation failed")
                return
            }
            let input = buffer(rate: 16_000, frames: 160, fill: 0.5)
            let out = MicCapture.convert(input, with: converter, to: fmt)
            t.expect(out === input, "no copy when formats already match")
        }
    }
}
