import Foundation

/// Pure-aggregation tests for the Preflight verdict matrix. The live
/// gatherer needs TCC/Keychain/models and stays out of the core tier;
/// everything decided FROM those facts is proven here.
enum PreflightTestCases {
    static func run(_ t: TestContext) {
        /// A fully healthy machine.
        func healthy() -> Preflight.Inputs {
            Preflight.Inputs(
                speechModelAvailable: true,
                microphone: .granted, accessibility: .granted, inputMonitoring: .granted,
                claudeMode: .cli, apiKeyPresent: false, cliPresent: true, cliAuthed: true,
                notesFolderWritable: true, freeDiskBytes: 50_000_000_000)
        }

        t.test("healthy inputs pass everything") { t in
            let r = Preflight.report(healthy())
            t.expectEqual(r.checks.count, 8, "all eight checks present")
            t.expect(r.checks.allSatisfy(\.isPass), "every check passes")
            t.expect(r.dictationReady, "dictation ready")
            t.expect(!r.hasFailure, "no failures")
        }

        t.test("missing speech model is a failure that blocks dictation") { t in
            var i = healthy()
            i.speechModelAvailable = false
            let r = Preflight.report(i)
            t.expect(r.check(.speechModel)?.isFail ?? false, "model check fails")
            t.expect(!r.dictationReady, "dictation not ready")
            t.expect(r.hasFailure, "report has a failure")
        }

        t.test("permission statuses map to pass/warn/fail") { t in
            var i = healthy()
            i.microphone = .notDetermined
            i.accessibility = .denied
            let r = Preflight.report(i)
            if case .warn = r.check(.microphone)?.verdict {} else {
                t.expect(false, "notDetermined → warn (will prompt)")
            }
            t.expect(r.check(.accessibility)?.isFail ?? false, "denied → fail")
            t.expect(!r.dictationReady, "warn/fail permissions block dictation-ready")
        }

        t.test("intelligence gaps degrade to warn, never fail") { t in
            var i = healthy()
            i.cliPresent = false
            let r = Preflight.report(i)
            if case .warn = r.check(.claudeCLI)?.verdict {} else {
                t.expect(false, "missing CLI is a warn — the app still dictates")
            }
            if case .warn = r.check(.claudeAuth)?.verdict {} else {
                t.expect(false, "auth check warns when there is no CLI")
            }
            t.expect(!r.hasFailure, "no failure from intelligence gaps")
            t.expect(r.dictationReady, "dictation unaffected")

            var signedOut = healthy()
            signedOut.cliAuthed = false
            let r2 = Preflight.report(signedOut)
            if case .warn = r2.check(.claudeAuth)?.verdict {} else {
                t.expect(false, "signed-out CLI is a warn")
            }
        }

        t.test("API mode ignores the CLI and checks the key") { t in
            var i = healthy()
            i.claudeMode = .api
            i.cliPresent = false
            i.cliAuthed = false
            i.apiKeyPresent = true
            let r = Preflight.report(i)
            t.expect(r.check(.claudeCLI)?.isPass ?? false, "CLI not needed in API mode")
            t.expect(r.check(.claudeAuth)?.isPass ?? false, "key present → pass")

            i.apiKeyPresent = false
            let r2 = Preflight.report(i)
            if case .warn = r2.check(.claudeAuth)?.verdict {} else {
                t.expect(false, "API mode with no key warns")
            }
        }

        t.test("notes folder and disk gate on failure thresholds") { t in
            var i = healthy()
            i.notesFolderWritable = false
            t.expect(Preflight.report(i).check(.notesFolder)?.isFail ?? false,
                     "unwritable notes folder fails")

            var disk = healthy()
            disk.freeDiskBytes = Preflight.minFreeDiskBytes - 1
            t.expect(Preflight.report(disk).check(.diskSpace)?.isFail ?? false,
                     "below 1 GB fails")
            disk.freeDiskBytes = Preflight.minFreeDiskBytes
            t.expect(Preflight.report(disk).check(.diskSpace)?.isPass ?? false,
                     "exactly 1 GB passes")
            disk.freeDiskBytes = nil
            if case .warn = Preflight.report(disk).check(.diskSpace)?.verdict {} else {
                t.expect(false, "unknown capacity is a warn, not a silent pass")
            }
        }

        t.test("disk detail uses the deterministic size formatter") { t in
            var i = healthy()
            i.freeDiskBytes = 5_000_000_000
            t.expect(Preflight.report(i).check(.diskSpace)?.detail.contains("5.0 GB") ?? false,
                     "free space rendered human-readable")
        }
    }
}
