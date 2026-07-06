import Foundation
import AppKit
import CryptoKit

/// Tests for the SQLite history store against a throwaway database file.
/// Stores get an injected throwaway key — the unit tier never touches the
/// Keychain — and run encrypted by default, matching production.
enum HistoryStoreTestCases {
    static func run(_ t: TestContext) {
        // Tests inject a no-op key-destroyer so panicWipe never touches the
        // production Keychain.
        func makeStore(cipher: HistoryCipher? = HistoryCipher(key: SymmetricKey(size: .bits256)))
        -> (HistoryStore, URL) {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("ro-history-\(UUID().uuidString).sqlite")
            return (HistoryStore(path: url.path, cipher: cipher, destroyKey: {}), url)
        }

        /// Scans the whole SQLite on-disk footprint — main file plus any
        /// -journal/-wal/-shm siblings — so a plaintext leak into a sibling can't
        /// pass a main-file-only check.
        func fileContains(_ url: URL, _ needle: String) -> Bool {
            let needleData = Data(needle.utf8)
            for suffix in ["", "-journal", "-wal", "-shm"] {
                let p = url.path + suffix
                guard let bytes = try? Data(contentsOf: URL(fileURLWithPath: p)) else { continue }
                if bytes.range(of: needleData) != nil { return true }
            }
            return false
        }

        t.test("search matches raw and cleaned case-insensitively") { t in
            let (store, url) = makeStore()
            defer { try? FileManager.default.removeItem(at: url) }
            store.record(raw: "um gopuff numbers", cleaned: "Gopuff numbers",
                         appBundleID: "com.apple.mail", durationMs: 900, pasteOK: true)
            store.record(raw: "hello world", cleaned: "Hello world",
                         appBundleID: nil, durationMs: 500, pasteOK: true)
            store.record(raw: "raw only phrase kinaxis", cleaned: "different text",
                         appBundleID: nil, durationMs: 500, pasteOK: true)
            t.expectEqual(store.search(query: "GOPUFF").count, 1, "case-insensitive cleaned match")
            t.expectEqual(store.search(query: "kinaxis").count, 1, "raw text match")
            t.expectEqual(store.search(query: "zzz-none").count, 0, "no match")
            // In-memory matching treats former LIKE wildcards as literals.
            t.expectEqual(store.search(query: "%").count, 0, "wildcards are literal")
        }

        t.test("history is encrypted at rest") { t in
            let (store, url) = makeStore()
            defer { try? FileManager.default.removeItem(at: url) }
            let secret = "zebra-quantum-fig confidential launch date"
            store.record(raw: secret, cleaned: secret,
                         appBundleID: "com.apple.mail", durationMs: 700, pasteOK: true)
            let rows = store.recent()
            t.expectEqual(rows.first?.cleanedText ?? "", secret, "round-trips through decrypt")
            t.expect(!fileContains(url, "zebra-quantum-fig"), "plaintext absent from the db file")
        }

        t.test("plaintext v0 database migrates to encrypted") { t in
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("ro-history-\(UUID().uuidString).sqlite")
            defer { try? FileManager.default.removeItem(at: url) }
            // Era 1: no key (legacy plaintext store). Churn — write many rows
            // then delete most — so plaintext lands in freed pages, not just the
            // live rows, exercising VACUUM (not just secure_delete on the UPDATE).
            var legacy: HistoryStore? = HistoryStore(path: url.path, cipher: nil)
            for i in 0..<40 {
                legacy?.record(raw: "churn-secret-\(i)", cleaned: "churn-secret-\(i)",
                               appBundleID: nil, durationMs: 1, pasteOK: true)
            }
            legacy?.record(raw: "migrate-me-alpha", cleaned: "migrate-me-alpha",
                           appBundleID: nil, durationMs: 1, pasteOK: true)
            legacy?.record(raw: "migrate-me-beta", cleaned: "migrate-me-beta",
                           appBundleID: nil, durationMs: 1, pasteOK: true)
            legacy?.prune(olderThan: Date(timeIntervalSinceNow: 3600)) // deletes the 42 rows... keep alpha/beta
            legacy?.record(raw: "migrate-me-alpha", cleaned: "migrate-me-alpha",
                           appBundleID: nil, durationMs: 1, pasteOK: true, at: Date(timeIntervalSinceNow: 7200))
            legacy?.record(raw: "migrate-me-beta", cleaned: "migrate-me-beta",
                           appBundleID: nil, durationMs: 1, pasteOK: true, at: Date(timeIntervalSinceNow: 7200))
            t.expect(fileContains(url, "migrate-me-alpha"), "v0 file holds plaintext")
            legacy = nil // close the first connection before migrating

            // Era 2: key appears; open migrates + vacuums the plaintext away.
            let store = HistoryStore(path: url.path,
                                     cipher: HistoryCipher(key: SymmetricKey(size: .bits256)))
            let rows = store.recent()
            t.expectEqual(rows.count, 2, "both live rows survive migration")
            t.expect(rows.contains { $0.cleanedText == "migrate-me-alpha" }, "content readable after migration")
            t.expect(!fileContains(url, "migrate-me-alpha"), "plaintext destroyed by migration VACUUM")
            t.expect(!fileContains(url, "churn-secret-"), "freed-page plaintext residue destroyed too")
            t.expectEqual(store.search(query: "beta").count, 1, "search works over migrated rows")
        }

        t.test("deleteAll leaves no recoverable plaintext") { t in
            // Plaintext-mode store: proves secure_delete + VACUUM scrub freed
            // pages even without encryption in front.
            let (store, url) = makeStore(cipher: nil)
            defer { try? FileManager.default.removeItem(at: url) }
            store.record(raw: "shred-target-omega", cleaned: "shred-target-omega",
                         appBundleID: nil, durationMs: 1, pasteOK: true)
            t.expect(fileContains(url, "shred-target-omega"), "plaintext present before delete")
            store.deleteAll()
            t.expectEqual(store.recent().count, 0, "table empty")
            t.expect(!fileContains(url, "shred-target-omega"), "bytes scrubbed after deleteAll")
        }

        t.test("plaintext written to a v1 db is healed on next healthy open") { t in
            // Regression: the encryption sweep must not be gated on user_version.
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("ro-history-\(UUID().uuidString).sqlite")
            defer { try? FileManager.default.removeItem(at: url) }
            let key = HistoryCipher(key: SymmetricKey(size: .bits256))
            // Era 1: encrypted store stamps user_version = 1.
            var era1: HistoryStore? = HistoryStore(path: url.path, cipher: key)
            era1?.record(raw: "encrypted-row", cleaned: "encrypted-row",
                         appBundleID: nil, durationMs: 1, pasteOK: true)
            era1 = nil
            // Era 2: Keychain unavailable (cipher nil) — a row lands as plaintext
            // in a db already stamped "encrypted".
            var era2: HistoryStore? = HistoryStore(path: url.path, cipher: nil)
            era2?.record(raw: "degraded-plaintext-row", cleaned: "degraded-plaintext-row",
                         appBundleID: nil, durationMs: 1, pasteOK: true)
            era2 = nil
            t.expect(fileContains(url, "degraded-plaintext-row"), "plaintext present after degraded write")
            // Era 3: key back — the sweep must re-encrypt the stranded row.
            let era3 = HistoryStore(path: url.path, cipher: key)
            t.expectEqual(era3.recent().count, 2, "both rows present")
            t.expect(!fileContains(url, "degraded-plaintext-row"), "stranded plaintext healed by the sweep")
            t.expectEqual(era3.search(query: "degraded").count, 1, "healed row still searchable")
        }

        t.test("seal failure drops the row instead of writing plaintext") { t in
            // A 64-bit key is not a valid AES key size, so seal() returns nil.
            let bad = HistoryCipher(key: SymmetricKey(size: .init(bitCount: 64)))
            let (store, url) = makeStore(cipher: bad)
            defer { try? FileManager.default.removeItem(at: url) }
            let id = store.record(raw: "must-not-persist", cleaned: "must-not-persist",
                                  appBundleID: nil, durationMs: 1, pasteOK: true)
            t.expectEqual(id, -1, "record reports failure")
            t.expectEqual(store.count(), 0, "no row inserted")
            t.expect(!fileContains(url, "must-not-persist"), "no plaintext leaked to the file")
        }

        t.test("unicode round-trips through encryption") { t in
            let (store, url) = makeStore()
            defer { try? FileManager.default.removeItem(at: url) }
            let text = "café ☕️ 会議 — 🎙️ don't"
            store.record(raw: text, cleaned: text, appBundleID: nil, durationMs: 1, pasteOK: true)
            t.expectEqual(store.recent().first?.cleanedText ?? "", text, "multibyte content round-trips")
            t.expectEqual(store.search(query: "会議").count, 1, "search matches multibyte")
        }

        t.test("panicWipe empties the table and erases the key (no production Keychain touch)") { t in
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("ro-history-\(UUID().uuidString).sqlite")
            defer { try? FileManager.default.removeItem(at: url) }
            var erased = false
            let store = HistoryStore(path: url.path,
                                     cipher: HistoryCipher(key: SymmetricKey(size: .bits256)),
                                     destroyKey: { erased = true },
                                     rotateKey: { HistoryCipher(key: SymmetricKey(size: .bits256)) })
            store.record(raw: "gone", cleaned: "gone", appBundleID: nil, durationMs: 1, pasteOK: true)
            t.expect(store.panicWipe(), "rekey reported success")
            t.expectEqual(store.recent().count, 0, "table emptied")
            t.expect(erased, "key-erase invoked")
        }

        t.test("panicWipe rotates the key in place — post-wipe rows sealed with the FRESH key") { t in
            // Regression: the wipe used to leave the destroyed key active in the
            // live store, so every dictation until relaunch was sealed with a
            // dead key and silently lost on the next launch.
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("ro-history-\(UUID().uuidString).sqlite")
            defer { try? FileManager.default.removeItem(at: url) }
            let freshKey = HistoryCipher(key: SymmetricKey(size: .bits256))
            let store = HistoryStore(path: url.path,
                                     cipher: HistoryCipher(key: SymmetricKey(size: .bits256)),
                                     destroyKey: {},
                                     rotateKey: { freshKey })
            store.record(raw: "pre-wipe", cleaned: "pre-wipe", appBundleID: nil, durationMs: 1, pasteOK: true)
            t.expect(store.panicWipe(), "rotation succeeded")
            store.record(raw: "post-wipe-row", cleaned: "post-wipe-row",
                         appBundleID: nil, durationMs: 1, pasteOK: true)
            t.expectEqual(store.recent().first?.cleanedText ?? "MISSING", "post-wipe-row",
                          "post-wipe row readable in the live session")
            // A relaunch (new store holding only the rotated key) must still
            // read it — proving it was sealed with the NEW key, not the dead one.
            let relaunched = HistoryStore(path: url.path, cipher: freshKey)
            t.expectEqual(relaunched.recent().first?.cleanedText ?? "MISSING", "post-wipe-row",
                          "post-wipe row survives relaunch under the rotated key")
        }

        t.test("panicWipe with no replacement key falls back to loud plaintext, never a dead key") { t in
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("ro-history-\(UUID().uuidString).sqlite")
            defer { try? FileManager.default.removeItem(at: url) }
            let store = HistoryStore(path: url.path,
                                     cipher: HistoryCipher(key: SymmetricKey(size: .bits256)),
                                     destroyKey: {},
                                     rotateKey: { nil })
            store.record(raw: "pre", cleaned: "pre", appBundleID: nil, durationMs: 1, pasteOK: true)
            t.expect(!store.panicWipe(), "rekey failure reported to the caller")
            store.record(raw: "degraded-after-wipe", cleaned: "degraded-after-wipe",
                         appBundleID: nil, durationMs: 1, pasteOK: true)
            // Keyless store on relaunch reads it fine: it landed as plaintext
            // (the healable degraded posture), NOT as ciphertext under the
            // destroyed key (unrecoverable).
            let relaunched = HistoryStore(path: url.path, cipher: nil)
            t.expectEqual(relaunched.recent().first?.cleanedText ?? "MISSING", "degraded-after-wipe",
                          "post-wipe row stored plaintext, not sealed with the destroyed key")
        }

        t.test("wrong key yields the unreadable marker, not garbage") { t in
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("ro-history-\(UUID().uuidString).sqlite")
            defer { try? FileManager.default.removeItem(at: url) }
            var writer: HistoryStore? = HistoryStore(
                path: url.path, cipher: HistoryCipher(key: SymmetricKey(size: .bits256)))
            writer?.record(raw: "sealed", cleaned: "sealed", appBundleID: nil, durationMs: 1, pasteOK: true)
            writer = nil
            let reader = HistoryStore(path: url.path,
                                      cipher: HistoryCipher(key: SymmetricKey(size: .bits256)))
            t.expectEqual(reader.recent().first?.cleanedText ?? "",
                          HistoryCipher.unreadableMarker, "marker shown for undecryptable rows")
            // The marker must not produce false-positive search hits.
            t.expectEqual(reader.search(query: "key").count, 0, "no spurious hit on marker substring 'key'")
            t.expectEqual(reader.search(query: "missing").count, 0, "no spurious hit on 'missing'")
        }

        t.test("empty transcript round-trips, not stored as the marker") { t in
            let (store, url) = makeStore()
            defer { try? FileManager.default.removeItem(at: url) }
            store.record(raw: "", cleaned: "", appBundleID: nil, durationMs: 1, pasteOK: true)
            t.expectEqual(store.count(), 1, "empty transcript stored, not dropped")
            t.expectEqual(store.recent().first?.cleanedText ?? "MISSING", "", "empty round-trips, not marker/nil")
        }

        t.test("prune removes only old rows") { t in
            let (store, url) = makeStore()
            defer { try? FileManager.default.removeItem(at: url) }
            store.record(raw: "old", cleaned: "old", appBundleID: nil, durationMs: 1,
                         pasteOK: true, at: Date(timeIntervalSinceNow: -90_000))
            store.record(raw: "fresh", cleaned: "fresh", appBundleID: nil, durationMs: 1,
                         pasteOK: true, at: Date())
            store.prune(olderThan: Date(timeIntervalSinceNow: -86_400))
            let rows = store.recent()
            t.expectEqual(rows.count, 1, "one row survives")
            t.expectEqual(rows.first?.cleanedText ?? "", "fresh", "fresh row survives")
        }

        t.test("deleteAll empties the table") { t in
            let (store, url) = makeStore()
            defer { try? FileManager.default.removeItem(at: url) }
            store.record(raw: "a", cleaned: "a", appBundleID: nil, durationMs: 1, pasteOK: true)
            store.record(raw: "b", cleaned: "b", appBundleID: nil, durationMs: 1, pasteOK: true)
            store.deleteAll()
            t.expectEqual(store.recent().count, 0, "table empty")
        }

        t.test("count returns uncapped total") { t in
            let (store, url) = makeStore()
            defer { try? FileManager.default.removeItem(at: url) }
            t.expectEqual(store.count(), 0, "empty is zero")
            for i in 0..<250 {
                store.record(raw: "r\(i)", cleaned: "c\(i)", appBundleID: nil, durationMs: 1, pasteOK: true)
            }
            t.expectEqual(store.count(), 250, "counts beyond the recent() cap of 200")
        }
    }
}

/// Pure-logic checks for small feature helpers.
enum MiscFeatureTestCases {
    static func run(_ t: TestContext) {
        t.test("smart leading space merge") { t in
            t.expectEqual(SmartSpace.merged("hello", needsSpace: true), " hello", "space prepended")
            t.expectEqual(SmartSpace.merged("hello", needsSpace: false), "hello", "untouched")
            t.expectEqual(SmartSpace.merged(", though", needsSpace: true), ", though", "binding punctuation")
            t.expectEqual(SmartSpace.merged("\nnext", needsSpace: true), "\nnext", "already whitespace-led")
        }

        t.test("ask prompt includes conversation history") { t in
            let p = ClaudeService.cliAskPrompt(
                question: "and the second one?",
                history: [("What did we decide?", "You decided X. [a.md]")])
            t.expect(p.contains("What did we decide?"), "prior question present")
            t.expect(p.contains("You decided X."), "prior answer present")
            t.expect(p.contains("and the second one?"), "current question present")
        }

        t.test("double tap detection window") { t in
            let now = Date()
            t.expect(!DictationController.isDoubleTap(previousDown: nil, now: now), "nil previous")
            t.expect(DictationController.isDoubleTap(previousDown: now.addingTimeInterval(-0.2), now: now),
                     "200ms is a double tap")
            t.expect(!DictationController.isDoubleTap(previousDown: now.addingTimeInterval(-0.8), now: now),
                     "800ms is not")
        }

        t.test("hotkey-down action resolves double-tap lock even mid-finalize") { t in
            typealias A = DictationController.HotkeyDownAction
            // First press from idle → a normal (hold) session.
            t.expectEqual(DictationController.hotkeyDownAction(
                idle: true, activeOrStarting: false, locked: false, doubleTap: false),
                A.beginNormal, "first press begins normal")
            // The bug case: second quick press while the first tap is still
            // finalizing (state == .stopping → not idle, not active). MUST lock,
            // not be ignored.
            t.expectEqual(DictationController.hotkeyDownAction(
                idle: false, activeOrStarting: false, locked: false, doubleTap: true),
                A.beginLocked, "double-tap during finalize locks")
            // Second quick press while the first tap is still recording → locks.
            t.expectEqual(DictationController.hotkeyDownAction(
                idle: false, activeOrStarting: true, locked: false, doubleTap: true),
                A.beginLocked, "double-tap during record locks")
            // A press during a locked hands-free session → finish + paste.
            t.expectEqual(DictationController.hotkeyDownAction(
                idle: false, activeOrStarting: true, locked: true, doubleTap: false),
                A.finishLocked, "press finishes locked session")
            // Stray press mid-finalize, no double-tap → ignored (unchanged).
            t.expectEqual(DictationController.hotkeyDownAction(
                idle: false, activeOrStarting: false, locked: false, doubleTap: false),
                A.ignore, "stray press ignored")
        }

        t.test("dictation log prune keeps recent days") { t in
            let fm = FileManager.default
            let tmp = fm.temporaryDirectory.appendingPathComponent("ro-prune-\(UUID().uuidString)")
            try? fm.createDirectory(at: tmp, withIntermediateDirectories: true)
            defer { try? fm.removeItem(at: tmp) }
            let df = DateFormatter()
            df.dateFormat = "yyyy-MM-dd"
            let oldName = df.string(from: Date(timeIntervalSinceNow: -5 * 86_400))
            let newName = df.string(from: Date())
            try? "old".write(to: tmp.appendingPathComponent("\(oldName).md"), atomically: true, encoding: .utf8)
            try? "new".write(to: tmp.appendingPathComponent("\(newName).md"), atomically: true, encoding: .utf8)
            NotesStore.pruneDictationLogs(in: tmp, keepingDays: 1)
            t.expect(!fm.fileExists(atPath: tmp.appendingPathComponent("\(oldName).md").path), "old log pruned")
            t.expect(fm.fileExists(atPath: tmp.appendingPathComponent("\(newName).md").path), "fresh log kept")
        }

        t.test("echo guard mode resolves") { t in
            t.expect(EchoGuardMode.on.resolved(onSpeakers: false), "on is always true")
            t.expect(!EchoGuardMode.off.resolved(onSpeakers: true), "off is always false")
            t.expect(EchoGuardMode.auto.resolved(onSpeakers: true), "auto true on speakers")
            t.expect(!EchoGuardMode.auto.resolved(onSpeakers: false), "auto false off speakers")
        }

        t.test("output headphones classification gates the echo guard") { t in
            let hdpn: UInt32 = 0x6864_706E // 'hdpn' — built-in headphone jack
            let ispk: UInt32 = 0x6973_706B // 'ispk' — built-in speaker
            t.expect(AudioOutputDevices.classifyHeadphones(dataSource: hdpn), "headphone jack = headphones")
            t.expect(!AudioOutputDevices.classifyHeadphones(dataSource: ispk), "built-in speaker = not headphones")
            // External/USB/HDMI/Bluetooth report no 'hdpn' source, so they must
            // read as NOT headphones — the exact case the old gating missed.
            t.expect(!AudioOutputDevices.classifyHeadphones(dataSource: nil), "unknown output = not headphones")
            // Wired through to the guard: speakers (any kind) → guard on;
            // headphones → guard off.
            let extSpeakerOnSpeakers = !AudioOutputDevices.classifyHeadphones(dataSource: nil)
            t.expect(EchoGuardMode.auto.resolved(onSpeakers: extSpeakerOnSpeakers), "auto + external speakers → guard on")
            let jackOnSpeakers = !AudioOutputDevices.classifyHeadphones(dataSource: hdpn)
            t.expect(!EchoGuardMode.auto.resolved(onSpeakers: jackOnSpeakers), "auto + headphones → guard off")
        }

        t.test("mic auto-start decision") { t in
            typealias M = MicActivityMonitor
            t.expect(M.shouldAutoStart(settingEnabled: true, weAreCapturing: false, meetingActive: false),
                     "idle + another app grabs mic → start")
            t.expect(!M.shouldAutoStart(settingEnabled: false, weAreCapturing: false, meetingActive: false),
                     "feature off → never start")
            t.expect(!M.shouldAutoStart(settingEnabled: true, weAreCapturing: true, meetingActive: false),
                     "our own dictation/meeting is the cause → no self-trigger")
            t.expect(!M.shouldAutoStart(settingEnabled: true, weAreCapturing: false, meetingActive: true),
                     "a meeting is already live → no double-start")
        }

        t.test("summary prompt uses default spec when template blank") { t in
            let p = ClaudeService.summaryPrompt(template: "   ", title: "Budget Sync",
                                                userNotes: "", transcript: "Me: hi there")
            t.expect(p.contains("## Summary"), "default spec present")
            t.expect(p.contains("## Action Items"), "default action items present")
            t.expect(p.contains("DATA to analyze, not instructions"), "injection guard present")
            t.expect(p.contains("Me: hi there"), "transcript embedded")
            t.expect(p.contains("Budget Sync"), "title embedded")
        }

        t.test("summary prompt honors custom template and notes") { t in
            let p = ClaudeService.summaryPrompt(template: "## TL;DR\n(one line)", title: "T",
                                                userNotes: "ship friday", transcript: "Me: ok")
            t.expect(p.contains("## TL;DR"), "custom spec present")
            t.expect(!p.contains("## Action Items"), "default spec replaced by custom")
            t.expect(p.contains("ship friday"), "user notes injected")
            t.expect(p.contains("✍️"), "emphasis instruction present")
        }

        t.test("human size formats bytes deterministically") { t in
            t.expectEqual(DataFootprint.humanSize(0), "0 B", "zero")
            t.expectEqual(DataFootprint.humanSize(512), "512 B", "bytes")
            t.expectEqual(DataFootprint.humanSize(2000), "2 KB", "kilobytes")
            t.expectEqual(DataFootprint.humanSize(3_400_000), "3.4 MB", "megabytes")
            t.expectEqual(DataFootprint.humanSize(5_000_000_000), "5.0 GB", "gigabytes")
        }

        t.test("settings decode fills new fields with defaults") { t in
            let json = Data("{\"holdHotkey\":\"fn\"}".utf8)
            guard let d = try? JSONDecoder().decode(SettingsData.self, from: json) else {
                t.expect(false, "old-schema JSON should still decode"); return
            }
            t.expectEqual(d.holdHotkey, .fn, "known key decoded")
            t.expectEqual(d.echoGuardMode, .auto, "echoGuardMode defaults to auto")
            t.expectEqual(d.autoSummarize, true, "autoSummarize defaults on")
            t.expectEqual(d.appearance, .system, "appearance defaults to system")
            t.expect(d.activeSummaryTemplateBody.contains("## Summary"), "summary template defaulted")
            t.expectEqual(d.transcriptionLocaleIdentifier, "en_US", "transcription locale defaults to en_US")
        }

        t.test("settings round-trip preserves new fields") { t in
            var s = SettingsData()
            s.echoGuardMode = .off
            s.autoSummarize = false
            s.appearance = .dark
            s.setSelectedTemplateBody("## Custom\n(x)")
            s.transcriptionLocaleIdentifier = "de_DE"
            guard let data = try? JSONEncoder().encode(s),
                  let back = try? JSONDecoder().decode(SettingsData.self, from: data) else {
                t.expect(false, "encode/decode failed"); return
            }
            t.expectEqual(back.echoGuardMode, .off, "echo mode round-trips")
            t.expectEqual(back.autoSummarize, false, "autoSummarize round-trips")
            t.expectEqual(back.appearance, .dark, "appearance round-trips")
            t.expectEqual(back.activeSummaryTemplateBody, "## Custom\n(x)", "template round-trips")
            t.expectEqual(back.transcriptionLocaleIdentifier, "de_DE", "transcription locale round-trips")
        }

        t.test("ask scope maps to the right folder") { t in
            let base = URL(fileURLWithPath: "/tmp/notes")
            t.expectEqual(ClaudeService.scopedFolder(.all, notesFolder: base).path, "/tmp/notes", "all = root")
            t.expectEqual(ClaudeService.scopedFolder(.meetings, notesFolder: base).lastPathComponent,
                          "Meetings", "meetings subfolder")
            t.expectEqual(ClaudeService.scopedFolder(.dictations, notesFolder: base).lastPathComponent,
                          "Dictations", "dictations subfolder")
        }

        t.test("ask prompt describes the scoped corpus") { t in
            let all = ClaudeService.cliAskPrompt(question: "q", history: [], scope: .all)
            t.expect(all.contains("Meetings/") && all.contains("Dictations/"), "all mentions both folders")
            let m = ClaudeService.cliAskPrompt(question: "q", history: [], scope: .meetings)
            t.expect(m.contains("meeting transcripts"), "meetings corpus described")
            t.expect(!m.contains("Dictations/"), "meetings scope omits the dictations folder")
            let d = ClaudeService.cliAskPrompt(question: "find X", history: [], scope: .dictations)
            t.expect(d.contains("dictation logs"), "dictations corpus described")
            t.expect(d.contains("find X"), "question embedded")
        }

        t.test("paste clipboard save/restore survives the dictation swap") { t in
            // Scratch pasteboard, isolated from the user's real clipboard.
            let pb = NSPasteboard(name: NSPasteboard.Name("com.warroom.radiooperator.test-\(UUID().uuidString)"))
            defer { pb.releaseGlobally() }
            let custom = NSPasteboard.PasteboardType("com.warroom.test.blob")
            pb.clearContents()
            pb.setString("original clipboard", forType: .string)
            pb.setData(Data("blob".utf8), forType: custom)

            // Snapshot the way PasteService does before it overwrites.
            let saved = PasteService.snapshot(pb)

            // Simulate the dictation swap.
            pb.clearContents()
            pb.setString("dictated text", forType: .string)
            t.expectEqual(pb.string(forType: .string) ?? "", "dictated text", "swap took")

            // Guarded restore reproduces every original type.
            pb.clearContents()
            pb.writeObjects(saved)
            t.expectEqual(pb.string(forType: .string) ?? "", "original clipboard", "string restored")
            t.expectEqual(pb.data(forType: custom).flatMap { String(data: $0, encoding: .utf8) } ?? "",
                          "blob", "non-string type restored")
        }
    }
}
