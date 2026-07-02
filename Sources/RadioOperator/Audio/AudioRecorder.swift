import Foundation
import AVFoundation

/// Optional local audio retention: encodes PCM buffers to an .m4a file.
/// One instance per channel; writes serialized on a private queue.
final class AudioRecorder: @unchecked Sendable {
    private var file: AVAudioFile?
    private let queue = DispatchQueue(label: "com.warroom.radiooperator.recorder")

    init?(url: URL, format: AVAudioFormat) {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: format.channelCount,
            AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue,
        ]
        guard let f = try? AVAudioFile(forWriting: url, settings: settings,
                                       commonFormat: format.commonFormat,
                                       interleaved: format.isInterleaved) else { return nil }
        file = f
    }

    func write(_ buffer: AVAudioPCMBuffer) {
        queue.async { [weak self] in
            try? self?.file?.write(from: buffer)
        }
    }

    func finish() {
        queue.sync { file = nil } // AVAudioFile finalizes on dealloc
    }
}
