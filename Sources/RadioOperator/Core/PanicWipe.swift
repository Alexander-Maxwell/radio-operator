import Foundation

/// D8 panic-wipe scope resolution and execution.
///
/// Default scope: the history database + the Keychain data key — a
/// cryptographic erase (HistoryStore.panicWipe destroys the key, so any
/// ciphertext anywhere, including old backups, is permanently unreadable).
/// Notes and audio are USER files and are deleted only when the explicit
/// second toggle is on — never by default.
///
/// The plan step is pure so the scope rule is unit-testable; execution takes
/// an injected HistoryStore so tests never touch the production Keychain.
enum PanicWipe {
    struct Plan: Equatable {
        /// Always true — the D8 default scope is non-negotiable.
        let eraseHistoryAndKey: Bool
        /// Folders whose CONTENTS are deleted (the folders themselves stay,
        /// so the app keeps working afterward). Empty unless the explicit
        /// notes/audio toggle was on.
        let foldersToClear: [URL]
    }

    /// The subfolders of the notes root that hold user content.
    static let userContentSubfolders = ["Meetings", "Dictations", "Audio"]

    /// Pure scope resolution: history+key always; notes/audio folders only
    /// on the explicit opt-in.
    static func plan(alsoDeleteNotesAndAudio: Bool, notesRoot: URL) -> Plan {
        let folders = alsoDeleteNotesAndAudio
            ? userContentSubfolders.map { notesRoot.appendingPathComponent($0, isDirectory: true) }
            : []
        return Plan(eraseHistoryAndKey: true, foldersToClear: folders)
    }

    /// Deletes everything INSIDE `folder`, keeping the folder itself.
    /// Missing folders are a no-op.
    static func clearContents(of folder: URL) {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else {
            return
        }
        for item in items {
            try? fm.removeItem(at: item)
        }
    }

    /// Runs the plan. Blocking (DELETE + VACUUM + file removals) — call it
    /// off the main thread. The store is injected so tests use a throwaway
    /// db with a no-op key destroyer and an injected key rotator.
    ///
    /// Returns true when a fresh encryption key is active after the wipe
    /// (HistoryStore.panicWipe rotates the key in place, so post-wipe
    /// dictations are sealed with the new key — no relaunch needed). False
    /// means the Keychain was unavailable and the store said so loudly.
    @discardableResult
    static func execute(plan: Plan, history: HistoryStore) -> Bool {
        var rekeyed = true
        if plan.eraseHistoryAndKey {
            rekeyed = history.panicWipe()
        }
        for folder in plan.foldersToClear {
            clearContents(of: folder)
        }
        return rekeyed
    }
}
