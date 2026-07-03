import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// SQLite-backed dictation history. Serialized through its own queue; safe to
/// call from any thread.
final class HistoryStore: @unchecked Sendable {
    static let shared: HistoryStore = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Radio Operator", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return HistoryStore(path: dir.appendingPathComponent("history.sqlite").path)
    }()

    private var db: OpaquePointer?
    private let queue = DispatchQueue(label: "com.warroom.radiooperator.history")

    /// Internal (not private) so tests can run against a throwaway file.
    init(path: String) {
        queue.sync {
            guard sqlite3_open(path, &db) == SQLITE_OK else {
                NSLog("HistoryStore: failed to open \(path)")
                db = nil
                return
            }
            exec("""
                CREATE TABLE IF NOT EXISTS dictations (
                  id INTEGER PRIMARY KEY AUTOINCREMENT,
                  ts REAL NOT NULL,
                  raw TEXT NOT NULL,
                  cleaned TEXT NOT NULL,
                  app_bundle_id TEXT,
                  duration_ms INTEGER NOT NULL DEFAULT 0,
                  paste_ok INTEGER NOT NULL DEFAULT 1
                );
                """)
        }
    }

    private func exec(_ sql: String) {
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &err) != SQLITE_OK {
            NSLog("HistoryStore exec error: \(err.map { String(cString: $0) } ?? "?")")
            sqlite3_free(err)
        }
    }

    @discardableResult
    func record(raw: String, cleaned: String, appBundleID: String?,
                durationMs: Int, pasteOK: Bool, at ts: Date = Date()) -> Int64 {
        queue.sync {
            guard let db else { return -1 }
            var stmt: OpaquePointer?
            let sql = "INSERT INTO dictations (ts, raw, cleaned, app_bundle_id, duration_ms, paste_ok) VALUES (?,?,?,?,?,?)"
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return -1 }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_double(stmt, 1, ts.timeIntervalSince1970)
            sqlite3_bind_text(stmt, 2, raw, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 3, cleaned, -1, SQLITE_TRANSIENT)
            if let appBundleID {
                sqlite3_bind_text(stmt, 4, appBundleID, -1, SQLITE_TRANSIENT)
            } else {
                sqlite3_bind_null(stmt, 4)
            }
            sqlite3_bind_int(stmt, 5, Int32(durationMs))
            sqlite3_bind_int(stmt, 6, pasteOK ? 1 : 0)
            guard sqlite3_step(stmt) == SQLITE_DONE else { return -1 }
            return sqlite3_last_insert_rowid(db)
        }
    }

    func recent(limit: Int = 200) -> [DictationRecord] {
        queue.sync {
            guard let db else { return [] }
            var stmt: OpaquePointer?
            let sql = "SELECT id, ts, raw, cleaned, app_bundle_id, duration_ms, paste_ok FROM dictations ORDER BY ts DESC LIMIT ?"
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_int(stmt, 1, Int32(limit))
            var out: [DictationRecord] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                out.append(HistoryStore.row(stmt))
            }
            return out
        }
    }

    /// Case-insensitive substring search over raw and cleaned text.
    func search(query: String, limit: Int = 200) -> [DictationRecord] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return recent(limit: limit) }
        let escaped = trimmed
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
        let pattern = "%\(escaped)%"
        return queue.sync {
            guard let db else { return [] }
            var stmt: OpaquePointer?
            let sql = """
                SELECT id, ts, raw, cleaned, app_bundle_id, duration_ms, paste_ok FROM dictations
                WHERE raw LIKE ?1 ESCAPE '\\' OR cleaned LIKE ?1 ESCAPE '\\'
                ORDER BY ts DESC LIMIT ?2
                """
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, pattern, -1, SQLITE_TRANSIENT)
            sqlite3_bind_int(stmt, 2, Int32(limit))
            var out: [DictationRecord] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                out.append(HistoryStore.row(stmt))
            }
            return out
        }
    }

    /// Deletes rows recorded before the cutoff.
    func prune(olderThan cutoff: Date) {
        queue.sync {
            guard let db else { return }
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, "DELETE FROM dictations WHERE ts < ?", -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_double(stmt, 1, cutoff.timeIntervalSince1970)
            sqlite3_step(stmt)
        }
    }

    /// Deletes every dictation row.
    func deleteAll() {
        queue.sync {
            exec("DELETE FROM dictations")
        }
    }

    /// Total dictation rows (uncapped, for the Privacy "Your data" readout).
    func count() -> Int {
        queue.sync {
            guard let db else { return 0 }
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM dictations", -1, &stmt, nil) == SQLITE_OK else { return 0 }
            defer { sqlite3_finalize(stmt) }
            return sqlite3_step(stmt) == SQLITE_ROW ? Int(sqlite3_column_int64(stmt, 0)) : 0
        }
    }

    private static func row(_ stmt: OpaquePointer?) -> DictationRecord {
        DictationRecord(
            id: sqlite3_column_int64(stmt, 0),
            timestamp: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 1)),
            rawText: String(cString: sqlite3_column_text(stmt, 2)),
            cleanedText: String(cString: sqlite3_column_text(stmt, 3)),
            appBundleID: sqlite3_column_text(stmt, 4).map { String(cString: $0) },
            durationMs: Int(sqlite3_column_int(stmt, 5)),
            pasteOK: sqlite3_column_int(stmt, 6) == 1
        )
    }

    func delete(id: Int64) {
        queue.sync {
            guard let db else { return }
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, "DELETE FROM dictations WHERE id = ?", -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_int64(stmt, 1, id)
            sqlite3_step(stmt)
        }
    }
}
