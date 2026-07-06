import Foundation

/// `RadioOperator --mcp`: runs the binary as a local MCP stdio server and
/// never touches NSApplication. Handled in RadioOperatorApp.main BEFORE the
/// app object exists (same pattern as TestRunner/ProbeRunner), so the
/// subprocess is fully headless: no MainActor singletons, no windows, no TCC.
///
/// Settings are read by decoding settings.json directly (SettingsData is
/// Codable) — SettingsStore is @MainActor and must not be touched here.
enum MCPRunner {
    /// Returns true if `--mcp` was requested and the serve loop ran to EOF
    /// (caller returns without starting the app).
    static func handleIfRequested() -> Bool {
        guard CommandLine.arguments.contains("--mcp") else { return false }

        let meetings = meetingsFolder(settings: loadSettings())

        // History opens lazily on the first search_dictations call — an
        // initialize/tools-list handshake never touches the Keychain — and is
        // cached for the life of the process (the serve loop is single-threaded).
        var cachedHistory: MCPHistoryAccess?
        let server = MCPServer(meetingsFolder: meetings, history: {
            if let cachedHistory { return cachedHistory }
            let access = openHistory()
            cachedHistory = access
            return access
        })
        serve(server)
        return true
    }

    // MARK: - Headless wiring

    private static var appSupportFolder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Radio Operator", isDirectory: true)
    }

    /// Direct Codable decode of settings.json; falls back to defaults when the
    /// file is missing or unreadable (fresh machine).
    static func loadSettings() -> SettingsData {
        let url = appSupportFolder.appendingPathComponent("settings.json")
        if let raw = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode(SettingsData.self, from: raw) {
            return decoded
        }
        return SettingsData()
    }

    static func meetingsFolder(settings: SettingsData) -> URL {
        URL(fileURLWithPath: settings.notesFolderPath, isDirectory: true)
            .appendingPathComponent("Meetings", isDirectory: true)
    }

    /// Opens the real history database with the real Keychain-backed cipher.
    /// A locked/unavailable Keychain becomes a reportable state, never a crash
    /// — and never a plaintext-fallback store (the GUI owns that decision).
    private static func openHistory() -> MCPHistoryAccess {
        guard let cipher = HistoryCipher.loadOrCreate() else {
            return .unavailable(reason:
                "the history encryption key could not be read from the login Keychain (locked or inaccessible)")
        }
        let path = appSupportFolder.appendingPathComponent("history.sqlite").path
        // HistoryStore sets PRAGMA busy_timeout at open, so sharing the file
        // with a running GUI app is safe for these read paths.
        return .available(HistoryStore(path: path, cipher: cipher))
    }

    // MARK: - Stdio loop (newline-delimited JSON-RPC per the MCP stdio transport)

    private static func serve(_ server: MCPServer) {
        // Diagnostics must never contaminate the protocol stream: NSLog (used
        // by HistoryStore/HistoryCipher) writes to stderr, and everything we
        // print here is exactly one JSON message per line.
        while let line = readLine(strippingNewline: true) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            if let response = server.handle(line: trimmed) {
                print(response)
                fflush(stdout)
            }
        }
    }
}
