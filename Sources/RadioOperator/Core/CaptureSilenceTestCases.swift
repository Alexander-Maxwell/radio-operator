import Foundation

/// Tests for CaptureSilenceCheck.decide — the pure verdict behind MicCapture's
/// start-of-capture silence watchdog. Deterministic, offline; the hardware
/// rebuild it triggers is covered by the live `--probe-capture` gate.
enum CaptureSilenceTestCases {
    static func run(_ t: TestContext) {
        t.test("real audio → ok") { t in
            t.expectEqual(CaptureSilenceCheck.decide(
                buffersArrived: true, sawSignal: true,
                voiceProcessingActive: true, alreadyHealed: false), .ok)
        }

        // A slow mic that hasn't delivered a buffer yet must NOT be judged
        // silent — that would rebuild the engine out from under a healthy mic.
        t.test("no buffers yet → waiting, not a silence verdict") { t in
            t.expectEqual(CaptureSilenceCheck.decide(
                buffersArrived: false, sawSignal: false,
                voiceProcessingActive: true, alreadyHealed: false), .waiting)
        }

        // The exact VPIO-silence signature: buffers flow, all zero, VPIO on.
        t.test("silent buffers with VPIO on → self-heal") { t in
            t.expectEqual(CaptureSilenceCheck.decide(
                buffersArrived: true, sawSignal: false,
                voiceProcessingActive: true, alreadyHealed: false), .selfHeal)
        }

        // Silent with VPIO already off — rebuilding won't help; surface it.
        t.test("silent buffers, VPIO already off → report, cannot heal") { t in
            t.expectEqual(CaptureSilenceCheck.decide(
                buffersArrived: true, sawSignal: false,
                voiceProcessingActive: false, alreadyHealed: false), .reportSilent)
        }

        // Loop guard: never rebuild twice for the same silent session.
        t.test("silent, VPIO on but already healed → report, do not loop") { t in
            t.expectEqual(CaptureSilenceCheck.decide(
                buffersArrived: true, sawSignal: false,
                voiceProcessingActive: true, alreadyHealed: true), .reportSilent)
        }

        // Signal present wins even post-heal — no needless second rebuild.
        t.test("signal present outweighs VPIO-on / healed flags → ok") { t in
            t.expectEqual(CaptureSilenceCheck.decide(
                buffersArrived: true, sawSignal: true,
                voiceProcessingActive: true, alreadyHealed: true), .ok)
        }
    }
}
