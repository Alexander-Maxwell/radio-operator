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
    /// Returns true if tests were requested and run (caller exits).
    static func handleIfRequested() -> Bool {
        guard CommandLine.arguments.contains("--run-tests") else { return false }
        let t = TestContext()
        CleanupEngineTestCases.run(t)
        TranscriptAssemblerTestCases.run(t)
        NotesStoreTestCases.run(t)
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
    }
}
