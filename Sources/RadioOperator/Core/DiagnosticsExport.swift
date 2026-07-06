import Foundation
import OSLog

/// Local-only, opt-in diagnostics export: the last 24 hours of THIS process's
/// log entries, filtered to app-emitted subsystems, written to a file the
/// user picks. No telemetry, no network — the user reads and shares the file
/// (or doesn't) themselves.
///
/// Privacy is load-bearing here: the export is safe only because the app
/// never logs dictation/transcript/selection content — enforced by
/// `scripts/audit-logging.sh` in CI. The rendered header states that
/// guarantee so a recipient knows what they are (not) looking at.
enum DiagnosticsExport {
    /// The app's os_log subsystem. NSLog entries carry an empty subsystem, so
    /// both are "ours"; everything else (com.apple.*, framework chatter) is
    /// excluded — that is the subsystem filter.
    static let appSubsystem = "com.warroom.radiooperator"

    /// Pure filter: keep only lines the app itself emitted.
    static func shouldInclude(subsystem: String) -> Bool {
        subsystem.isEmpty || subsystem == appSubsystem
    }

    /// One log entry, decoupled from OSLogEntryLog so rendering is testable.
    struct Line: Equatable {
        let date: Date
        let level: String
        let subsystem: String
        let category: String
        let message: String
    }

    static let defaultWindow: TimeInterval = 24 * 3600

    /// Pure render: header + one line per entry, ISO-8601 timestamps.
    static func render(lines: [Line], generatedAt: Date,
                       window: TimeInterval = defaultWindow) -> String {
        let iso = ISO8601DateFormatter()
        var out = """
        # Radio Operator diagnostics
        # Generated: \(iso.string(from: generatedAt))
        # Window: last \(Int(window / 3600))h · this app process only · app-emitted subsystems only
        #
        # Radio Operator never logs dictation, transcript, or selection content
        # (enforced by scripts/audit-logging.sh in CI). Lines below are app and
        # framework STATUS messages only. This file was written locally and has
        # not been transmitted anywhere — review it before sharing.

        """
        if lines.isEmpty {
            out += "\n(no app log entries in the window)\n"
            return out
        }
        for line in lines {
            let sub = line.subsystem.isEmpty ? "NSLog" : line.subsystem
            let cat = line.category.isEmpty ? "" : "/\(line.category)"
            out += "\n\(iso.string(from: line.date)) [\(line.level)] \(sub)\(cat): \(line.message)"
        }
        out += "\n"
        return out
    }

    /// Reads this process's unified-log entries for the window via
    /// OSLogStore(scope: .currentProcessIdentifier), keeping only
    /// app-emitted (subsystem-filtered) entries.
    static func collect(window: TimeInterval = defaultWindow) throws -> [Line] {
        let store = try OSLogStore(scope: .currentProcessIdentifier)
        let position = store.position(date: Date().addingTimeInterval(-window))
        let entries = try store.getEntries(at: position)
        var lines: [Line] = []
        for entry in entries {
            guard let log = entry as? OSLogEntryLog,
                  shouldInclude(subsystem: log.subsystem) else { continue }
            lines.append(Line(date: log.date,
                              level: levelLabel(log.level),
                              subsystem: log.subsystem,
                              category: log.category,
                              message: log.composedMessage))
        }
        return lines
    }

    static func levelLabel(_ level: OSLogEntryLog.Level) -> String {
        switch level {
        case .undefined: return "undefined"
        case .debug: return "debug"
        case .info: return "info"
        case .notice: return "notice"
        case .error: return "error"
        case .fault: return "fault"
        @unknown default: return "unknown"
        }
    }

    /// Suggested filename for the save panel.
    static func suggestedFilename(for date: Date = Date()) -> String {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd-HHmm"
        return "radio-operator-diagnostics-\(df.string(from: date)).log"
    }
}
