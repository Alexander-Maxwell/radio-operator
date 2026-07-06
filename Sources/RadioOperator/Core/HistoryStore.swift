import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// SQLite-backed dictation history. Serialized through its own queue; safe to
/// call from any thread.
///
/// At-rest encryption: the `raw` and `cleaned` columns are AES-256-GCM
/// ciphertext (BLOBs) when a `HistoryCipher` is present — the shared store
/// always has one unless the Keychain itself is unavailable. Search decrypts
/// in memory (ciphertext can't be LIKE-matched); a personal history is small
/// enough that this stays instant. `PRAGMA user_version` 0 = plaintext legacy,
/// 1 = encrypted; migration runs once at open and VACUUMs the plaintext away.
final class HistoryStore: @unchecked Sendable {
    static let shared: HistoryStore = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Radio Operator", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let cipher = HistoryCipher.loadOrCreate()
        if cipher == nil {
            NSLog("HistoryStore: NO encryption key — dictation history is being stored in PLAINTEXT")
        }
        return HistoryStore(path: dir.appendingPathComponent("history.sqlite").path, cipher: cipher)
    }()

    private var db: OpaquePointer?
    private let cipher: HistoryCipher?
    private let queue = DispatchQueue(label: "com.warroom.radiooperator.history")

    /// Internal (not private) so tests can run against a throwaway file with
    /// an injected key (no Keychain access in the unit tier).
    init(path: String, cipher: HistoryCipher? = nil) {
        self.cipher = cipher
        queue.sync {
            guard sqlite3_open(path, &db) == SQLITE_OK else {
                NSLog("HistoryStore: failed to open \(path)")
                db = nil
                return
            }
            // Zero freed pages on delete so cleared rows aren't recoverable
            // from the file. Cheap; VACUUM still runs after bulk deletes.
            exec("PRAGMA secure_delete=ON")
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
            migrateLocked()
        }
    }

    deinit {
        if let db {
            sqlite3_close(db)
        }
    }

    private func exec(_ sql: String) {
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &err) != SQLITE_OK {
            NSLog("HistoryStore exec error: \(err.map { String(cString: $0) } ?? "?")")
            sqlite3_free(err)
        }
    }

    // MARK: - Plaintext → encrypted migration (runs once, on the queue)

    private func schemaVersionLocked() -> Int32 {
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, "PRAGMA user_version", -1, &stmt, nil) == SQLITE_OK,
              sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
        return sqlite3_column_int(stmt, 0)
    }

    private func migrateLocked() {
        guard let db, let cipher, schemaVersionLocked() < 1 else { return }

        // Collect plaintext rows (typeof guard keeps this idempotent even if a
        // previous migration was interrupted mid-write).
        var rows: [(Int64, String, String)] = []
        var sel: OpaquePointer?
        if sqlite3_prepare_v2(db, "SELECT id, raw, cleaned FROM dictations WHERE typeof(raw) = 'text'",
                              -1, &sel, nil) == SQLITE_OK {
            while sqlite3_step(sel) == SQLITE_ROW {
                rows.append((
                    sqlite3_column_int64(sel, 0),
                    sqlite3_column_text(sel, 1).map { String(cString: $0) } ?? "",
                    sqlite3_column_text(sel, 2).map { String(cString: $0) } ?? ""
                ))
            }
        }
        sqlite3_finalize(sel)

        exec("BEGIN")
        var failed = false
        for (id, raw, cleaned) in rows {
            guard let rawBlob = cipher.seal(raw), let cleanedBlob = cipher.seal(cleaned) else {
                failed = true
                break
            }
            var up: OpaquePointer?
            guard sqlite3_prepare_v2(db, "UPDATE dictations SET raw = ?, cleaned = ? WHERE id = ?",
                                     -1, &up, nil) == SQLITE_OK else {
                failed = true
                break
            }
            bindBlob(up, 1, rawBlob)
            bindBlob(up, 2, cleanedBlob)
            sqlite3_bind_int64(up, 3, id)
            if sqlite3_step(up) != SQLITE_DONE { failed = true }
            sqlite3_finalize(up)
            if failed { break }
        }
        if failed {
            exec("ROLLBACK")
            NSLog("HistoryStore: encryption migration failed — rows left as-is, will retry next launch")
            return
        }
        exec("COMMIT")
        exec("PRAGMA user_version = 1")
        // Rewrite the file so freed pages holding plaintext are destroyed.
        exec("VACUUM")
    }

    // MARK: - Column encode/decode

    private func bindBlob(_ stmt: OpaquePointer?, _ index: Int32, _ data: Data) {
        data.withUnsafeBytes { buf in
            _ = sqlite3_bind_blob(stmt, index, buf.baseAddress, Int32(buf.count), SQLITE_TRANSIENT)
        }
    }

    /// Binds a text column: ciphertext BLOB when a key exists, plaintext TEXT
    /// otherwise (Keychain-unavailable fallback and legacy tests).
    private func bindColumn(_ stmt: OpaquePointer?, _ index: Int32, _ text: String) {
        if let cipher, let blob = cipher.seal(text) {
            bindBlob(stmt, index, blob)
        } else {
            sqlite3_bind_text(stmt, index, text, -1, SQLITE_TRANSIENT)
        }
    }

    /// Reads a column written by `bindColumn` in either era: BLOB → decrypt,
    /// TEXT → legacy plaintext passthrough.
    private func decodeColumn(_ stmt: OpaquePointer?, _ index: Int32) -> String {
        if sqlite3_column_type(stmt, index) == SQLITE_BLOB {
            guard let bytes = sqlite3_column_blob(stmt, index) else { return "" }
            let count = Int(sqlite3_column_bytes(stmt, index))
            guard count > 0 else { return "" }
            let data = Data(bytes: bytes, count: count)
            return cipher?.open(data) ?? HistoryCipher.unreadableMarker
        }
        return sqlite3_column_text(stmt, index).map { String(cString: $0) } ?? ""
    }

    // MARK: - CRUD

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
            bindColumn(stmt, 2, raw)
            bindColumn(stmt, 3, cleaned)
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
                out.append(rowLocked(stmt))
            }
            return out
        }
    }

    /// Case-insensitive substring search over raw and cleaned text. Encrypted
    /// columns can't be matched in SQL, so rows stream newest-first and are
    /// decrypted + matched in memory until `limit` hits. Wildcards are literal.
    func search(query: String, limit: Int = 200) -> [DictationRecord] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return recent(limit: limit) }
        return queue.sync {
            guard let db else { return [] }
            var stmt: OpaquePointer?
            let sql = "SELECT id, ts, raw, cleaned, app_bundle_id, duration_ms, paste_ok FROM dictations ORDER BY ts DESC"
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(stmt) }
            var out: [DictationRecord] = []
            while out.count < limit, sqlite3_step(stmt) == SQLITE_ROW {
                let rec = rowLocked(stmt)
                if rec.rawText.localizedCaseInsensitiveContains(trimmed)
                    || rec.cleanedText.localizedCaseInsensitiveContains(trimmed) {
                    out.append(rec)
                }
            }
            return out
        }
    }

    /// Deletes rows recorded before the cutoff. secure_delete zeroes the
    /// freed pages, so no VACUUM needed on this steady-state path.
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

    /// Deletes every dictation row, then rewrites the file so nothing is
    /// recoverable from freed pages.
    func deleteAll() {
        queue.sync {
            exec("DELETE FROM dictations")
            exec("VACUUM")
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

    private func rowLocked(_ stmt: OpaquePointer?) -> DictationRecord {
        DictationRecord(
            id: sqlite3_column_int64(stmt, 0),
            timestamp: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 1)),
            rawText: decodeColumn(stmt, 2),
            cleanedText: decodeColumn(stmt, 3),
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
