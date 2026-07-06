import Foundation

/// Pure-parser tests for the radiooperator:// URL scheme. The parser is
/// `AppDelegate.parseURLCommand(_:)` — nonisolated and side-effect-free, so
/// these run headless with no NSApplication.
enum URLCommandTestCases {
    private static func parse(_ s: String) -> URLCommand? {
        guard let url = URL(string: s) else { return nil }
        return AppDelegate.parseURLCommand(url)
    }

    static func run(_ t: TestContext) {
        t.test("dictate toggles") { t in
            t.expectEqual(parse("radiooperator://dictate"), .dictateToggle, "plain")
            t.expectEqual(parse("radiooperator://dictate/"), .dictateToggle, "trailing slash")
            t.expectEqual(parse("RADIOOPERATOR://Dictate"), .dictateToggle, "case-insensitive")
        }
        t.test("meeting start/stop") { t in
            t.expectEqual(parse("radiooperator://meeting/start"), .meetingStart, "start")
            t.expectEqual(parse("radiooperator://meeting/stop"), .meetingStop, "stop")
            t.expectEqual(parse("radiooperator://meeting/STOP"), .meetingStop, "case-insensitive path")
            t.expectEqual(parse("radiooperator://meeting/start/"), .meetingStart, "trailing slash")
        }
        t.test("hub sections") { t in
            t.expectEqual(parse("radiooperator://hub/library"), .hub(.library), "library")
            t.expectEqual(parse("radiooperator://hub/ask"), .hub(.ask), "ask")
            t.expectEqual(parse("radiooperator://hub/dictionary"), .hub(.dictionary), "dictionary")
            t.expectEqual(parse("radiooperator://hub/snippets"), .hub(.snippets), "snippets")
            // "settings" lands on the same section as the Settings… menu item.
            t.expectEqual(parse("radiooperator://hub/settings"), .hub(.dictation), "settings")
        }
        t.test("junk input maps to unknown, never crashes") { t in
            t.expectEqual(parse("https://example.com"), .unknown, "wrong scheme")
            t.expectEqual(parse("radiooperator://"), .unknown, "no host")
            t.expectEqual(parse("radiooperator://bogus"), .unknown, "unknown host")
            t.expectEqual(parse("radiooperator://dictate/extra"), .unknown, "extra segment")
            t.expectEqual(parse("radiooperator://meeting"), .unknown, "meeting missing verb")
            t.expectEqual(parse("radiooperator://meeting/pause"), .unknown, "unknown verb")
            t.expectEqual(parse("radiooperator://meeting/start/now"), .unknown, "too many segments")
            t.expectEqual(parse("radiooperator://hub"), .unknown, "hub missing section")
            t.expectEqual(parse("radiooperator://hub/general"), .unknown, "unrouted section")
            t.expectEqual(parse("radiooperator://hub/library/deep"), .unknown, "too deep")
            t.expectEqual(parse("radiooperator:dictate"), .unknown, "opaque form, no host")
            t.expectEqual(parse("mailto:x@y.z"), .unknown, "foreign scheme")
        }
        t.test("unparseable strings never reach the parser") { t in
            t.expect(URL(string: "not a url ://") == nil, "spaces reject at URL init")
            t.expect(URL(string: "") == nil, "empty string rejects at URL init")
        }
    }
}
