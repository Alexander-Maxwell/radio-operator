import Foundation
import AVFoundation

/// Final-pass transcription via Groq-hosted Whisper — lever 4 of the
/// speech-impediment plan. Apple SpeechAnalyzer keeps powering the LIVE pill
/// preview; on release the dictation's accumulated mic audio is sent to
/// Whisper large-v3-turbo (markedly more robust to atypical speech, and
/// faster than real-time on Groq), and its transcript becomes the raw text.
/// Apple's transcript is the fallback on ANY failure, so this pass can only
/// ever improve recognition, never lose a dictation.

/// Thread-safe accumulator for the dictation's mic audio. Buffers arrive on
/// the audio thread in the analyzer's preferred format (mono float); channel 0
/// is kept in memory for the life of one dictation and encoded to 16-bit PCM
/// WAV on demand. Nothing touches disk.
final class DictationAudioTap: @unchecked Sendable {
    private let lock = NSLock()
    private var samples: [Float] = []
    private var sampleRate: Double = 0

    /// ~14 minutes at 16 kHz ≈ 22 MB WAV — safely under Groq's 25 MB upload
    /// cap. Longer dictations keep the first 14 minutes (and in practice
    /// Apple's transcript wins the fallback for marathon sessions).
    private static let maxSamples = 16_000 * 60 * 14

    func append(_ buffer: AVAudioPCMBuffer) {
        guard let channel = buffer.floatChannelData?[0] else { return }
        let count = Int(buffer.frameLength)
        guard count > 0 else { return }
        lock.lock()
        defer { lock.unlock() }
        if sampleRate == 0 { sampleRate = buffer.format.sampleRate }
        guard samples.count < Self.maxSamples else { return }
        samples.append(contentsOf: UnsafeBufferPointer(start: channel, count: count))
    }

    var duration: TimeInterval {
        lock.lock()
        defer { lock.unlock() }
        return sampleRate > 0 ? Double(samples.count) / sampleRate : 0
    }

    func wavData() -> Data? {
        lock.lock()
        let samples = self.samples
        let rate = self.sampleRate
        lock.unlock()
        guard rate > 0, !samples.isEmpty else { return nil }
        return DictationAudioTap.wav(samples: samples, sampleRate: Int(rate))
    }

    /// Pure 16-bit mono PCM WAV encoding (44-byte canonical header) — unit
    /// tested. Floats are clipped to [-1, 1]; arm64 is little-endian, which is
    /// exactly what WAV wants.
    static func wav(samples: [Float], sampleRate: Int) -> Data {
        var ints = [Int16](repeating: 0, count: samples.count)
        for i in samples.indices {
            ints[i] = Int16(max(-1.0, min(1.0, samples[i])) * 32767)
        }
        let pcm = ints.withUnsafeBufferPointer { Data(buffer: $0) }

        var d = Data(capacity: 44 + pcm.count)
        func le32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func le16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        d.append(contentsOf: Array("RIFF".utf8))
        le32(UInt32(36 + pcm.count))
        d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8))
        le32(16)                       // PCM fmt chunk size
        le16(1)                        // PCM
        le16(1)                        // mono
        le32(UInt32(sampleRate))
        le32(UInt32(sampleRate * 2))   // byte rate (mono 16-bit)
        le16(2)                        // block align
        le16(16)                       // bits per sample
        d.append(contentsOf: Array("data".utf8))
        le32(UInt32(pcm.count))
        d.append(pcm)
        return d
    }
}

/// Minimal client for Groq's OpenAI-compatible `audio/transcriptions`
/// endpoint. The prompt/body builders are pure statics so they are unit
/// testable without a network.
enum GroqWhisper {
    /// Whisper biases toward the prompt's spellings, so the user's dictionary
    /// terms transcribe as themselves ("Gopuff", not "go puff"). Whisper's
    /// prompt window is small (~224 tokens) — keep it modest.
    static func vocabularyPrompt(_ vocabulary: [String]) -> String {
        let terms = vocabulary
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !terms.isEmpty else { return "" }
        return "Vocabulary: " + terms.prefix(40).joined(separator: ", ") + "."
    }

    static func multipartBody(boundary: String, wav: Data, model: String,
                              prompt: String) -> Data {
        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
        }
        field("model", model)
        field("language", "en")
        field("temperature", "0")
        field("response_format", "text")
        if !prompt.isEmpty { field("prompt", prompt) }
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"dictation.wav\"\r\nContent-Type: audio/wav\r\n\r\n".utf8))
        body.append(wav)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        return body
    }

    /// One HTTPS call; `response_format=text` means the body IS the transcript.
    static func transcribe(wav: Data, key: String, vocabulary: [String]) async throws -> String {
        var request = URLRequest(url: URL(string: "https://api.groq.com/openai/v1/audio/transcriptions")!)
        request.httpMethod = "POST"
        let boundary = "radio-operator-\(UUID().uuidString)"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)",
                         forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 10
        request.httpBody = multipartBody(boundary: boundary, wav: wav,
                                         model: "whisper-large-v3-turbo",
                                         prompt: vocabularyPrompt(vocabulary))
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let msg = String(data: data, encoding: .utf8) ?? "no response"
            throw NSError(domain: "GroqWhisper", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: String(msg.prefix(200))])
        }
        return (String(data: data, encoding: .utf8) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
