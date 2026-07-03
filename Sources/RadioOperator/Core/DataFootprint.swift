import Foundation

/// Computes what Radio Operator is storing on this Mac, for the Privacy pane's
/// "Your data" readout. Everything here is local: no network, no account.
enum DataFootprint {
    struct Snapshot: Equatable {
        var dictations: Int
        var meetings: Int
        var notesBytes: Int64
        var audioBytes: Int64

        static let empty = Snapshot(dictations: 0, meetings: 0, notesBytes: 0, audioBytes: 0)
    }

    /// Recursive on-disk size of a directory in bytes (0 if it doesn't exist).
    static func directorySize(_ url: URL) -> Int64 {
        let fm = FileManager.default
        guard let e = fm.enumerator(at: url, includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .fileSizeKey]) else {
            return 0
        }
        var total: Int64 = 0
        for case let f as URL in e {
            let v = try? f.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileSizeKey])
            total += Int64(v?.totalFileAllocatedSize ?? v?.fileSize ?? 0)
        }
        return total
    }

    /// Deterministic, locale-independent size label (base-1000, one decimal for
    /// MB/GB). Pure so it can be unit-tested without a formatter's locale drift.
    static func humanSize(_ bytes: Int64) -> String {
        if bytes < 1000 { return "\(bytes) B" }
        let kb = Double(bytes) / 1000
        if kb < 1000 { return "\(Int(kb.rounded())) KB" }
        let mb = kb / 1000
        if mb < 1000 { return String(format: "%.1f MB", mb) }
        return String(format: "%.1f GB", mb / 1000)
    }
}
