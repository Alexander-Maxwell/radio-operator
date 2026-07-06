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
/// enough that this stays instant. Any plaintext row (a legacy v0.2.0 db, or one
/// written while the Keychain was unavailable) is re-encrypted at every open when
/// a key is present — the sweep is idempotent and matches zero rows in steady
/// state, so it can't strand plaintext in an "encrypted" database.
///
/// NOTE: metadata columns (ts, app_bundle_id, duration_ms, paste_ok) stay
/// plaintext — only transcript content is encrypted. FileVault covers the rest.
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
    private let keyDestroyer: () -> Void
    private let queue = DispatchQueue(label: "com.warroom.radiooperator.history")

    /// Internal (not private) so tests can run against a throwaway file with an
    /// injected key (no Keychain access in the unit tier). `destroyKey` is the
    /// panic-wipe's key-erase action; it defaults to the production Keychain
    /// delete but is overridden to a no-op in tests so `make test` can never
    /// touch the real key.
    init(path: String, cipher: HistoryCipher? = nil,
         destroyKey: @escaping () -> Void = { _ = HistoryCipher.destroyKey() }) {
        self.cipher = cipher
        self.keyDestroyer = destroyKey
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

    // MARK: - Plaintext → encrypted sweep (idempotent, runs at every open)

    /// Encrypts any plaintext (TEXT-typed) rows. Runs at open whenever a key is
    /// present. Idempotent: the `typeof(raw)='text'` predicate matches zero rows
    /// once everything is ciphertext, so the steady-state cost is a single
    /// existence probe. Not gated on `user_version` — that would strand rows
    /// written plaintext during a Keychain-unavailable session in a db already
    /// stamped "encrypted".
    private func schemaVersionLocked() -> Int32 {
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, "PRAGMA user_version", -1, &stmt, nil) == SQLITE_OK,
              sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
        return sqlite3_column_int(stmt, 0)
    }

    private func migrateLocked() {
        guard let db, let cipher else { return }

        // Cheap existence probe first — the common (all-encrypted, stamped) case
        // does no table scan and no VACUUM.
        var probe: OpaquePointer?
        var hasPlaintext = false
        if sqlite3_prepare_v2(db, "SELECT EXISTS(SELECT 1 FROM dictations WHERE typeof(raw) = 'text')",
                              -1, &probe, nil) == SQLITE_OK, sqlite3_step(probe) == SQLITE_ROW {
            hasPlaintext = sqlite3_column_int(probe, 0) == 1
        }
        sqlite3_finalize(probe)

        // user_version is stamped to 1 only AFTER a successful scrub VACUUM.
        // So version 0 with all-BLOB rows means a prior migration COMMITted but
        // crashed before VACUUM — legacy plaintext pre-images may still sit in
        // freed pages. Run the final VACUUM in that case too, not just when
        // TEXT rows remain.
        let needsScrub = hasPlaintext || schemaVersionLocked() < 1
        guard needsScrub else { return }

        // Collect plaintext rows (empty when this is only a crash-recovery scrub).
        var rows: [(Int64, String, String)] = []
        var sel: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT id, raw, cleaned FROM dictations WHERE typeof(raw) = 'text'",
                                 -1, &sel, nil) == SQLITE_OK else {
            NSLog("HistoryStore: sweep select failed — will retry next open")
            sqlite3_finalize(sel)
            return
        }
        while sqlite3_step(sel) == SQLITE_ROW {
            rows.append((
                sqlite3_column_int64(sel, 0),
                sqlite3_column_text(sel, 1).map { String(cString: $0) } ?? "",
                sqlite3_column_text(sel, 2).map { String(cString: $0) } ?? ""
            ))
        }
        sqlite3_finalize(sel)

        // Keep every plaintext pre-image off disk for the WHOLE migration —
        // both the encrypt UPDATEs and the scrub VACUUM — by journaling to
        // memory, not a sibling -journal file. Tradeoff: a crash during the
        // COMMIT or VACUUM under MEMORY journaling can (per SQLite) leave the
        // file corrupt, not merely stale. Recovery: if the file is still
        // readable next open, the idempotent sweep re-runs (user_version is
        // stamped only after VACUUM); if it is corrupt, restore a pre-upgrade
        // copy of history.sqlite. FileVault is the compensating control for the
        // residue this avoids. Acceptable for a one-time migration of a personal
        // history db; do NOT use MEMORY journaling for steady-state writes.
        exec("PRAGMA journal_mode=MEMORY")
        if !rows.isEmpty {
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
                exec("PRAGMA journal_mode=DELETE")
                NSLog("HistoryStore: encryption sweep failed — rows left as-is, will retry next open")
                return
            }
            exec("COMMIT")
        }

        // Rewrite the file so freed pages holding plaintext (this sweep's, plus
        // any legacy pre-images from the v0.2.0 build's DELETE-journaled writes)
        // are destroyed. Still under MEMORY journaling so VACUUM's own writeback
        // journal never lands plaintext on disk. Stamp user_version to 1 ONLY
        // after VACUUM succeeds — so a crash between the COMMIT above and this
        // VACUUM leaves version 0 and re-enters the scrub (via
        // `schemaVersionLocked() < 1`) on the next open even though every row is
        // already BLOB.
        exec("VACUUM")
        exec("PRAGMA user_version = 1")
        exec("PRAGMA journal_mode=DELETE")
    }

    // MARK: - Column encode/decode

    private func bindBlob(_ stmt: OpaquePointer?, _ index: Int32, _ data: Data) {
        data.withUnsafeBytes { buf in
            _ = sqlite3_bind_blob(stmt, index, buf.baseAddress, Int32(buf.count), SQLITE_TRANSIENT)
        }
    }

    /// Binds a text column. With a key: ciphertext BLOB, and a seal() failure is
    /// reported (never silently written as plaintext into an encrypted db — the
    /// sweep would then never repair it). Without a key: plaintext TEXT (the
    /// Keychain-unavailable fallback and legacy tests). Returns false only when a
    /// key exists but sealing failed, so the caller can abort the insert.
    private func bindColumn(_ stmt: OpaquePointer?, _ index: Int32, _ text: String) -> Bool {
        guard let cipher else {
            sqlite3_bind_text(stmt, index, text, -1, SQLITE_TRANSIENT)
            return true
        }
        guard let blob = cipher.seal(text) else {
            NSLog("HistoryStore: seal() failed — dropping this dictation rather than storing it in plaintext")
            return false
        }
        bindBlob(stmt, index, blob)
        return true
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
            guard bindColumn(stmt, 2, raw), bindColumn(stmt, 3, cleaned) else { return -1 }
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
    ///
    /// Cost note: a non-matching query decrypts every row (O(n)), and under the
    /// default `.keep` retention n grows unbounded. Acceptable for a personal
    /// history, and the Library runs this debounced + off the main thread. If it
    /// ever needs bounding, add a keyed-HMAC search-token column to prefilter in
    /// SQL, or cap the scan window.
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
                // Decrypt + match on the two text columns before materializing a
                // full record, so non-matching rows skip the extra allocations.
                // A row that failed to decrypt shows the unreadable marker; it
                // must not produce false-positive hits when a query happens to be
                // a substring of that marker ("key", "missing", …).
                let raw = decodeColumn(stmt, 2)
                if raw != HistoryCipher.unreadableMarker, raw.localizedCaseInsensitiveContains(trimmed) {
                    out.append(rowLocked(stmt, rawText: raw))
                    continue
                }
                let cleaned = decodeColumn(stmt, 3)
                if cleaned != HistoryCipher.unreadableMarker, cleaned.localizedCaseInsensitiveContains(trimmed) {
                    out.append(rowLocked(stmt, rawText: raw, cleanedText: cleaned))
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

    /// Deletes every dictation row. `secure_delete=ON` (set at open) overwrites
    /// each deleted cell's content with zeros in place, so nothing is
    /// recoverable from the freed pages — no VACUUM needed here (a full-file
    /// rewrite would only reclaim disk space, and this runs on the caller's
    /// thread from a UI button). Transcript columns are ciphertext regardless.
    func deleteAll() {
        queue.sync {
            exec("DELETE FROM dictations")
        }
    }

    /// Cryptographic erase of all dictation content: destroys the Keychain key
    /// (so any lingering ciphertext anywhere is permanently unrecoverable) and
    /// clears the table. Confirmation must be gated by the caller. The key-erase
    /// is injected (see init) so tests never touch the production Keychain.
    func panicWipe() {
        queue.sync {
            exec("DELETE FROM dictations")
            exec("VACUUM")
        }
        keyDestroyer()
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

    /// Builds a record from the current row. `rawText`/`cleanedText` can be
    /// passed in when the caller already decrypted them (search), avoiding a
    /// second AES pass.
    private func rowLocked(_ stmt: OpaquePointer?,
                           rawText: String? = nil, cleanedText: String? = nil) -> DictationRecord {
        DictationRecord(
            id: sqlite3_column_int64(stmt, 0),
            timestamp: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 1)),
            rawText: rawText ?? decodeColumn(stmt, 2),
            cleanedText: cleanedText ?? decodeColumn(stmt, 3),
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
