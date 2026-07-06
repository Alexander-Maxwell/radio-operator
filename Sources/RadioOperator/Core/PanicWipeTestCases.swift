import Foundation
import CryptoKit

/// D8 scope-resolution and execution tests. The key-erase is always an
/// injected closure here — the production Keychain is never touched (and
/// HistoryCipher.destroyKey additionally refuses under --run-tests).
enum PanicWipeTestCases {
    static func run(_ t: TestContext) {
        t.test("default scope is history+key only (D8)") { t in
            let plan = PanicWipe.plan(alsoDeleteNotesAndAudio: false,
                                      notesRoot: URL(fileURLWithPath: "/tmp/notes"))
            t.expect(plan.eraseHistoryAndKey, "history+key always in scope")
            t.expect(plan.foldersToClear.isEmpty, "notes/audio untouched by default")
        }

        t.test("explicit opt-in adds exactly the three user-content folders") { t in
            let root = URL(fileURLWithPath: "/tmp/notes")
            let plan = PanicWipe.plan(alsoDeleteNotesAndAudio: true, notesRoot: root)
            t.expect(plan.eraseHistoryAndKey, "history+key still in scope")
            t.expectEqual(plan.foldersToClear.map(\.lastPathComponent),
                          ["Meetings", "Dictations", "Audio"], "the user-content subfolders")
            t.expect(plan.foldersToClear.allSatisfy { $0.path.hasPrefix(root.path) },
                     "all folders live under the notes root")
        }

        t.test("clearContents empties the folder but keeps it, siblings untouched") { t in
            let fm = FileManager.default
            let tmp = fm.temporaryDirectory.appendingPathComponent("ro-wipe-\(UUID().uuidString)")
            let target = tmp.appendingPathComponent("Meetings")
            let sibling = tmp.appendingPathComponent("Keep")
            let nested = target.appendingPathComponent("sub")
            try? fm.createDirectory(at: nested, withIntermediateDirectories: true)
            try? fm.createDirectory(at: sibling, withIntermediateDirectories: true)
            defer { try? fm.removeItem(at: tmp) }
            try? "note".write(to: target.appendingPathComponent("a.md"), atomically: true, encoding: .utf8)
            try? "deep".write(to: nested.appendingPathComponent("b.md"), atomically: true, encoding: .utf8)
            try? "safe".write(to: sibling.appendingPathComponent("c.md"), atomically: true, encoding: .utf8)

            PanicWipe.clearContents(of: target)

            t.expect(fm.fileExists(atPath: target.path), "folder itself survives")
            let remaining = (try? fm.contentsOfDirectory(atPath: target.path)) ?? ["ERR"]
            t.expectEqual(remaining.count, 0, "folder emptied, including nested dirs")
            t.expect(fm.fileExists(atPath: sibling.appendingPathComponent("c.md").path),
                     "sibling folder untouched")
        }

        t.test("clearContents on a missing folder is a no-op") { t in
            PanicWipe.clearContents(of: URL(fileURLWithPath: "/tmp/ro-wipe-missing-\(UUID().uuidString)"))
            t.expect(true, "no crash")
        }

        t.test("execute wipes history, erases key, and honors the notes toggle") { t in
            let fm = FileManager.default
            let tmp = fm.temporaryDirectory.appendingPathComponent("ro-wipe-exec-\(UUID().uuidString)")
            let meetings = tmp.appendingPathComponent("Meetings")
            try? fm.createDirectory(at: meetings, withIntermediateDirectories: true)
            defer { try? fm.removeItem(at: tmp) }
            try? "m".write(to: meetings.appendingPathComponent("m.md"), atomically: true, encoding: .utf8)

            let dbURL = tmp.appendingPathComponent("history.sqlite")
            var keyErased = false
            let store = HistoryStore(path: dbURL.path,
                                     cipher: HistoryCipher(key: SymmetricKey(size: .bits256)),
                                     destroyKey: { keyErased = true },
                                     rotateKey: { HistoryCipher(key: SymmetricKey(size: .bits256)) })
            store.record(raw: "secret", cleaned: "secret", appBundleID: nil, durationMs: 1, pasteOK: true)

            // Default scope: history gone, key erased + rotated, notes intact.
            let rekeyed = PanicWipe.execute(plan: PanicWipe.plan(alsoDeleteNotesAndAudio: false, notesRoot: tmp),
                                            history: store)
            t.expect(rekeyed, "execute reports the fresh key is active")
            t.expectEqual(store.recent().count, 0, "history emptied")
            t.expect(keyErased, "key destroyer invoked")
            store.record(raw: "post-wipe", cleaned: "post-wipe", appBundleID: nil, durationMs: 1, pasteOK: true)
            t.expectEqual(store.recent().first?.cleanedText ?? "MISSING", "post-wipe",
                          "post-wipe dictations readable — key rotated in place, no relaunch needed")
            t.expect(fm.fileExists(atPath: meetings.appendingPathComponent("m.md").path),
                     "notes survive the default scope")

            // Opt-in scope: notes contents go too.
            PanicWipe.execute(plan: PanicWipe.plan(alsoDeleteNotesAndAudio: true, notesRoot: tmp),
                              history: store)
            t.expect(!fm.fileExists(atPath: meetings.appendingPathComponent("m.md").path),
                     "notes deleted on explicit opt-in")
            t.expect(fm.fileExists(atPath: meetings.path), "meetings folder itself kept")
        }
    }
}
