import Foundation

/// Ported from Tests/Radio OperatorTests/TranscriptAssemblerTests.swift (Swift Testing)
/// to the micro harness in TestRunner.swift.

/// Builds a deterministic event anchored at epoch + 1000s + `seconds`.
private func makeEvent(
    _ channel: Speaker,
    _ text: String,
    isFinal: Bool = true,
    at seconds: TimeInterval,
    audioStart: TimeInterval? = nil,
    audioEnd: TimeInterval? = nil
) -> TranscriptEvent {
    TranscriptEvent(
        channel: channel,
        text: text,
        isFinal: isFinal,
        audioStart: audioStart,
        audioEnd: audioEnd,
        wallClock: Date(timeIntervalSince1970: 1000 + seconds)
    )
}

enum TranscriptAssemblerTestCases {
    static func run(_ t: TestContext) {

        // MARK: - Ordering and merging

        t.test("interleaved channels produce ordered utterances") { t in
            let assembler = TranscriptAssembler()
            assembler.ingest(makeEvent(.me, "first", at: 0))
            assembler.ingest(makeEvent(.them, "second", at: 5))
            assembler.ingest(makeEvent(.me, "third", at: 10))

            t.expectEqual(assembler.utterances.count, 3, "utterance count")
            t.expectEqual(assembler.utterances.map(\.speaker), [.me, .them, .me], "speaker order")
            t.expectEqual(assembler.utterances.map(\.text), ["first", "second", "third"], "text order")
        }

        t.test("same speaker merges inside window") { t in
            let assembler = TranscriptAssembler()
            assembler.ingest(makeEvent(.me, "hello", at: 0))
            assembler.ingest(makeEvent(.me, "world", at: 1))

            t.expectEqual(assembler.utterances.count, 1, "merged into one utterance")
            t.expectEqual(assembler.utterances[0].text, "hello world", "merged text")
            t.expectEqual(assembler.utterances[0].start, Date(timeIntervalSince1970: 1000), "start preserved")
            t.expectEqual(assembler.utterances[0].end, Date(timeIntervalSince1970: 1001), "end extended")
        }

        t.test("same speaker does not merge outside window") { t in
            let assembler = TranscriptAssembler()
            assembler.ingest(makeEvent(.me, "hello", at: 0))
            assembler.ingest(makeEvent(.me, "world", at: 3))

            t.expectEqual(assembler.utterances.count, 2, "two utterances")
            t.expectEqual(assembler.utterances.map(\.text), ["hello", "world"], "texts kept separate")
        }

        t.test("late arriving them final inserts in start order") { t in
            let assembler = TranscriptAssembler()
            assembler.ingest(makeEvent(.me, "me speaks later", at: 10))
            assembler.ingest(makeEvent(.them, "them spoke first", at: 5))

            t.expectEqual(assembler.utterances.count, 2, "utterance count")
            t.expectEqual(assembler.utterances[0].speaker, .them, "first speaker")
            t.expectEqual(assembler.utterances[0].text, "them spoke first", "first text")
            t.expectEqual(assembler.utterances[1].speaker, .me, "second speaker")
            t.expectEqual(assembler.utterances[1].text, "me speaks later", "second text")
        }

        t.test("late arrival merges with utterance preceding insertion point") { t in
            let assembler = TranscriptAssembler()
            assembler.ingest(makeEvent(.them, "we should", at: 0))
            assembler.ingest(makeEvent(.me, "sure", at: 10))
            // Late them final whose start falls between the two existing utterances:
            // it must merge into the them utterance that precedes its insertion point.
            assembler.ingest(makeEvent(.them, "sync tomorrow", at: 1))

            t.expectEqual(assembler.utterances.count, 2, "utterance count")
            t.expectEqual(assembler.utterances[0].text, "we should sync tomorrow", "merged them text")
            t.expectEqual(assembler.utterances[0].end, Date(timeIntervalSince1970: 1001), "merged end")
            t.expectEqual(assembler.utterances[1].text, "sure", "me text untouched")
        }

        t.test("start derived from audio timestamps when both present") { t in
            let assembler = TranscriptAssembler()
            assembler.ingest(makeEvent(.me, "hello", at: 5, audioStart: 1.0, audioEnd: 3.5))

            let first = assembler.utterances.first
            t.expect(first != nil, "has an utterance")
            guard let utterance = first else { return }
            t.expectEqual(utterance.end, Date(timeIntervalSince1970: 1005), "end from wall clock")
            t.expectEqual(utterance.start, Date(timeIntervalSince1970: 1002.5), "start from audio duration")
        }

        // MARK: - Volatiles

        t.test("volatile replaces and final clears") { t in
            let assembler = TranscriptAssembler()
            assembler.ingest(makeEvent(.me, "hel", isFinal: false, at: 0))
            assembler.ingest(makeEvent(.me, "hello th", isFinal: false, at: 0.5))

            t.expectEqual(assembler.volatileMe, "hello th", "latest hypothesis wins")
            t.expect(assembler.utterances.isEmpty, "no finals yet")

            assembler.ingest(makeEvent(.me, "hello there", at: 1))

            t.expectEqual(assembler.volatileMe, "", "final clears volatile")
            t.expectEqual(assembler.utterances.map(\.text), ["hello there"], "final recorded")
        }

        t.test("empty volatile text clears hypothesis") { t in
            let assembler = TranscriptAssembler()
            assembler.ingest(makeEvent(.them, "thinking out", isFinal: false, at: 0))
            assembler.ingest(makeEvent(.them, "", isFinal: false, at: 1))

            t.expectEqual(assembler.volatileThem, "", "empty volatile clears")
        }

        t.test("whitespace-only final is skipped but still clears volatile") { t in
            let assembler = TranscriptAssembler()
            assembler.ingest(makeEvent(.me, "mumbl", isFinal: false, at: 0))
            assembler.ingest(makeEvent(.me, "   ", at: 1))

            t.expect(assembler.utterances.isEmpty, "whitespace final skipped")
            t.expectEqual(assembler.volatileMe, "", "volatile cleared")
        }

        // MARK: - Echo guard

        t.test("echo guard drops me final matching nearby them utterance") { t in
            let assembler = TranscriptAssembler(echoGuard: true)
            assembler.ingest(makeEvent(.them, "let's move the meeting to thursday afternoon", at: 0))
            assembler.ingest(makeEvent(.me, "move the meeting to thursday", at: 1))

            t.expectEqual(assembler.utterances.count, 1, "echo dropped")
            t.expectEqual(assembler.utterances[0].speaker, .them, "them kept")
            t.expectEqual(assembler.utterances[0].text, "let's move the meeting to thursday afternoon", "them text intact")
        }

        t.test("echo guard off keeps both channels") { t in
            let assembler = TranscriptAssembler(echoGuard: false)
            assembler.ingest(makeEvent(.them, "let's move the meeting to thursday afternoon", at: 0))
            assembler.ingest(makeEvent(.me, "move the meeting to thursday", at: 1))

            t.expectEqual(assembler.utterances.count, 2, "both kept with guard off")
        }

        t.test("echo guard keeps short overlapping matches") { t in
            let assembler = TranscriptAssembler(echoGuard: true)
            assembler.ingest(makeEvent(.them, "yes", at: 0))
            assembler.ingest(makeEvent(.me, "yes", at: 1))

            t.expectEqual(assembler.utterances.count, 2, "short matches kept")
        }

        t.test("echo guard ignores them utterances outside overlap window") { t in
            let assembler = TranscriptAssembler(echoGuard: true)
            assembler.ingest(makeEvent(.them, "move the meeting to thursday", at: 0))
            // Same text, but 10s away — outside the ±3s overlap window, so kept.
            assembler.ingest(makeEvent(.me, "move the meeting to thursday", at: 10))

            t.expectEqual(assembler.utterances.count, 2, "outside window kept")
        }

        // MARK: - finish / reset

        t.test("finish clears volatiles and returns utterances") { t in
            let assembler = TranscriptAssembler()
            assembler.ingest(makeEvent(.me, "hello", at: 0))
            assembler.ingest(makeEvent(.me, "still talking", isFinal: false, at: 1))
            assembler.ingest(makeEvent(.them, "still replying", isFinal: false, at: 1))

            let result = assembler.finish()

            t.expectEqual(result.map(\.text), ["hello"], "finish returns finals only")
            t.expectEqual(assembler.volatileMe, "", "me volatile cleared")
            t.expectEqual(assembler.volatileThem, "", "them volatile cleared")
            t.expect(assembler.utterances == result, "utterances match finish result")
        }

        t.test("reset empties everything") { t in
            let assembler = TranscriptAssembler()
            assembler.ingest(makeEvent(.me, "hello", at: 0))
            assembler.ingest(makeEvent(.them, "hypothesis", isFinal: false, at: 1))

            assembler.reset()

            t.expect(assembler.utterances.isEmpty, "utterances emptied")
            t.expectEqual(assembler.volatileMe, "", "me volatile emptied")
            t.expectEqual(assembler.volatileThem, "", "them volatile emptied")
        }
    }
}
