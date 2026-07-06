import Foundation
import CryptoKit

/// Pure dispatch tests for the MCP server: request JSON in → response JSON
/// out, against temp fixtures. No stdio, no Keychain (injected throwaway
/// cipher), no network — deterministic and offline.
enum MCPTestCases {
    // MARK: - Fixtures

    /// Meetings folder with two known notes (one summarized, one pending).
    private static func makeMeetingsFolder() -> URL {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("ro-mcp-\(UUID().uuidString)/Meetings",
                                                               isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)

        let older = NotesStore.renderNote(
            title: "Alpha Sync", start: Date(timeIntervalSince1970: 1_780_000_000),
            durationSeconds: 600, summaryMarkdown: NotesStore.summaryPendingMarker,
            utterances: [Utterance(speaker: .me, text: "alpha content",
                                   start: Date(timeIntervalSince1970: 1_780_000_000),
                                   end: Date(timeIntervalSince1970: 1_780_000_010))],
            degradedMicOnly: false)
        try? older.write(to: dir.appendingPathComponent("2026-06-28-0900 Alpha Sync.md"),
                         atomically: true, encoding: .utf8)

        let newer = NotesStore.replacedSummary(
            in: NotesStore.renderNote(
                title: "Beta Review", start: Date(timeIntervalSince1970: 1_780_500_000),
                durationSeconds: 1200, summaryMarkdown: NotesStore.summaryPendingMarker,
                utterances: [], degradedMicOnly: false),
            with: "## Summary\n- beta went well")
        try? newer.write(to: dir.appendingPathComponent("2026-07-04-1300 Beta Review.md"),
                         atomically: true, encoding: .utf8)
        return dir
    }

    private static func makeHistoryStore() -> (HistoryStore, URL) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ro-mcp-history-\(UUID().uuidString).sqlite")
        let store = HistoryStore(path: url.path,
                                 cipher: HistoryCipher(key: SymmetricKey(size: .bits256)),
                                 destroyKey: {})
        store.record(raw: "um send the kinaxis numbers", cleaned: "Send the Kinaxis numbers.",
                     appBundleID: "com.apple.mail", durationMs: 1500, pasteOK: true,
                     at: Date(timeIntervalSince1970: 1_780_100_000))
        store.record(raw: "hello world", cleaned: "Hello world.",
                     appBundleID: nil, durationMs: 700, pasteOK: true,
                     at: Date(timeIntervalSince1970: 1_780_200_000))
        return (store, url)
    }

    /// Dispatches one request line and parses the response as JSON.
    private static func rpc(_ server: MCPServer, _ line: String) -> [String: Any]? {
        guard let response = server.handle(line: line),
              let data = response.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return obj
    }

    private static func result(_ obj: [String: Any]?) -> [String: Any]? {
        obj?["result"] as? [String: Any]
    }

    private static func errorCode(_ obj: [String: Any]?) -> Int? {
        (obj?["error"] as? [String: Any])?["code"] as? Int
    }

    /// Decoded first text content block of a tool result.
    private static func toolText(_ obj: [String: Any]?) -> String? {
        guard let content = result(obj)?["content"] as? [[String: Any]] else { return nil }
        return content.first?["text"] as? String
    }

    private static func toolJSON(_ obj: [String: Any]?) -> [String: Any]? {
        guard let text = toolText(obj), let data = text.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    // MARK: - Cases

    static func run(_ t: TestContext) {
        let meetings = makeMeetingsFolder()
        let (store, historyURL) = makeHistoryStore()
        defer {
            try? FileManager.default.removeItem(at: meetings.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: historyURL)
        }
        let server = MCPServer(meetingsFolder: meetings, history: { .available(store) })
        let lockedServer = MCPServer(meetingsFolder: meetings,
                                     history: { .unavailable(reason: "keychain locked (test)") })

        t.test("MCP initialize handshake shape") { t in
            let obj = rpc(server, #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"t","version":"0"}}}"#)
            t.expectEqual(obj?["jsonrpc"] as? String ?? "", "2.0", "jsonrpc version")
            t.expectEqual(obj?["id"] as? Int ?? -1, 1, "id echoed")
            let res = result(obj)
            t.expectEqual(res?["protocolVersion"] as? String ?? "", "2025-06-18", "supported version echoed")
            t.expect((res?["capabilities"] as? [String: Any])?["tools"] != nil, "tools capability advertised")
            let info = res?["serverInfo"] as? [String: Any]
            t.expectEqual(info?["name"] as? String ?? "", "radio-operator", "server name")
        }

        t.test("MCP initialize falls back on unknown protocol version") { t in
            let obj = rpc(server, #"{"jsonrpc":"2.0","id":2,"method":"initialize","params":{"protocolVersion":"1999-01-01"}}"#)
            t.expectEqual(result(obj)?["protocolVersion"] as? String ?? "", "2024-11-05", "fallback version")
        }

        t.test("MCP notifications get no response") { t in
            t.expect(server.handle(line: #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#) == nil,
                     "initialized notification ignored")
            t.expect(server.handle(line: #"{"jsonrpc":"2.0","method":"notifications/cancelled"}"#) == nil,
                     "unknown notification ignored")
        }

        t.test("MCP tools/list schema") { t in
            let obj = rpc(server, #"{"jsonrpc":"2.0","id":3,"method":"tools/list"}"#)
            let tools = result(obj)?["tools"] as? [[String: Any]] ?? []
            let names = tools.compactMap { $0["name"] as? String }
            t.expectEqual(names, ["search_dictations", "list_meetings", "get_note"], "exactly the three read-only tools")
            t.expect(!names.contains("ask"), "no ask tool (D7)")
            for tool in tools {
                let schema = tool["inputSchema"] as? [String: Any]
                t.expectEqual(schema?["type"] as? String ?? "", "object", "inputSchema is an object schema")
                t.expect((tool["description"] as? String)?.isEmpty == false, "description present")
            }
            let search = tools.first { ($0["name"] as? String) == "search_dictations" }
            let required = (search?["inputSchema"] as? [String: Any])?["required"] as? [String]
            t.expectEqual(required ?? [], ["query"], "query is required")
        }

        t.test("MCP search_dictations returns matches") { t in
            let obj = rpc(server, #"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"search_dictations","arguments":{"query":"kinaxis"}}}"#)
            let payload = toolJSON(obj)
            t.expectEqual(payload?["count"] as? Int ?? -1, 1, "one match")
            let match = (payload?["matches"] as? [[String: Any]])?.first
            t.expectEqual(match?["text"] as? String ?? "", "Send the Kinaxis numbers.", "cleaned text returned")
            t.expectEqual(match?["app_bundle_id"] as? String ?? "", "com.apple.mail", "app recorded")
            t.expectEqual(match?["duration_ms"] as? Int ?? -1, 1500, "duration returned")
            let none = toolJSON(rpc(server, #"{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"search_dictations","arguments":{"query":"zzz-none"}}}"#))
            t.expectEqual(none?["count"] as? Int ?? -1, 0, "no match is empty, not an error")
        }

        t.test("MCP search_dictations validates params") { t in
            let obj = rpc(server, #"{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"search_dictations","arguments":{}}}"#)
            t.expectEqual(errorCode(obj) ?? 0, -32602, "missing query is invalid params")
        }

        t.test("MCP search_dictations with keychain unavailable is a JSON-RPC error") { t in
            let obj = rpc(lockedServer, #"{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"search_dictations","arguments":{"query":"x"}}}"#)
            t.expectEqual(errorCode(obj) ?? 0, -32002, "history-unavailable error code")
            let message = (obj?["error"] as? [String: Any])?["message"] as? String ?? ""
            t.expect(message.contains("keychain locked (test)"), "reason surfaced")
            // The same locked server still serves the corpus tools.
            let list = rpc(lockedServer, #"{"jsonrpc":"2.0","id":8,"method":"tools/call","params":{"name":"list_meetings","arguments":{}}}"#)
            t.expect(toolJSON(list) != nil, "list_meetings unaffected by keychain state")
        }

        t.test("MCP list_meetings lists fixtures newest first") { t in
            let obj = rpc(server, #"{"jsonrpc":"2.0","id":9,"method":"tools/call","params":{"name":"list_meetings","arguments":{}}}"#)
            let payload = toolJSON(obj)
            let items = payload?["meetings"] as? [[String: Any]] ?? []
            t.expectEqual(items.count, 2, "both fixtures listed")
            t.expectEqual(items.first?["filename"] as? String ?? "", "2026-07-04-1300 Beta Review.md", "newest first")
            t.expectEqual(items.first?["title"] as? String ?? "", "Beta Review", "title from frontmatter")
            t.expectEqual(items.first?["duration_seconds"] as? Int ?? -1, 1200, "duration")
            t.expectEqual(items.first?["hasSummary"] as? Bool ?? false, true, "summarized note flagged")
            t.expectEqual(items.last?["hasSummary"] as? Bool ?? true, false, "pending note not flagged")
        }

        t.test("MCP get_note returns full markdown") { t in
            let obj = rpc(server, #"{"jsonrpc":"2.0","id":10,"method":"tools/call","params":{"name":"get_note","arguments":{"filename":"2026-06-28-0900 Alpha Sync.md"}}}"#)
            let text = toolText(obj) ?? ""
            t.expect(text.contains("# Alpha Sync"), "note H1 present")
            t.expect(text.contains("alpha content"), "transcript present")
            t.expect(result(obj)?["isError"] == nil, "not an error result")
        }

        t.test("MCP get_note rejects traversal and non-leaf names") { t in
            for attack in ["../secret.md", "/etc/passwd", "~/notes.md", "sub/inner.md",
                           "..", "a\\b.md", "", "2026-06-28-0900 Alpha Sync.txt",
                           "....//secret.md", "..%2Fsecret.md"] {
                let escaped = attack
                    .replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "\"", with: "\\\"")
                let obj = rpc(server, "{\"jsonrpc\":\"2.0\",\"id\":11,\"method\":\"tools/call\",\"params\":{\"name\":\"get_note\",\"arguments\":{\"filename\":\"\(escaped)\"}}}")
                t.expectEqual(result(obj)?["isError"] as? Bool ?? false, true, "rejected: \(attack)")
                let text = toolText(obj) ?? ""
                t.expect(!text.contains("root:"), "no /etc/passwd content leaked for \(attack)")
                t.expect(!text.contains("# Alpha Sync"), "no note content for \(attack)")
            }
            let missing = rpc(server, #"{"jsonrpc":"2.0","id":12,"method":"tools/call","params":{"name":"get_note","arguments":{"filename":"ghost.md"}}}"#)
            t.expectEqual(result(missing)?["isError"] as? Bool ?? false, true, "missing note is a tool error")
            t.expect((toolText(missing) ?? "").contains("not found"), "distinct not-found message")
        }

        t.test("MCPPathGuard direct attack cases") { t in
            func rejected(_ name: String) -> Bool {
                if case .rejected = MCPPathGuard.resolveNote(filename: name, in: meetings) { return true }
                return false
            }
            t.expect(rejected("../secret.md"), "dot-dot")
            t.expect(rejected("/etc/passwd"), "absolute")
            t.expect(rejected("~/x.md"), "tilde")
            t.expect(rejected("a/b.md"), "separator")
            t.expect(rejected("a\\b.md"), "backslash")
            t.expect(rejected("nested..md"), "embedded dot-dot")
            t.expect(rejected("note.pdf"), "non-md extension")
            t.expect(rejected(""), "empty")
            if case .notFound = MCPPathGuard.resolveNote(filename: "nope.md", in: meetings) {
                t.expect(true, "")
            } else {
                t.expect(false, "well-formed missing name is notFound, not rejected")
            }
            if case .ok(let url) = MCPPathGuard.resolveNote(filename: "2026-06-28-0900 Alpha Sync.md",
                                                            in: meetings) {
                t.expect(FileManager.default.fileExists(atPath: url.path), "resolved to a real file")
            } else {
                t.expect(false, "legitimate filename resolves")
            }
        }

        t.test("MCPPathGuard blocks symlink escape") { t in
            let fm = FileManager.default
            let outside = fm.temporaryDirectory.appendingPathComponent("ro-mcp-outside-\(UUID().uuidString).md")
            try? "TOP SECRET OUTSIDE".write(to: outside, atomically: true, encoding: .utf8)
            defer { try? fm.removeItem(at: outside) }
            let link = meetings.appendingPathComponent("escape.md")
            try? fm.createSymbolicLink(at: link, withDestinationURL: outside)
            defer { try? fm.removeItem(at: link) }

            if case .rejected = MCPPathGuard.resolveNote(filename: "escape.md", in: meetings) {
                t.expect(true, "")
            } else {
                t.expect(false, "symlink pointing outside the Meetings folder must be rejected")
            }
            let obj = rpc(server, #"{"jsonrpc":"2.0","id":13,"method":"tools/call","params":{"name":"get_note","arguments":{"filename":"escape.md"}}}"#)
            t.expectEqual(result(obj)?["isError"] as? Bool ?? false, true, "dispatch path also rejects")
            t.expect(!(toolText(obj) ?? "").contains("TOP SECRET"), "no outside content leaked")

            // A symlink that stays inside the folder is fine (canonical target
            // is still under Meetings).
            let inLink = meetings.appendingPathComponent("alias.md")
            try? fm.createSymbolicLink(
                at: inLink,
                withDestinationURL: meetings.appendingPathComponent("2026-06-28-0900 Alpha Sync.md"))
            defer { try? fm.removeItem(at: inLink) }
            if case .ok = MCPPathGuard.resolveNote(filename: "alias.md", in: meetings) {
                t.expect(true, "")
            } else {
                t.expect(false, "inside-folder symlink stays readable")
            }
        }

        t.test("MCP unknown method and unknown tool") { t in
            let method = rpc(server, #"{"jsonrpc":"2.0","id":14,"method":"resources/list"}"#)
            t.expectEqual(errorCode(method) ?? 0, -32601, "unknown method")
            let tool = rpc(server, #"{"jsonrpc":"2.0","id":15,"method":"tools/call","params":{"name":"ask","arguments":{}}}"#)
            t.expectEqual(errorCode(tool) ?? 0, -32602, "ask stays unimplemented (D7)")
        }

        t.test("MCP malformed input") { t in
            let garbage = rpc(server, "this is not json")
            t.expectEqual(errorCode(garbage) ?? 0, -32700, "parse error")
            t.expect(garbage?["id"] is NSNull, "parse error id is null")
            let nonObject = rpc(server, "[1,2,3]")
            t.expectEqual(errorCode(nonObject) ?? 0, -32600, "non-object request invalid")
            let noMethod = rpc(server, #"{"jsonrpc":"2.0","id":16}"#)
            t.expectEqual(errorCode(noMethod) ?? 0, -32600, "request without method invalid")
        }

        t.test("MCP ping responds") { t in
            let obj = rpc(server, #"{"jsonrpc":"2.0","id":17,"method":"ping"}"#)
            t.expect(result(obj) != nil, "ping returns an empty result")
        }

        t.test("MCP responses are single-line JSON") { t in
            for request in [#"{"jsonrpc":"2.0","id":18,"method":"tools/list"}"#,
                            #"{"jsonrpc":"2.0","id":19,"method":"tools/call","params":{"name":"get_note","arguments":{"filename":"2026-06-28-0900 Alpha Sync.md"}}}"#] {
                let raw = server.handle(line: request) ?? ""
                t.expect(!raw.isEmpty, "response present")
                t.expect(!raw.contains("\n"), "newline-delimited framing preserved (note content has newlines — they must be escaped)")
            }
        }
    }
}
