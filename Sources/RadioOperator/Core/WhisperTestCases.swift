import Foundation

/// Pure-function coverage for the Whisper final pass: the WAV encoder (a
/// malformed header would fail every upload silently) and the prompt/body
/// builders.
enum WhisperTestCases {
    static func run(_ t: TestContext) {

        t.test("wav encoder: header, size, sample rate, clipping") { t in
            let wav = DictationAudioTap.wav(samples: [0, 0.5, -0.5, 2.0, -2.0],
                                            sampleRate: 16_000)
            t.expectEqual(wav.count, 44 + 10, "44-byte header + 2 bytes/sample")
            t.expectEqual(String(data: wav.prefix(4), encoding: .ascii), "RIFF", "RIFF magic")
            t.expectEqual(String(data: wav.subdata(in: 8..<12), encoding: .ascii), "WAVE", "WAVE magic")
            t.expectEqual(String(data: wav.subdata(in: 36..<40), encoding: .ascii), "data", "data chunk")

            func u32(_ at: Int) -> UInt32 {
                let b = wav.subdata(in: at..<(at + 4))
                return UInt32(b[0]) | UInt32(b[1]) << 8 | UInt32(b[2]) << 16 | UInt32(b[3]) << 24
            }
            func u16(_ at: Int) -> UInt16 {
                let b = wav.subdata(in: at..<(at + 2))
                return UInt16(b[0]) | UInt16(b[1]) << 8
            }
            t.expectEqual(Int(u32(24)), 16_000, "sample rate")
            t.expectEqual(Int(u16(22)), 1, "mono")
            t.expectEqual(Int(u16(34)), 16, "16-bit")
            t.expectEqual(Int(u32(40)), 10, "data chunk size")

            // Out-of-range floats clip to full scale instead of wrapping.
            func s16(_ at: Int) -> Int16 {
                let b = wav.subdata(in: at..<(at + 2))
                return Int16(bitPattern: UInt16(b[0]) | UInt16(b[1]) << 8)
            }
            t.expectEqual(s16(44 + 6), Int16(32767), "+2.0 clips to +32767")
            t.expectEqual(s16(44 + 8), Int16(-32767), "-2.0 clips to -32767")
        }

        t.test("vocabulary prompt: trims, caps at 40, empty stays empty") { t in
            t.expectEqual(GroqWhisper.vocabularyPrompt([]), "", "no vocab, no prompt")
            t.expectEqual(GroqWhisper.vocabularyPrompt(["  ", ""]), "", "blank entries drop out")
            t.expectEqual(GroqWhisper.vocabularyPrompt([" Gopuff ", "BevMo"]),
                          "Vocabulary: Gopuff, BevMo.", "joined and trimmed")
            let many = (1...60).map { "w\($0)" }
            let prompt = GroqWhisper.vocabularyPrompt(many)
            t.expectEqual(prompt.contains("w40"), true, "40th term kept")
            t.expectEqual(prompt.contains("w41"), false, "41st term capped")
        }

        t.test("multipart body carries model, file, and terminator") { t in
            let wav = Data([1, 2, 3])
            let body = GroqWhisper.multipartBody(boundary: "BB", wav: wav,
                                                 model: "whisper-large-v3-turbo",
                                                 prompt: "Vocabulary: Gopuff.")
            let text = String(decoding: body, as: UTF8.self)
            t.expectEqual(text.contains("name=\"model\"\r\n\r\nwhisper-large-v3-turbo"), true, "model field")
            t.expectEqual(text.contains("name=\"response_format\"\r\n\r\ntext"), true, "text response")
            t.expectEqual(text.contains("name=\"prompt\"\r\n\r\nVocabulary: Gopuff."), true, "prompt field")
            t.expectEqual(text.contains("filename=\"dictation.wav\""), true, "file part")
            t.expectEqual(text.hasSuffix("--BB--\r\n"), true, "closing boundary")
        }
    }
}
