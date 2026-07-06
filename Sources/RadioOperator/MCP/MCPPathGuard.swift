import Foundation

/// Strict path guard for `get_note`: the only filesystem reads the MCP server
/// ever performs are of plain leaf `.md` files that *canonically* live inside
/// the Meetings folder. Everything else — absolute paths, traversal, nested
/// paths, symlinks that escape the folder — is rejected before any read.
enum MCPPathGuard {
    enum Resolution: Equatable {
        /// Safe to read.
        case ok(URL)
        /// The name itself, or where it canonically points, is disallowed.
        case rejected(String)
        /// The name is well-formed but no such note exists.
        case notFound
    }

    /// Resolves `filename` strictly inside `folder`.
    ///
    /// Static shape checks first (leaf-only: no separators, no "..", no
    /// absolute/tilde forms, must end in ".md"), then both sides are
    /// canonicalized (symlinks + "." / ".." resolved) and the candidate must
    /// remain under the canonical folder — so a symlink planted inside the
    /// Meetings folder cannot leak a file from outside it.
    static func resolveNote(filename: String, in folder: URL) -> Resolution {
        let name = filename
        guard !name.isEmpty else { return .rejected("empty filename") }
        guard !name.contains("\0") else { return .rejected("NUL byte in filename") }
        guard !name.hasPrefix("/") else { return .rejected("absolute paths are not allowed") }
        guard !name.hasPrefix("~") else { return .rejected("home-relative paths are not allowed") }
        guard !name.contains("/"), !name.contains("\\") else {
            return .rejected("path separators are not allowed — pass a leaf filename from list_meetings")
        }
        guard !name.contains("..") else { return .rejected("'..' is not allowed") }
        guard name.lowercased().hasSuffix(".md") else { return .rejected("only .md note files can be read") }

        // Canonicalize BOTH sides. standardizedFileURL collapses "." / ".."
        // components; resolvingSymlinksInPath resolves every existing symlink
        // (including a symlinked leaf), so the prefix check below compares
        // real filesystem locations, not spellings.
        let canonicalFolder = folder.standardizedFileURL.resolvingSymlinksInPath()
        let candidate = canonicalFolder.appendingPathComponent(name)
        let canonicalCandidate = candidate.standardizedFileURL.resolvingSymlinksInPath()

        // Boundary-aware prefix match ("/a/Meetings/" so "/a/Meetings-evil"
        // can never pass).
        guard canonicalCandidate.path.hasPrefix(canonicalFolder.path + "/") else {
            return .rejected("resolved path escapes the Meetings folder")
        }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: canonicalCandidate.path, isDirectory: &isDirectory) else {
            return .notFound
        }
        guard !isDirectory.boolValue else { return .rejected("not a note file") }
        return .ok(canonicalCandidate)
    }
}
