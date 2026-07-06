import Foundation

/// Tests for DictationController.finalizeOutcome — the raw-empty ×
/// finished-cleanly × cleaned-empty decision at the end of every dictation.
/// The consequential cells: a finalize timeout with no finals must surface
/// as an error (words are lost, silence would hide it), and a cleanup that
/// eats everything must dismiss quietly, never paste an empty string.
enum DictationFinalizeTestCases {
    static func run(_ t: TestContext) {
        typealias DC = DictationController

        t.test("nothing heard, finished cleanly → quiet discard") { t in
            t.expectEqual(
                DC.finalizeOutcome(rawEmpty: true, finishedCleanly: true, cleanedEmpty: true),
                .discardQuiet, "accidental tap dismisses silently")
        }
        t.test("nothing heard, finalize timed out → error") { t in
            t.expectEqual(
                DC.finalizeOutcome(rawEmpty: true, finishedCleanly: false, cleanedEmpty: true),
                .errorTimeout, "lost words must surface, never silent-dismiss")
        }
        t.test("heard something, cleanup ate it all → quiet discard") { t in
            t.expectEqual(
                DC.finalizeOutcome(rawEmpty: false, finishedCleanly: true, cleanedEmpty: true),
                .discardQuiet, "pure filler pastes nothing")
        }
        t.test("heard something, cleaned text present → paste") { t in
            t.expectEqual(
                DC.finalizeOutcome(rawEmpty: false, finishedCleanly: true, cleanedEmpty: false),
                .paste, "normal dictation pastes")
        }
        t.test("timeout with partial finals still pastes what was captured") { t in
            // finishAndWait timing out does NOT discard finals that already
            // arrived — the user gets the words that made it through.
            t.expectEqual(
                DC.finalizeOutcome(rawEmpty: false, finishedCleanly: false, cleanedEmpty: false),
                .paste, "partial capture beats losing everything")
        }
        t.test("timeout with finals that cleaned to nothing → quiet discard") { t in
            t.expectEqual(
                DC.finalizeOutcome(rawEmpty: false, finishedCleanly: false, cleanedEmpty: true),
                .discardQuiet, "filler-only partial capture is not an error")
        }
    }
}
