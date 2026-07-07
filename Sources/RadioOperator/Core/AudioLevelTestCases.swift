import Foundation
import AVFoundation

/// Tests for MicCapture.amplitude — the format-agnostic level read behind the
/// `--probe-capture` live-mic smoke gate. Deterministic and offline: buffers
/// are synthesized in float32, int16, and int32 with no engine, mic, or TCC.
/// The int16 cases are the regression guard: the first cut of the probe read
/// only `floatChannelData`, so it measured the (int16) analyzer buffer as pure
/// silence and would have green-lit a dead mic.
enum AudioLevelTestCases {
    private static func floatFormat(rate: Double = 16_000) -> AVAudioFormat {
        AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate,
                      channels: 1, interleaved: false)!
    }

    private static func floatBuffer(frames: AVAudioFrameCount, fill: Float) -> AVAudioPCMBuffer {
        let buf = AVAudioPCMBuffer(pcmFormat: floatFormat(), frameCapacity: max(frames, 1))!
        buf.frameLength = frames
        if let data = buf.floatChannelData?[0] {
            for i in 0..<Int(frames) { data[i] = fill }
        }
        return buf
    }

    private static func int16Buffer(frames: AVAudioFrameCount, fill: Int16) -> AVAudioPCMBuffer {
        let fmt = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000,
                                channels: 1, interleaved: false)!
        let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: max(frames, 1))!
        buf.frameLength = frames
        if let data = buf.int16ChannelData?[0] {
            for i in 0..<Int(frames) { data[i] = fill }
        }
        return buf
    }

    private static func int32Buffer(frames: AVAudioFrameCount, fill: Int32) -> AVAudioPCMBuffer {
        let fmt = AVAudioFormat(commonFormat: .pcmFormatInt32, sampleRate: 16_000,
                                channels: 1, interleaved: false)!
        let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: max(frames, 1))!
        buf.frameLength = frames
        if let data = buf.int32ChannelData?[0] {
            for i in 0..<Int(frames) { data[i] = fill }
        }
        return buf
    }

    static func run(_ t: TestContext) {
        t.test("float32 constant reads exact peak and rms") { t in
            let (peak, rms) = MicCapture.amplitude(of: floatBuffer(frames: 512, fill: 0.5))
            t.expect(abs(peak - 0.5) < 0.001, "peak ~0.5 — got \(peak)")
            t.expect(abs(rms - 0.5) < 0.001, "rms ~0.5 (constant) — got \(rms)")
        }

        t.test("float32 silence reads zero") { t in
            let (peak, rms) = MicCapture.amplitude(of: floatBuffer(frames: 512, fill: 0))
            t.expect(peak == 0, "peak 0 for silence — got \(peak)")
            t.expect(rms == 0, "rms 0 for silence — got \(rms)")
        }

        // The regression guard: int16 audio must NOT read as silence.
        t.test("int16 non-silent reads real amplitude, not zero") { t in
            let (peak, rms) = MicCapture.amplitude(of: int16Buffer(frames: 512, fill: 16_384))
            t.expect(peak > 0.4, "int16 half-scale must register — got peak \(peak)")
            t.expect(abs(peak - 0.5) < 0.001, "16384/32768 == 0.5 — got \(peak)")
            t.expect(rms > 0.4, "int16 rms non-zero — got \(rms)")
        }

        t.test("int16 silence reads zero") { t in
            let (peak, _) = MicCapture.amplitude(of: int16Buffer(frames: 512, fill: 0))
            t.expect(peak == 0, "peak 0 for int16 silence — got \(peak)")
        }

        t.test("int32 non-silent reads real amplitude, not zero") { t in
            let (peak, _) = MicCapture.amplitude(of: int32Buffer(frames: 256, fill: 1_073_741_824))
            t.expect(peak > 0.4, "int32 half-scale must register — got peak \(peak)")
        }

        t.test("empty buffer is (0,0), not a crash") { t in
            let (peak, rms) = MicCapture.amplitude(of: floatBuffer(frames: 0, fill: 0.9))
            t.expect(peak == 0 && rms == 0, "empty buffer yields zero — got (\(peak), \(rms))")
        }
    }
}
