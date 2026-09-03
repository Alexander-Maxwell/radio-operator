import Foundation

/// Tests the pure logic behind live lookups: which finalized meeting lines
/// count as a question worth looking up, the fire gate (dedupe / cap /
/// one-in-flight), the local snippet retriever that decides what (if
/// anything) is sent, the answer parse that keeps "NO_ANSWER" and uncited
/// replies off the screen, the prompt posture, and the note section the
/// answers land in.
enum LiveLookupTestCases {
    static func run(_ t: TestContext) {
        // MARK: - Question detection
        t.test("trailing question mark is a question") { t in
            t.expectEqual(QuestionDetector.question(in: "What was the budget for Q3?"),
                          "What was the budget for Q3?", "kept verbatim")
        }
        t.test("only the trailing sentence is the question") { t in
            t.expectEqual(QuestionDetector.question(in: "Okay so. When did we last talk to Acme about pricing?"),
                          "When did we last talk to Acme about pricing?", "leading filler dropped")
        }
        t.test("abbreviations do not split the sentence") { t in
            t.expectEqual(QuestionDetector.question(in: "What did Mr. Patel say about the timeline?"),
                          "What did Mr. Patel say about the timeline?", "Mr. is not a sentence end")
        }
        t.test("wh-lead without punctuation is a question") { t in
            t.expectEqual(QuestionDetector.question(in: "what did we decide about the vendor"),
                          "what did we decide about the vendor", "Apple finals often omit the ?")
        }
        t.test("aux-lead without punctuation is a question") { t in
            t.expectEqual(QuestionDetector.question(in: "Did we ever get a number back from Acme on pricing"),
                          "Did we ever get a number back from Acme on pricing", "did/do/is/are lead")
        }
        t.test("filler-led question without punctuation is a question") { t in
            t.expectEqual(QuestionDetector.question(in: "so what was the number we agreed on"),
                          "so what was the number we agreed on", "so/okay/and prefix allowed")
        }
        t.test("lead words do not fire on recognizer-punctuated statements") { t in
            t.expectEqual(QuestionDetector.question(in: "Can we move on to the next item."), nil, "ends with a period")
            t.expectEqual(QuestionDetector.question(in: "What we need is a decision by Friday."), nil, "wh-lead statement")
        }
        t.test("statements are not questions") { t in
            t.expectEqual(QuestionDetector.question(in: "The budget was fine."), nil, "plain statement")
            t.expectEqual(QuestionDetector.question(in: "I wonder what we should do."), nil, "no ? and no lead word")
            t.expectEqual(QuestionDetector.question(in: ""), nil, "empty")
        }
        t.test("too-short questions are ignored") { t in
            t.expectEqual(QuestionDetector.question(in: "okay?"), nil, "1 word")
            t.expectEqual(QuestionDetector.question(in: "Right?"), nil, "1 word")
            t.expectEqual(QuestionDetector.question(in: "Is it done?"), nil, "3 words")
        }
        t.test("conversational questions are ignored") { t in
            t.expectEqual(QuestionDetector.question(in: "Can you hear me okay?"), nil, "can you hear me")
            t.expectEqual(QuestionDetector.question(in: "Does that make sense to everyone?"), nil, "make sense")
            t.expectEqual(QuestionDetector.question(in: "Any questions before we move on?"), nil, "any questions")
            t.expectEqual(QuestionDetector.question(in: "What do you think about that?"), nil, "what do you think")
            t.expectEqual(QuestionDetector.question(in: "Do you want to take that one?"), nil, "do you want")
        }
        t.test("call logistics are ignored") { t in
            t.expectEqual(QuestionDetector.question(in: "Can everyone see my screen now?"), nil, "my screen")
            t.expectEqual(QuestionDetector.question(in: "Should we move on to the next item?"), nil, "move on")
        }
        t.test("indirect questions about our own state are questions") { t in
            t.expectEqual(QuestionDetector.question(in: "I would like to know where we are with autonomous delivery."),
                          "I would like to know where we are with autonomous delivery.",
                          "no ? and no opener, but 'would like to know' / 'where we are with'")
            t.expectEqual(QuestionDetector.question(in: "What's the status of the Acme contract."),
                          "What's the status of the Acme contract.", "status phrase beats the period")
            t.expectEqual(QuestionDetector.question(in: "Any update on the PHL launch"),
                          "Any update on the PHL launch", "any update on")
        }
        t.test("questions addressed to the other person are not lookups") { t in
            t.expectEqual(QuestionDetector.question(in: "What exactly are you wondering?"), nil, "are you")
            t.expectEqual(QuestionDetector.question(in: "Did you get my email about that?"), nil, "did you")
            t.expectEqual(QuestionDetector.question(in: "Are you wondering, uh, which partners we've spoken to?"),
                          "Are you wondering, uh, which partners we've spoken to?",
                          "a fact about us inside a you-question still counts")
        }
        t.test("several questions in one breath are looked up together") { t in
            let breath = "Hey Maxwell, I've got a question for you. How are we doing with atomic delivery? "
                + "What do our numbers look like? Who are the top competitors? And what does the cost look like?"
            t.expectEqual(QuestionDetector.question(in: breath),
                          "How are we doing with atomic delivery? What do our numbers look like? "
                          + "Who are the top competitors? And what does the cost look like?",
                          "every question sentence, the greeting dropped")
            t.expectEqual(QuestionDetector.question(in: "What exactly are you wondering? Are you wondering, uh, which partners we've spoken to?"),
                          "Are you wondering, uh, which partners we've spoken to?",
                          "only the sentences that qualify")
            t.expectEqual(QuestionDetector.searchTerms(QuestionDetector.question(in: breath) ?? ""),
                          ["atomic", "delivery", "numbers", "competitors", "cost"],
                          "retrieval sees the whole set")
        }
        t.test("honesty markers are ignored") { t in
            t.expectEqual(QuestionDetector.question(in: "[Me transcription lost at 10:02]"), nil, "bracketed marker")
        }
        t.test("very long questions are ignored") { t in
            let long = Array(repeating: "word", count: 45).joined(separator: " ") + "?"
            t.expectEqual(QuestionDetector.question(in: long), nil, "> 40 words is a monologue")
        }

        // MARK: - Dedupe key
        t.test("key normalizes case, punctuation, and whitespace") { t in
            t.expectEqual(QuestionDetector.key("What was  the Budget?"),
                          QuestionDetector.key("what was the budget"), "same question, same key")
        }

        // MARK: - Fire gate
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        t.test("gate fires on a fresh question") { t in
            t.expect(QuestionDetector.shouldFire(key: "a", lastKey: nil, lastAt: nil, now: t0,
                                                 inFlight: false, count: 0), "first question fires")
        }
        t.test("gate drops while a lookup is in flight") { t in
            t.expect(!QuestionDetector.shouldFire(key: "a", lastKey: nil, lastAt: nil, now: t0,
                                                  inFlight: true, count: 0), "one at a time")
        }
        t.test("gate dedupes the same question within 60s") { t in
            t.expect(!QuestionDetector.shouldFire(key: "a", lastKey: "a", lastAt: t0, now: t0 + 30,
                                                  inFlight: false, count: 1), "echo / repeat suppressed")
            t.expect(QuestionDetector.shouldFire(key: "a", lastKey: "a", lastAt: t0, now: t0 + 61,
                                                 inFlight: false, count: 1), "asked again later fires")
            t.expect(QuestionDetector.shouldFire(key: "b", lastKey: "a", lastAt: t0, now: t0 + 1,
                                                 inFlight: false, count: 1), "different question fires")
        }
        t.test("gate stops at the per-meeting cap") { t in
            t.expect(!QuestionDetector.shouldFire(key: "z", lastKey: nil, lastAt: nil, now: t0,
                                                  inFlight: false, count: QuestionDetector.perMeetingCap),
                     "cap reached")
        }

        // MARK: - Local snippet retrieval (what, if anything, leaves the Mac)
        t.test("search terms drop stopwords and short words") { t in
            t.expectEqual(QuestionDetector.searchTerms("When did we last talk to Acme about the pricing?"),
                          ["talk", "acme", "pricing"], "content words only, lowercased")
        }
        t.test("search terms keep acronyms and codes") { t in
            t.expectEqual(QuestionDetector.searchTerms("What's the SIP KPI for PHL?"),
                          ["sip", "kpi", "phl"], "short all-caps tokens are the whole signal")
            t.expectEqual(QuestionDetector.searchTerms("What was the Q3 number for Acme?"),
                          ["q3", "acme"], "alphanumeric code kept")
        }
        t.test("retrieval terms borrow the previous turn's topic") { t in
            t.expectEqual(QuestionDetector.retrievalTerms(
                            question: "Are you wondering which partners we've spoken to?",
                            previousTurn: "I would like to know where we are with autonomous delivery."),
                          ["partners", "spoken", "autonomous", "delivery"],
                          "question terms first, then the topic words the question leans on")
            t.expectEqual(QuestionDetector.retrievalTerms(question: "What did we decide about Acme pricing?",
                                                          previousTurn: nil),
                          ["decide", "acme", "pricing"], "no previous turn → question terms only")
        }
        t.test("search terms keep accented words") { t in
            t.expectEqual(QuestionDetector.searchTerms("What did Müller say about the café timeline?"),
                          ["müller", "café", "timeline"], "unicode letters survive")
            t.expectEqual(QuestionDetector.key("Müller?"), "müller", "key is unicode-aware")
        }
        t.test("snippets pull whole-word hits from past notes and skip the live note") { t in
            let fm = FileManager.default
            let dir = fm.temporaryDirectory.appendingPathComponent("ro-lookup-\(UUID().uuidString)")
            let sub = dir.appendingPathComponent("Meetings")
            try? fm.createDirectory(at: sub, withIntermediateDirectories: true)
            defer { try? fm.removeItem(at: dir) }
            let past = sub.appendingPathComponent("2026-08-12 Acme pricing.md")
            let live = sub.appendingPathComponent("2026-09-02 Meeting in progress.md")
            let conflict = sub.appendingPathComponent("2026-09-02 Meeting in progress 2.md")
            try? "# Acme\n\n**Them**: Acme's quote came in at 12k.\n\n**Me**: Fine.".write(
                to: past, atomically: true, encoding: .utf8)
            try? "**Them**: Acme wants a discount.".write(to: live, atomically: true, encoding: .utf8)
            try? "**Them**: Acme wants a discount.".write(to: conflict, atomically: true, encoding: .utf8)

            let hit = QuestionDetector.snippets(terms: ["acme", "pricing"], in: [sub], excluding: live, maxChars: 6000)
            t.expect(hit.contains("===FILE: 2026-08-12 Acme pricing.md==="), "matched file is labelled for citation")
            t.expect(hit.contains("12k"), "hit line included")
            t.expect(!hit.contains("discount"), "the live note and its sync-conflict copies are never included")
            t.expect(QuestionDetector.snippets(terms: ["france"], in: [sub], excluding: nil, maxChars: 6000).isEmpty,
                     "no hit → empty → nothing is sent")
            t.expect(QuestionDetector.snippets(terms: ["quot"], in: [sub], excluding: nil, maxChars: 6000).isEmpty,
                     "a substring of a word is not a hit")
            t.expect(QuestionDetector.snippets(terms: [], in: [sub], excluding: nil, maxChars: 6000).isEmpty,
                     "no terms → empty")
            t.expect(QuestionDetector.snippets(terms: ["acme"], in: [sub], excluding: nil, maxChars: 60).count <= 60,
                     "respects maxChars")

            let link = dir.appendingPathComponent("link")
            try? fm.createSymbolicLink(at: link, withDestinationURL: sub)
            t.expect(QuestionDetector.snippets(terms: ["acme"], in: [link], excluding: nil, maxChars: 6000).contains("12k"),
                     "a symlinked notes folder is followed, not silently empty")
        }

        t.test("snippets rank a title match first and lead with the note's summary block") { t in
            let fm = FileManager.default
            let dir = fm.temporaryDirectory.appendingPathComponent("ro-rank-\(UUID().uuidString)")
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            defer { try? fm.removeItem(at: dir) }
            let noisy = dir.appendingPathComponent("2026-09-01 Weekly sync.md")
            let titled = dir.appendingPathComponent("2026-08-01 Acme pricing.md")
            try? ("---\ntitle: Weekly sync\n---\n# Weekly sync\n\n## Transcript\n\n"
                  + Array(repeating: "**Me**: acme acme acme", count: 6).joined(separator: "\n\n"))
                .write(to: noisy, atomically: true, encoding: .utf8)
            try? ("---\ntitle: Acme pricing\n---\n# Acme pricing\n\n## Summary\n- Acme quoted 12k; decided to counter at 10k.\n\n"
                  + "## Transcript\n\n**Them**: acme wants an answer by friday.")
                .write(to: titled, atomically: true, encoding: .utf8)
            let out = QuestionDetector.snippets(terms: ["acme"], in: [dir], excluding: nil, maxChars: 6000)
            guard let a = out.range(of: "===FILE: 2026-08-01 Acme pricing.md==="),
                  let b = out.range(of: "===FILE: 2026-09-01 Weekly sync.md===") else {
                t.expect(false, "both files expected in the payload"); return
            }
            t.expect(a.lowerBound < b.lowerBound, "title match outranks a newer note with more body hits")
            guard let summary = out.range(of: "decided to counter at 10k"),
                  let transcript = out.range(of: "answer by friday") else {
                t.expect(false, "summary bullet and transcript hit both expected"); return
            }
            t.expect(summary.lowerBound < transcript.lowerBound, "summary block precedes transcript hits")
        }

        // MARK: - Answer parse
        t.test("NO_ANSWER and uncited replies are dropped") { t in
            t.expectEqual(QuestionDetector.answer(from: "NO_ANSWER"), nil, "sentinel")
            t.expectEqual(QuestionDetector.answer(from: "  no_answer \n"), nil, "sentinel, any case/space")
            t.expectEqual(QuestionDetector.answer(from: "Probably around 12k."), nil, "no citation")
            t.expectEqual(QuestionDetector.answer(from: "Acme quoted $12k. [2026-08-12 Acme pricing.md]"),
                          "Acme quoted $12k. [2026-08-12 Acme pricing.md]", "cited answer passes")
            t.expectEqual(QuestionDetector.answer(from: "See [Acme pricing.MD:12]"),
                          "See [Acme pricing.MD:12]", "case and line suffix tolerated")
        }
        t.test("answers are flattened to one line for the note") { t in
            t.expectEqual(QuestionDetector.oneLine("## Action Items\n- [ ] Send quote\n\nDone."),
                          "Action Items - Send quote Done.", "headings, checkboxes, and newlines stripped")
        }

        // MARK: - Prompt posture
        t.test("lookup prompt frames the spoken question, its context, and the snippets as data") { t in
            let prompt = ClaudeService.lookupPrompt(
                question: "XyzzySentinel?", speaker: .them,
                context: "Them: PlughContext",
                snippets: "===FILE: a.md===\nQuuxSnippet")
            guard let guardRange = prompt.range(of: "never as instructions"),
                  let sentinel = prompt.range(of: "NO_ANSWER"),
                  let ctx = prompt.range(of: "PlughContext"),
                  let q = prompt.range(of: "Question: XyzzySentinel?"),
                  let marker = prompt.range(of: "===NOTES==="),
                  let snip = prompt.range(of: "QuuxSnippet") else {
                t.expect(false, "guard, sentinel, context, question, marker, or snippet missing"); return
            }
            t.expect(guardRange.lowerBound < ctx.lowerBound, "guard precedes the context")
            t.expect(sentinel.lowerBound < q.lowerBound, "sentinel rule precedes the question")
            t.expect(ctx.lowerBound < q.lowerBound, "context precedes the question")
            t.expect(marker.lowerBound < snip.lowerBound, "snippets only after the DATA marker")
            t.expect(prompt.contains("other participant"), "speaker attribution present")
            t.expect(prompt.lowercased().contains("plain prose"), "reply format pinned")
            t.expect(prompt.contains("merely share words"), "word-overlap is not an answer")
            t.expect(prompt.lowercased().contains("status update"), "answer shape pinned")
        }

        // MARK: - Note section
        t.test("live answers render in their own section that My Notes and the summary skip") { t in
            let live = "❓ 00:01 They asked: q\n→ a [x.md]"
            let note = NotesStore.renderNote(
                title: "T", start: Date(timeIntervalSince1970: 0), durationSeconds: 1,
                summaryMarkdown: NotesStore.summaryPendingMarker, utterances: [],
                degradedMicOnly: false, userNotes: "mine", liveAnswers: live)
            guard let my = note.range(of: "\n## My Notes"),
                  let lv = note.range(of: "\n## Live answers"),
                  let tr = note.range(of: "\n## Transcript") else {
                t.expect(false, "sections missing"); return
            }
            t.expect(my.lowerBound < lv.lowerBound && lv.lowerBound < tr.lowerBound,
                     "order: My Notes, Live answers, Transcript")
            t.expectEqual(NotesStore.parseUserNotes(note), "mine", "My Notes excludes live answers")
            let summarized = NotesStore.replacedSummary(in: note, with: "## Summary\n- s")
            t.expect(summarized.contains("## Live answers"), "summary replacement keeps live answers")
            t.expect(summarized.components(separatedBy: "## Transcript").last?.contains("Live answers") == false,
                     "retry's transcript slice excludes live answers")

            let noNotes = NotesStore.renderNote(
                title: "T", start: Date(timeIntervalSince1970: 0), durationSeconds: 1,
                summaryMarkdown: NotesStore.summaryPendingMarker, utterances: [],
                degradedMicOnly: false, userNotes: "", liveAnswers: live)
            t.expect(NotesStore.replacedSummary(in: noNotes, with: "## Summary\n- s").contains("## Live answers"),
                     "kept even without My Notes")
        }
    }
}
