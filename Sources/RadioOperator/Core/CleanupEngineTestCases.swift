import Foundation

/// Ported from Tests/Radio OperatorTests/CleanupEngineTests.swift (Swift Testing)
/// to the micro harness in TestRunner.swift.

private func makeSettings(
    level: CleanupLevel = .standard,
    dictionary: [DictionaryEntry] = [],
    snippets: [Snippet] = []
) -> SettingsData {
    var settings = SettingsData()
    settings.cleanupLevel = level
    settings.dictionary = dictionary
    settings.snippets = snippets
    return settings
}

private let signature = [Snippet(trigger: "sig work", expansion: "Best,\nMaxwell")]

enum CleanupEngineTestCases {
    static func run(_ t: TestContext) {

        // MARK: - Fillers

        t.test("filler happy path") { t in
            let out = CleanupEngine.clean(
                "um so basically i think we should uh move the meeting to thursday",
                settings: makeSettings()
            )
            // "basically" is not a filler; standalone "i" is not capitalized.
            t.expectEqual(out, "So basically i think we should move the meeting to thursday", "filler removal")
        }

        t.test("filler comma debris is cleaned") { t in
            t.expectEqual(CleanupEngine.removeFillers("Hello, um, world"), "Hello, world", "mid-sentence um")
            t.expectEqual(CleanupEngine.removeFillers("Um, so we should"), "so we should", "leading um")
            t.expectEqual(CleanupEngine.removeFillers("It was, like, huge"), "It was, huge", "mid-sentence like")
            t.expectEqual(CleanupEngine.removeFillers("I mean, we should go"), "we should go", "leading i mean")
            t.expectEqual(CleanupEngine.removeFillers("that was sort of like a dream"), "that was a dream", "sort of like")
        }

        t.test("fillers do not touch normal words") { t in
            t.expectEqual(CleanupEngine.removeFillers("I like dogs"), "I like dogs", "like as verb")
            t.expectEqual(CleanupEngine.removeFillers("what i mean is clear"), "what i mean is clear", "i mean as content")
            t.expectEqual(CleanupEngine.removeFillers("the drum and the gum are fine"), "the drum and the gum are fine", "um inside words")
        }

        t.test("empty and whitespace-only inputs") { t in
            for level in CleanupLevel.allCases {
                let settings = makeSettings(level: level)
                t.expectEqual(CleanupEngine.clean("", settings: settings), "", "empty at level \(level)")
                t.expectEqual(CleanupEngine.clean("   \n\t  ", settings: settings), "", "whitespace at level \(level)")
            }
            t.expectEqual(CleanupEngine.removeFillers(""), "", "removeFillers empty")
            t.expectEqual(CleanupEngine.normalize(""), "", "normalize empty")
        }

        // MARK: - Dictionary

        t.test("dictionary replaces at every sentence start") { t in
            let settings = makeSettings(
                dictionary: [DictionaryEntry(spoken: "gopuff", written: "Gopuff")]
            )
            let out = CleanupEngine.clean("gopuff is great. gopuff ships fast", settings: settings)
            t.expectEqual(out, "Gopuff is great. Gopuff ships fast", "dictionary at sentence starts")
        }

        t.test("lowercase written is capitalized at sentence start only") { t in
            let entries = [DictionaryEntry(spoken: "acme", written: "acme.io")]
            let out = CleanupEngine.applyDictionary("acme is great. we like acme", entries: entries)
            t.expectEqual(out, "Acme.io is great. we like acme.io", "capitalize only at sentence start")
        }

        t.test("dictionary respects word boundaries") { t in
            let entries = [DictionaryEntry(spoken: "sip", written: "SIP")]
            t.expectEqual(CleanupEngine.applyDictionary("all the gossip in town", entries: entries),
                          "all the gossip in town", "no substring match")
            t.expectEqual(CleanupEngine.applyDictionary("take a sip now", entries: entries),
                          "take a SIP now", "whole-word match")
        }

        t.test("longest spoken phrase wins") { t in
            let settings = makeSettings(dictionary: [
                DictionaryEntry(spoken: "sip", written: "SIP"),
                DictionaryEntry(spoken: "sip program", written: "SIP Program"),
            ])
            t.expectEqual(CleanupEngine.clean("the sip program rocks", settings: settings),
                          "The SIP Program rocks", "longest phrase wins")
        }

        // MARK: - Snippets

        t.test("snippet exact trigger returns expansion verbatim") { t in
            let settings = makeSettings(snippets: signature)
            t.expectEqual(CleanupEngine.clean("Sig work.", settings: settings), "Best,\nMaxwell", "exact trigger")
        }

        t.test("snippet matches after filler removal") { t in
            let settings = makeSettings(snippets: signature)
            t.expectEqual(CleanupEngine.clean("Um, sig work!", settings: settings), "Best,\nMaxwell", "trigger after fillers")
        }

        t.test("snippet partial match passes through") { t in
            t.expectEqual(CleanupEngine.expandSnippets("sig working late", snippets: signature),
                          "sig working late", "partial trigger untouched")
        }

        // MARK: - Levels

        t.test("off level returns trimmed raw with fillers intact") { t in
            let settings = makeSettings(level: .off)
            t.expectEqual(CleanupEngine.clean("  hello  ", settings: settings), "hello", "trim only")
            t.expectEqual(CleanupEngine.clean(" um hello ", settings: settings), "um hello", "fillers intact")
        }

        t.test("light level skips dictionary and snippets") { t in
            let settings = makeSettings(
                level: .light,
                dictionary: [DictionaryEntry(spoken: "gopuff", written: "Gopuff")],
                snippets: signature
            )
            t.expectEqual(CleanupEngine.clean("um hello gopuff", settings: settings), "Hello gopuff", "dictionary skipped")
            // Not expanded to the signature; only normalized.
            t.expectEqual(CleanupEngine.clean("sig work", settings: settings), "Sig work", "snippet skipped")
        }

        // MARK: - Voice commands

        t.test("new paragraph command") { t in
            t.expectEqual(CleanupEngine.clean("first point new paragraph second point", settings: makeSettings()),
                          "First point\n\nSecond point", "bare new paragraph")
            t.expectEqual(CleanupEngine.clean("Thanks. New paragraph. Best regards", settings: makeSettings()),
                          "Thanks.\n\nBest regards", "punctuated new paragraph")
        }

        t.test("new line command") { t in
            t.expectEqual(CleanupEngine.clean("item one new line item two", settings: makeSettings()),
                          "Item one\nItem two", "bare new line")
        }

        t.test("article-protected new line is not a command") { t in
            t.expectEqual(CleanupEngine.clean("we need a new line of products", settings: makeSettings()),
                          "We need a new line of products", "a new line")
            t.expectEqual(CleanupEngine.clean("start the new paragraph tomorrow", settings: makeSettings()),
                          "Start the new paragraph tomorrow", "the new paragraph")
        }

        t.test("scratch that removes previous sentence") { t in
            t.expectEqual(CleanupEngine.clean("send it Monday. scratch that. send it Friday", settings: makeSettings()),
                          "Send it Friday", "sentence backtrack")
        }

        t.test("scratch that removes previous clause") { t in
            t.expectEqual(CleanupEngine.clean("use the red one scratch that use the blue one", settings: makeSettings()),
                          "Use the blue one", "mid-sentence backtrack")
        }

        t.test("commands run at light level") { t in
            t.expectEqual(CleanupEngine.clean("um one new line two", settings: makeSettings(level: .light)),
                          "One\nTwo", "light level commands")
        }

        t.test("command output is idempotent") { t in
            let settings = makeSettings()
            for input in ["first point new paragraph second point",
                          "send it Monday. scratch that. send it Friday"] {
                let once = CleanupEngine.clean(input, settings: settings)
                t.expectEqual(CleanupEngine.clean(once, settings: settings), once,
                              "not idempotent for: \(input)")
            }
        }

        // MARK: - Normalize

        t.test("normalize spacing and capitalization") { t in
            t.expectEqual(CleanupEngine.normalize("hello   world , yes"), "Hello world, yes", "spacing and comma")
            t.expectEqual(CleanupEngine.normalize("go home. we are done"), "Go home. We are done", "sentence capitalization")
            t.expectEqual(CleanupEngine.normalize("he said.Then left"), "He said. Then left", "space after period")
            t.expectEqual(CleanupEngine.normalize("it costs 5.50 total"), "It costs 5.50 total", "decimal untouched")
            t.expectEqual(CleanupEngine.normalize("visit example.com today"), "Visit example.com today", "domain untouched")
            t.expectEqual(CleanupEngine.normalize("über cool"), "über cool", "non-ASCII start")
        }

        t.test("normalize preserves line breaks and collapses blank runs") { t in
            t.expectEqual(CleanupEngine.normalize("one\ntwo"), "One\nTwo", "single line break")
            t.expectEqual(CleanupEngine.normalize("one\n\n\n\ntwo"), "One\n\nTwo", "blank run collapsed")
        }

        // MARK: - Unicode and stability

        t.test("unicode passes through untouched") { t in
            let input = "Café ☕️ costs €5"
            t.expectEqual(CleanupEngine.clean(input, settings: makeSettings()), input, "unicode passthrough")
        }

        t.test("clean is idempotent") { t in
            let settings = makeSettings(
                dictionary: [
                    DictionaryEntry(spoken: "sip", written: "SIP"),
                    DictionaryEntry(spoken: "sip program", written: "SIP Program"),
                    DictionaryEntry(spoken: "gopuff", written: "Gopuff"),
                ],
                snippets: signature
            )
            let inputs = [
                "um so basically i think we should uh move the meeting to thursday",
                "Hello, um, world",
                "gopuff is great. gopuff ships fast",
                "the sip program rocks",
                "first line\n\n\n\nsecond line",
                "Café ☕️ costs €5",
            ]
            for input in inputs {
                let once = CleanupEngine.clean(input, settings: settings)
                t.expectEqual(CleanupEngine.clean(once, settings: settings), once,
                              "not idempotent for: \(input)")
            }
        }
    }
}
