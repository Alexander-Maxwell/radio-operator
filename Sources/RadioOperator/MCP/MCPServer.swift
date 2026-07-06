import Foundation

/// How the MCP server reaches dictation history. Resolved lazily (first
/// `search_dictations` call) so `initialize`/`tools/list` never touch the
/// Keychain, and injectable so tests never touch the real database.
enum MCPHistoryAccess {
    case available(HistoryStore)
    /// The Keychain (and therefore the history cipher) is unavailable —
    /// surfaced to the client as a JSON-RPC error, never a crash.
    case unavailable(reason: String)
}

/// Hand-rolled MCP (Model Context Protocol) server core: one JSON-RPC 2.0
/// message in, at most one response out, over newline-delimited UTF-8 JSON.
/// Zero dependencies — JSONSerialization only. (The official Swift SDK drags
/// in swift-nio/system/log, which would detonate the zero-dep property; the
/// protocol subset we need is ~200 lines of Foundation.)
///
/// Read-only by design (plan decision D7): `search_dictations`,
/// `list_meetings`, `get_note`. Nothing here can write, delete, or send.
/// Pure dispatch — no stdin/stdout in this type — so tests drive it
/// string-in/string-out (see MCPTestCases).
struct MCPServer {
    static let supportedProtocolVersions: Set<String> = ["2025-06-18", "2024-11-05"]
    static let defaultProtocolVersion = "2024-11-05"
    static let serverName = "radio-operator"
    static let serverVersion = "0.3.0"

    /// The Meetings folder that `list_meetings`/`get_note` are jailed to.
    let meetingsFolder: URL
    /// Lazy history accessor (see MCPHistoryAccess).
    let history: () -> MCPHistoryAccess

    // MARK: - Dispatch

    /// Handles one newline-delimited JSON-RPC message. Returns the response
    /// line (no trailing newline), or nil when no response is due
    /// (notifications).
    func handle(line: String) -> String? {
        guard let data = line.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data) else {
            return errorLine(id: NSNull(), code: -32700, message: "Parse error: invalid JSON")
        }
        guard let message = parsed as? [String: Any] else {
            return errorLine(id: NSNull(), code: -32600, message: "Invalid Request: expected a JSON object")
        }
        let id = message["id"]
        guard let method = message["method"] as? String else {
            // A response from the client (has id, no method) or garbage.
            // Only a malformed *request* warrants an error.
            return id == nil ? nil
                : errorLine(id: id ?? NSNull(), code: -32600, message: "Invalid Request: missing method")
        }
        let params = message["params"] as? [String: Any] ?? [:]

        // Notifications (no id) get no response, known method or not.
        guard let id else {
            return nil // includes notifications/initialized, notifications/cancelled, …
        }

        switch method {
        case "initialize":
            return resultLine(id: id, result: initializeResult(params: params))
        case "ping":
            return resultLine(id: id, result: [:])
        case "tools/list":
            return resultLine(id: id, result: ["tools": MCPServer.toolDefinitions])
        case "tools/call":
            return toolsCall(id: id, params: params)
        default:
            return errorLine(id: id, code: -32601, message: "Method not found: \(method)")
        }
    }

    // MARK: - initialize

    private func initializeResult(params: [String: Any]) -> [String: Any] {
        let requested = params["protocolVersion"] as? String
        let negotiated = requested.flatMap { MCPServer.supportedProtocolVersions.contains($0) ? $0 : nil }
            ?? MCPServer.defaultProtocolVersion
        return [
            "protocolVersion": negotiated,
            "capabilities": ["tools": [String: Any]()],
            "serverInfo": ["name": MCPServer.serverName, "version": MCPServer.serverVersion],
            "instructions": "Read-only access to Radio Operator's local dictation history and meeting notes on this Mac. Nothing can be modified through this server.",
        ]
    }

    // MARK: - Tools

    static let toolDefinitions: [[String: Any]] = [
        [
            "name": "search_dictations",
            "description": "Case-insensitive substring search over everything the user has dictated with Radio Operator. Returns the most recent matches first.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "query": ["type": "string", "description": "Substring to find in dictation transcripts."],
                    "limit": ["type": "integer", "description": "Maximum results (default 20, max 200)."],
                ],
                "required": ["query"],
            ],
        ],
        [
            "name": "list_meetings",
            "description": "Lists the user's captured meeting notes (newest first) with filename, title, date, duration, and whether a summary exists.",
            "inputSchema": [
                "type": "object",
                "properties": [String: Any](),
            ],
        ],
        [
            "name": "get_note",
            "description": "Returns the full markdown of one meeting note. Pass a filename exactly as returned by list_meetings (leaf name only).",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "filename": ["type": "string", "description": "A meeting note filename from list_meetings, e.g. \"2026-07-06-1205 Weekly Sync.md\"."],
                ],
                "required": ["filename"],
            ],
        ],
    ]

    private func toolsCall(id: Any, params: [String: Any]) -> String? {
        guard let name = params["name"] as? String else {
            return errorLine(id: id, code: -32602, message: "Invalid params: missing tool name")
        }
        let arguments = params["arguments"] as? [String: Any] ?? [:]
        switch name {
        case "search_dictations":
            return searchDictations(id: id, arguments: arguments)
        case "list_meetings":
            return listMeetings(id: id)
        case "get_note":
            return getNote(id: id, arguments: arguments)
        default:
            return errorLine(id: id, code: -32602, message: "Unknown tool: \(name)")
        }
    }

    private func searchDictations(id: Any, arguments: [String: Any]) -> String? {
        guard let query = arguments["query"] as? String else {
            return errorLine(id: id, code: -32602, message: "Invalid params: 'query' (string) is required")
        }
        let store: HistoryStore
        switch history() {
        case .unavailable(let reason):
            return errorLine(id: id, code: -32002, message: "Dictation history unavailable: \(reason)")
        case .available(let s):
            store = s
        }
        let limit = max(1, min(arguments["limit"] as? Int ?? 20, 200))
        let iso = ISO8601DateFormatter()
        let rows: [[String: Any]] = store.search(query: query, limit: limit).map { r in
            [
                "timestamp": iso.string(from: r.timestamp),
                "text": r.cleanedText,
                "app_bundle_id": r.appBundleID ?? NSNull(),
                "duration_ms": r.durationMs,
            ]
        }
        return toolResultLine(id: id, json: ["matches": rows, "count": rows.count])
    }

    private func listMeetings(id: Any) -> String? {
        let iso = ISO8601DateFormatter()
        let metas: [[String: Any]] = NotesStore.listMeetings(in: meetingsFolder).map { m in
            [
                "filename": m.id,
                "title": m.title,
                "date": iso.string(from: m.date),
                "duration_seconds": m.durationSeconds,
                "hasSummary": m.hasSummary,
            ]
        }
        return toolResultLine(id: id, json: ["meetings": metas, "count": metas.count])
    }

    private func getNote(id: Any, arguments: [String: Any]) -> String? {
        guard let filename = arguments["filename"] as? String else {
            return errorLine(id: id, code: -32602, message: "Invalid params: 'filename' (string) is required")
        }
        switch MCPPathGuard.resolveNote(filename: filename, in: meetingsFolder) {
        case .rejected(let reason):
            return toolErrorLine(id: id, text: "Invalid filename: \(reason)")
        case .notFound:
            return toolErrorLine(id: id, text: "Note not found: \(filename)")
        case .ok(let url):
            guard let content = try? String(contentsOf: url, encoding: .utf8) else {
                return toolErrorLine(id: id, text: "Note could not be read: \(filename)")
            }
            return resultLine(id: id, result: [
                "content": [["type": "text", "text": content]],
            ])
        }
    }

    // MARK: - Envelope encoding

    /// Serializes a tool payload as compact JSON text inside an MCP tool result.
    private func toolResultLine(id: Any, json: [String: Any]) -> String? {
        resultLine(id: id, result: [
            "content": [["type": "text", "text": encodeJSON(json)]],
        ])
    }

    /// A tool-level failure (bad argument value, missing file): reported inside
    /// the result with isError, per the MCP spec, so the model can see it.
    private func toolErrorLine(id: Any, text: String) -> String? {
        resultLine(id: id, result: [
            "content": [["type": "text", "text": text]],
            "isError": true,
        ])
    }

    private func resultLine(id: Any, result: [String: Any]) -> String? {
        encodeLine(["jsonrpc": "2.0", "id": id, "result": result])
    }

    private func errorLine(id: Any, code: Int, message: String) -> String? {
        encodeLine(["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]])
    }

    /// Compact (newline-free) JSON — the stdio framing is one message per line.
    private func encodeLine(_ object: [String: Any]) -> String? {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else {
            return #"{"jsonrpc":"2.0","id":null,"error":{"code":-32603,"message":"Internal error: response encoding failed"}}"#
        }
        return String(data: data, encoding: .utf8)
    }

    private func encodeJSON(_ object: [String: Any]) -> String {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return "{}" }
        return text
    }
}
