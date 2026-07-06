import Foundation

/// Micro test harness: the Command Line Tools toolchain ships no usable
/// Swift Testing / XCTest modules, so unit tests run inside the app binary
/// via `RadioOperator --run-tests` (wired in RadioOperatorApp.main / Makefile `test`).
final class TestContext {
    private(set) var passed = 0
    private(set) var failures: [String] = []
    private var currentTest = ""

    func test(_ name: String, _ body: (TestContext) -> Void) {
        currentTest = name
        let before = failures.count
        body(self)
        if failures.count == before {
            passed += 1
        }
    }

    func expect(_ condition: Bool, _ message: String = "expectation failed",
                file: StaticString = #file, line: UInt = #line) {
        if !condition {
            failures.append("[\(currentTest)] \(message) (\(file):\(line))")
        }
    }

    func expectEqual<T: Equatable>(_ a: T, _ b: T, _ message: String = "",
                                   file: StaticString = #file, line: UInt = #line) {
        if a != b {
            failures.append("[\(currentTest)] \(message) — got: \(a) expected: \(b) (\(file):\(line))")
        }
    }
}

enum TestRunner {
    /// Core tier: deterministic, offline, no hardware/TCC/network. Runs on
    /// every `--run-tests` invocation and is the whole CI merge gate (D10).
    static let coreSuites: [(name: String, run: (TestContext) -> Void)] = [
        ("CleanupEngine", CleanupEngineTestCases.run),
        ("TranscriptAssembler", TranscriptAssemblerTestCases.run),
        ("NotesStore", NotesStoreTestCases.run),
        ("HistoryStore", HistoryStoreTestCases.run),
        ("MiscFeature", MiscFeatureTestCases.run),
        ("WordErrorRate", WordErrorRateTestCases.run),
        ("MCP", MCPTestCases.run),
        ("CommandMode", CommandModeTestCases.run),
        ("URLCommand", URLCommandTestCases.run),
        ("PasteLogic", PasteLogicTestCases.run),
        ("DictationFinalize", DictationFinalizeTestCases.run),
        ("MicConvert", MicConvertTestCases.run),
        ("ClaudeService", ClaudeServiceTestCases.run),
    ]

    /// Device tier: suites that need real hardware, TCC grants, or a signed-in
    /// Claude CLI. Empty today — those checks live in the manual probes
    /// (`--probe-*`, see docs/device-checklist.md). Skipped by `--core-only`.
    static let deviceSuites: [(name: String, run: (TestContext) -> Void)] = []

    /// Returns true if tests were requested and run (caller exits).
    static func handleIfRequested() -> Bool {
        let args = CommandLine.arguments
        guard args.contains("--run-tests") else { return false }
        let coreOnly = args.contains("--core-only")
        let t = TestContext()
        var suiteCounts: [String: Int] = [:]
        var suites = coreSuites
        if !coreOnly { suites += deviceSuites }
        for suite in suites {
            let before = t.passed
            suite.run(t)
            suiteCounts[suite.name] = t.passed - before
        }
        if let flagIndex = args.firstIndex(of: "--tests-json"), flagIndex + 1 < args.count {
            writeJSON(to: args[flagIndex + 1], passed: t.passed,
                      failures: t.failures, suites: suiteCounts)
        }
        print("PASSED: \(t.passed)")
        if t.failures.isEmpty {
            print("ALL TESTS PASSED")
            exit(0)
        } else {
            print("FAILED: \(t.failures.count)")
            for f in t.failures { print("  ✗ \(f)") }
            exit(1)
        }
    }

    /// Machine-readable results for CI annotation / trend tracking:
    /// `{passed, failures: [...], suites: {name: count}}`.
    private static func writeJSON(to path: String, passed: Int,
                                  failures: [String], suites: [String: Int]) {
        let payload: [String: Any] = [
            "passed": passed,
            "failures": failures,
            "suites": suites,
        ]
        guard let data = try? JSONSerialization.data(
            withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]) else {
            print("tests-json: could not serialize results")
            return
        }
        do {
            try data.write(to: URL(fileURLWithPath: path))
        } catch {
            print("tests-json: could not write \(path): \(error.localizedDescription)")
        }
    }
}

/// Small pure-logic checks for NotesStore helpers (rendering/parsing).
enum NotesStoreTestCases {
    static func run(_ t: TestContext) {
        t.test("frontmatter round-trip") { t in
            let note = NotesStore.renderNote(
                title: "Budget Sync", start: Date(timeIntervalSince1970: 1_780_000_000),
                durationSeconds: 300, summaryMarkdown: NotesStore.summaryPendingMarker,
                utterances: [Utterance(speaker: .me, text: "hello",
                                       start: Date(timeIntervalSince1970: 1_780_000_000),
                                       end: Date(timeIntervalSince1970: 1_780_000_002))],
                degradedMicOnly: false)
            let fm = NotesStore.parseFrontmatter(note)
            t.expectEqual(fm["title"] ?? "", "Budget Sync", "title")
            t.expectEqual(fm["summary"] ?? "", "pending", "summary flag")
            t.expectEqual(fm["duration_seconds"] ?? "", "300", "duration")
            t.expect(note.contains("**Me**"), "transcript line present")
        }
        t.test("filename sanitization") { t in
            t.expectEqual(NotesStore.sanitizeFilename("a/b:c?d*e|f\"g<h>i#j"), "a b c d e f g h i j")
            t.expect(NotesStore.sanitizeFilename(String(repeating: "x", count: 100)).count <= 60, "cap length")
            t.expectEqual(NotesStore.sanitizeFilename("  hi  "), "hi", "trim")
        }
        t.test("degraded banner in note") { t in
            let note = NotesStore.renderNote(
                title: "T", start: Date(), durationSeconds: 1,
                summaryMarkdown: "s", utterances: [], degradedMicOnly: true)
            t.expect(note.contains("microphone-only"), "degraded marker present")
        }
        t.test("retitled content swaps frontmatter and H1") { t in
            let note = NotesStore.renderNote(
                title: "Meeting in progress", start: Date(timeIntervalSince1970: 1_780_000_000),
                durationSeconds: 0, summaryMarkdown: NotesStore.summaryPendingMarker,
                utterances: [], degradedMicOnly: false)
            let out = NotesStore.retitledContent(note, title: "Budget Sync")
            t.expectEqual(NotesStore.parseFrontmatter(out)["title"] ?? "", "Budget Sync", "frontmatter title")
            t.expect(out.contains("\n# Budget Sync"), "H1 swapped")
            t.expect(!out.contains("Meeting in progress"), "old title gone")
        }
        t.test("retitled filename keeps stamp") { t in
            t.expectEqual(
                NotesStore.retitledFilename(currentStem: "2026-07-02-0930 Meeting in progress",
                                            title: "Budget Sync"),
                "2026-07-02-0930 Budget Sync", "stamp preserved")
            t.expectEqual(
                NotesStore.retitledFilename(currentStem: "custom name", title: "Budget Sync"),
                "Budget Sync", "no stamp falls back to title")
        }
        t.test("performRetitle renames note and audio") { t in
            let fm = FileManager.default
            let tmp = fm.temporaryDirectory.appendingPathComponent("ro-test-\(UUID().uuidString)")
            let meetings = tmp.appendingPathComponent("Meetings")
            let audio = tmp.appendingPathComponent("Audio")
            try? fm.createDirectory(at: meetings, withIntermediateDirectories: true)
            try? fm.createDirectory(at: audio, withIntermediateDirectories: true)
            defer { try? fm.removeItem(at: tmp) }

            let old = meetings.appendingPathComponent("2026-07-02-0930 Meeting in progress.md")
            let note = NotesStore.renderNote(
                title: "Meeting in progress", start: Date(timeIntervalSince1970: 1_780_000_000),
                durationSeconds: 60, summaryMarkdown: "## Summary\n- s",
                utterances: [], degradedMicOnly: false)
            try? note.write(to: old, atomically: true, encoding: .utf8)
            let oldAudio = audio.appendingPathComponent("2026-07-02-0930 Meeting in progress - me.m4a")
            try? Data("x".utf8).write(to: oldAudio)

            let newURL = NotesStore.performRetitle(noteURL: old, title: "Budget Sync", audioFolder: audio)
            t.expectEqual(newURL.lastPathComponent, "2026-07-02-0930 Budget Sync.md", "new filename")
            t.expect(fm.fileExists(atPath: newURL.path), "new file exists")
            t.expect(!fm.fileExists(atPath: old.path), "old file gone")
            t.expect(fm.fileExists(atPath: audio.appendingPathComponent("2026-07-02-0930 Budget Sync - me.m4a").path),
                     "audio moved with note")
            let content = (try? String(contentsOf: newURL, encoding: .utf8)) ?? ""
            t.expect(content.contains("# Budget Sync"), "content retitled")
        }
        t.test("replacedSummary preserves my notes") { t in
            let note = NotesStore.renderNote(
                title: "T", start: Date(), durationSeconds: 5,
                summaryMarkdown: NotesStore.summaryPendingMarker,
                utterances: [], degradedMicOnly: false, userNotes: "remember the budget")
            let out = NotesStore.replacedSummary(in: note, with: "## Summary\n- did things")
            t.expect(out.contains("## Summary\n- did things"), "summary replaced")
            t.expect(!out.contains(NotesStore.summaryPendingMarker), "pending marker gone")
            t.expect(out.contains("## My Notes"), "my notes section preserved")
            t.expect(out.contains("remember the budget"), "note text preserved")
            t.expect(out.contains("summary: done"), "frontmatter flag flipped")
            t.expect(out.contains("## Transcript"), "transcript intact")
        }
        t.test("userNotes render and parse round-trip") { t in
            let note = NotesStore.renderNote(
                title: "T", start: Date(), durationSeconds: 5,
                summaryMarkdown: "s", utterances: [], degradedMicOnly: false,
                userNotes: "key point\nsecond line")
            t.expectEqual(NotesStore.parseUserNotes(note) ?? "", "key point\nsecond line", "round trip")
            let plain = NotesStore.renderNote(
                title: "T", start: Date(), durationSeconds: 5,
                summaryMarkdown: "s", utterances: [], degradedMicOnly: false)
            t.expect(!plain.contains("## My Notes"), "no section when empty")
            t.expect(NotesStore.parseUserNotes(plain) == nil, "nil when absent")
        }
        t.test("appendDictation writes daily log") { t in
            let fm = FileManager.default
            let tmp = fm.temporaryDirectory.appendingPathComponent("ro-dict-\(UUID().uuidString)")
            try? fm.createDirectory(at: tmp, withIntermediateDirectories: true)
            defer { try? fm.removeItem(at: tmp) }
            let date = Date(timeIntervalSince1970: 1_780_000_000)
            NotesStore.appendDictation(text: "hello world", appName: "com.tinyspeck.slackmacgap",
                                       date: date, folder: tmp)
            NotesStore.appendDictation(text: "second entry", appName: nil, date: date, folder: tmp)
            let df = DateFormatter()
            df.dateFormat = "yyyy-MM-dd"
            let url = tmp.appendingPathComponent("\(df.string(from: date)).md")
            let content = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            t.expect(content.contains("hello world"), "first entry present")
            t.expect(content.contains("second entry"), "second entry appended")
            t.expect(content.contains("com.tinyspeck.slackmacgap"), "app recorded")
        }
    }
}
