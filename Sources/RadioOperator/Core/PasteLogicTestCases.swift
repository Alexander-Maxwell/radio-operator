import AppKit

/// Tests for PasteService's extracted pure logic: the paste/clipboard-only
/// precheck decision (every branch — a wrong call here silently loses
/// dictated text) and the concealed-pasteboard staging regression lock
/// (a missing marker leaks every dictation into clipboard-manager history).
enum PasteLogicTestCases {
    static func run(_ t: TestContext) {
        t.test("all preconditions pass → paste") { t in
            t.expectEqual(
                PasteService.pasteDecision(secureInput: false, targetTerminated: false,
                                           refocusNeeded: false, refocusSettled: true),
                .paste, "clean path")
        }
        t.test("refocus needed and settled → paste") { t in
            t.expectEqual(
                PasteService.pasteDecision(secureInput: false, targetTerminated: false,
                                           refocusNeeded: true, refocusSettled: true),
                .paste, "settled refocus pastes")
        }
        t.test("secure input → clipboard only") { t in
            t.expectEqual(
                PasteService.pasteDecision(secureInput: true, targetTerminated: false,
                                           refocusNeeded: false, refocusSettled: true),
                .clipboardOnly(reason: "Secure input active — press ⌘V to paste"),
                "secure input blocks the keystroke")
        }
        t.test("secure input outranks every other failure") { t in
            t.expectEqual(
                PasteService.pasteDecision(secureInput: true, targetTerminated: true,
                                           refocusNeeded: true, refocusSettled: false),
                .clipboardOnly(reason: "Secure input active — press ⌘V to paste"),
                "secure-input reason wins")
        }
        t.test("terminated target → clipboard only") { t in
            t.expectEqual(
                PasteService.pasteDecision(secureInput: false, targetTerminated: true,
                                           refocusNeeded: false, refocusSettled: true),
                .clipboardOnly(reason: "The app you were in closed — press ⌘V where you want the text"),
                "dead target")
        }
        t.test("terminated target outranks refocus failure") { t in
            t.expectEqual(
                PasteService.pasteDecision(secureInput: false, targetTerminated: true,
                                           refocusNeeded: true, refocusSettled: false),
                .clipboardOnly(reason: "The app you were in closed — press ⌘V where you want the text"),
                "terminated reason wins over refocus")
        }
        t.test("refocus failed → clipboard only") { t in
            t.expectEqual(
                PasteService.pasteDecision(secureInput: false, targetTerminated: false,
                                           refocusNeeded: true, refocusSettled: false),
                .clipboardOnly(reason: "Couldn't refocus the app — press ⌘V where you want the text"),
                "unsettled refocus")
        }
        t.test("unsettled flag ignored when no refocus was needed") { t in
            t.expectEqual(
                PasteService.pasteDecision(secureInput: false, targetTerminated: false,
                                           refocusNeeded: false, refocusSettled: false),
                .paste, "settled only matters when refocus ran")
        }

        t.test("stage sets string and concealed marker together") { t in
            let pb = NSPasteboard(name: NSPasteboard.Name("ro-test-paste-\(UUID().uuidString)"))
            defer { pb.releaseGlobally() }
            let count = PasteService.stage("dictated words", on: pb)
            t.expectEqual(pb.string(forType: .string) ?? "", "dictated words", "text staged")
            t.expectEqual(pb.string(forType: PasteService.concealedType) ?? "", "1",
                          "org.nspasteboard.ConcealedType marker present")
            t.expectEqual(count, pb.changeCount, "returned changeCount matches pasteboard")
        }
        t.test("stage replaces prior contents") { t in
            let pb = NSPasteboard(name: NSPasteboard.Name("ro-test-paste-\(UUID().uuidString)"))
            defer { pb.releaseGlobally() }
            pb.clearContents()
            pb.setString("previous", forType: .string)
            let before = pb.changeCount
            let count = PasteService.stage("new text", on: pb)
            t.expectEqual(pb.string(forType: .string) ?? "", "new text", "old contents replaced")
            t.expect(count > before, "changeCount advanced")
        }
    }
}
