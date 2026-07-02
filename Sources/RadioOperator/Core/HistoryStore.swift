import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// SQLite-backed dictation history. Serialized through its own queue; safe to
/// call from any thread.
final class HistoryStore: @unchecked Sendable {
    static let shared = HistoryStore()

    private var db: OpaquePointer?
    private let queue = DispatchQueue(label: "com.warroom.radiooperator.history")

    private init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Radio Operator", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("history.sqlite").path
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
                durationMs: Int, pasteOK: Bool) -> Int64 {
        queue.sync {
            guard let db else { return -1 }
            var stmt: OpaquePointer?
            let sql = "INSERT INTO dictations (ts, raw, cleaned, app_bundle_id, duration_ms, paste_ok) VALUES (?,?,?,?,?,?)"
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return -1 }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_double(stmt, 1, Date().timeIntervalSince1970)
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
                out.append(DictationRecord(
                    id: sqlite3_column_int64(stmt, 0),
                    timestamp: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 1)),
                    rawText: String(cString: sqlite3_column_text(stmt, 2)),
                    cleanedText: String(cString: sqlite3_column_text(stmt, 3)),
                    appBundleID: sqlite3_column_text(stmt, 4).map { String(cString: $0) },
                    durationMs: Int(sqlite3_column_int(stmt, 5)),
                    pasteOK: sqlite3_column_int(stmt, 6) == 1
                ))
            }
            return out
        }
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
