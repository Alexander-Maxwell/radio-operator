import Foundation

/// Tests for the diagnostics export's pure pieces: the subsystem filter that
/// keeps framework chatter out, and the render whose header carries the
/// no-content-logged guarantee. OSLogStore itself is exercised on-device.
enum DiagnosticsTestCases {
    static func run(_ t: TestContext) {
        t.test("subsystem filter keeps app lines, drops framework noise") { t in
            t.expect(DiagnosticsExport.shouldInclude(subsystem: ""), "NSLog (empty subsystem) is ours")
            t.expect(DiagnosticsExport.shouldInclude(subsystem: "com.warroom.radiooperator"),
                     "app subsystem is ours")
            t.expect(!DiagnosticsExport.shouldInclude(subsystem: "com.apple.avfaudio"),
                     "framework subsystem excluded")
            t.expect(!DiagnosticsExport.shouldInclude(subsystem: "com.apple.TCC"),
                     "system subsystem excluded")
            t.expect(!DiagnosticsExport.shouldInclude(subsystem: "com.warroom.radiooperator.extra"),
                     "prefix match is not enough — exact only")
        }

        t.test("render header states the privacy guarantee and locality") { t in
            let out = DiagnosticsExport.render(lines: [],
                                               generatedAt: Date(timeIntervalSince1970: 1_780_000_000))
            t.expect(out.contains("never logs dictation, transcript, or selection content"),
                     "no-content guarantee present")
            t.expect(out.contains("written locally"), "local-only statement present")
            t.expect(out.contains("last 24h"), "window stated")
            t.expect(out.contains("(no app log entries in the window)"), "empty window is explicit")
        }

        t.test("render formats entries deterministically") { t in
            let lines = [
                DiagnosticsExport.Line(date: Date(timeIntervalSince1970: 1_780_000_000),
                                       level: "error", subsystem: "", category: "",
                                       message: "MicCapture: no microphone input available."),
                DiagnosticsExport.Line(date: Date(timeIntervalSince1970: 1_780_000_060),
                                       level: "info", subsystem: "com.warroom.radiooperator",
                                       category: "paste", message: "precheck ok"),
            ]
            let out = DiagnosticsExport.render(lines: lines,
                                               generatedAt: Date(timeIntervalSince1970: 1_780_000_100))
            t.expect(out.contains("[error] NSLog: MicCapture: no microphone input available."),
                     "empty subsystem labeled NSLog")
            t.expect(out.contains("[info] com.warroom.radiooperator/paste: precheck ok"),
                     "subsystem/category line rendered")
            t.expect(out.contains("2026-05-28"), "ISO date rendered")
        }

        t.test("suggested filename is stamped and extensioned") { t in
            let name = DiagnosticsExport.suggestedFilename(for: Date(timeIntervalSince1970: 1_780_000_000))
            t.expect(name.hasPrefix("radio-operator-diagnostics-"), "prefix")
            t.expect(name.hasSuffix(".log"), "extension")
        }
    }
}
