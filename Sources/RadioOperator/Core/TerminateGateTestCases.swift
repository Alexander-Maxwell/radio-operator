import Foundation

/// Tests the quit-while-recording reply invariant (`TerminateOnceGate`): the app
/// must reply to `.terminateLater` EXACTLY once, from whichever of {stop
/// finished, hard deadline} fires first, in any order. This is the core of the
/// fix for the "Stop Meeting & Quit does nothing" hang, where the old fixed-timer
/// path re-entered `applicationShouldTerminate` and re-showed the dialog. Pure —
/// no NSApplication needed.
enum TerminateGateTestCases {
    static func run(_ t: TestContext) {
        t.test("three triggers reply exactly once") { t in
            var n = 0
            let g = TerminateOnceGate { n += 1 }
            g.trigger(); g.trigger(); g.trigger()
            t.expectEqual(n, 1, "idempotent")
        }
        t.test("stop-then-deadline replies once") { t in
            var n = 0
            let g = TerminateOnceGate { n += 1 }
            g.trigger()   // stop path finished (transcript flushed)
            g.trigger()   // hard deadline fires later — must no-op
            t.expectEqual(n, 1, "stop wins, deadline no-ops")
        }
        t.test("deadline-only path replies once") { t in
            var n = 0
            let g = TerminateOnceGate { n += 1 }
            g.trigger()   // teardown wedged, only the deadline fired
            t.expectEqual(n, 1, "quit still guaranteed")
        }
        t.test("no trigger means no reply") { t in
            var n = 0
            _ = TerminateOnceGate { n += 1 }
            t.expectEqual(n, 0, "reply is not fired on its own")
        }
    }
}
