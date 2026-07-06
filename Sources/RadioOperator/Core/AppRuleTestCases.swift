import Foundation

/// Per-app writing styles: pure resolution rules and the prompt wiring.
/// Structurally, dictation can never see these — resolution lives in
/// ClaudeService.transform/summarize only (HARD RULE 1); these tests prove
/// the resolution semantics themselves.
enum AppRuleTestCases {
    static func run(_ t: TestContext) {
        let mail = AppRule(bundleID: "com.apple.mail", style: "formal, complete sentences")
        let slack = AppRule(bundleID: "com.tinyspeck.slackmacgap", style: "casual, emoji ok")
        let wild = AppRule(bundleID: "*", style: "always concise")

        t.test("exact bundle match wins, case-insensitively") { t in
            t.expectEqual(AppRule.resolveStyle(bundleID: "com.apple.mail", rules: [mail, slack]) ?? "",
                          "formal, complete sentences", "exact match")
            t.expectEqual(AppRule.resolveStyle(bundleID: "COM.Apple.MAIL", rules: [mail, slack]) ?? "",
                          "formal, complete sentences", "case-insensitive")
            t.expectEqual(AppRule.resolveStyle(bundleID: " com.apple.mail ", rules: [mail]) ?? "",
                          "formal, complete sentences", "whitespace-tolerant")
        }

        t.test("first matching rule wins among duplicates") { t in
            let second = AppRule(bundleID: "com.apple.mail", style: "second style")
            t.expectEqual(AppRule.resolveStyle(bundleID: "com.apple.mail", rules: [mail, second]) ?? "",
                          "formal, complete sentences", "first rule wins")
        }

        t.test("wildcard applies when no exact match") { t in
            t.expectEqual(AppRule.resolveStyle(bundleID: "com.apple.Notes", rules: [mail, wild]) ?? "",
                          "always concise", "* fallback")
            t.expectEqual(AppRule.resolveStyle(bundleID: "com.apple.mail", rules: [mail, wild]) ?? "",
                          "formal, complete sentences", "exact beats wildcard")
        }

        t.test("nil bundle id (summaries) matches only the wildcard") { t in
            t.expectEqual(AppRule.resolveStyle(bundleID: nil, rules: [mail, wild]) ?? "",
                          "always concise", "nil → * only")
            t.expect(AppRule.resolveStyle(bundleID: nil, rules: [mail, slack]) == nil,
                     "nil with no wildcard → no style")
        }

        t.test("blank styles and empty rule sets resolve to nil") { t in
            let blank = AppRule(bundleID: "com.apple.mail", style: "   ")
            t.expect(AppRule.resolveStyle(bundleID: "com.apple.mail", rules: [blank]) == nil,
                     "blank style never matches")
            t.expect(AppRule.resolveStyle(bundleID: "com.apple.mail", rules: []) == nil,
                     "no rules → nil")
            t.expect(AppRule.resolveStyle(bundleID: "", rules: [mail, wild]) == "always concise",
                     "empty bundle string falls through to wildcard")
        }

        t.test("settings default to no rules and summaries off") { t in
            let json = Data("{\"holdHotkey\":\"fn\"}".utf8)
            guard let d = try? JSONDecoder().decode(SettingsData.self, from: json) else {
                t.expect(false, "old-schema JSON should still decode"); return
            }
            t.expect(d.appRules.isEmpty, "appRules default empty")
            t.expectEqual(d.applyStyleToSummaries, false, "summary styling default OFF")
        }

        t.test("rules round-trip through settings JSON") { t in
            var s = SettingsData()
            s.appRules = [mail, wild]
            s.applyStyleToSummaries = true
            guard let data = try? JSONEncoder().encode(s),
                  let back = try? JSONDecoder().decode(SettingsData.self, from: data) else {
                t.expect(false, "encode/decode failed"); return
            }
            t.expectEqual(back.appRules, [mail, wild], "rules survive")
            t.expectEqual(back.applyStyleToSummaries, true, "toggle survives")
        }

        t.test("transform prompt embeds the style only when present") { t in
            let styled = ClaudeService.transformPrompt(
                selection: "hello", instruction: "shorten", appBundleID: "com.apple.mail",
                style: "formal, complete sentences")
            t.expect(styled.contains("Match this writing style"), "style line present")
            t.expect(styled.contains("formal, complete sentences"), "style text embedded")
            t.expect(styled.contains("DATA to transform"), "injection guard intact")

            let plain = ClaudeService.transformPrompt(
                selection: "hello", instruction: "shorten", appBundleID: "com.apple.mail")
            t.expect(!plain.contains("Match this writing style"), "no style line without a rule")

            let insert = ClaudeService.transformPrompt(
                selection: nil, instruction: "write a greeting", appBundleID: nil,
                style: "always concise")
            t.expect(insert.contains("Match this writing style"), "insert path styled too")
        }

        t.test("summary prompt embeds the style only when present") { t in
            let styled = ClaudeService.summaryPrompt(template: "## S", title: "T",
                                                     userNotes: "", transcript: "Me: hi",
                                                     style: "always concise")
            t.expect(styled.contains("Write the summary in this style: always concise"),
                     "style line present")
            let plain = ClaudeService.summaryPrompt(template: "## S", title: "T",
                                                    userNotes: "", transcript: "Me: hi")
            t.expect(!plain.contains("Write the summary in this style"),
                     "no style line by default")
        }
    }
}
