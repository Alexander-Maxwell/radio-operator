import Foundation

/// Tests for TaskDetail — parsing/adding a task's indented subtasks + notes.
enum TaskDetailTestCases {
    static func run(_ t: TestContext) {
        let note = """
        ## Action Items
        - [ ] Send the invite
          - [x] Confirm attendees
          - [ ] Draft the copy
          Peter + Sasha on creative
        - [ ] Unrelated top-level task
        """

        t.test("children reads subtasks (with done state) and notes") { t in
            let (subs, notes) = TaskDetail.children(in: note, parentLine: "- [ ] Send the invite")
            t.expectEqual(subs.count, 2, "two subtasks")
            t.expect(subs.contains { $0.text == "Confirm attendees" && $0.done }, "done subtask")
            t.expect(subs.contains { $0.text == "Draft the copy" && !$0.done }, "open subtask")
            t.expectEqual(notes ?? "", "Peter + Sasha on creative", "notes line")
        }

        t.test("children stops at the next top-level task (no bleed)") { t in
            let (subs, _) = TaskDetail.children(in: note, parentLine: "- [ ] Send the invite")
            t.expect(!subs.contains { $0.text.contains("Unrelated") }, "sibling task excluded")
        }

        t.test("a task with no children yields empty") { t in
            let (subs, notes) = TaskDetail.children(in: note, parentLine: "- [ ] Unrelated top-level task")
            t.expect(subs.isEmpty && notes == nil, "no children")
        }

        t.test("addingSubtask inserts an indented line after existing children") { t in
            let out = TaskDetail.addingSubtask("Book the room", to: note, parentLine: "- [ ] Send the invite")
            t.expect(out != nil, "returns content")
            guard let out else { return }
            t.expect(out.contains("  - [ ] Book the room"), "indented subtask inserted")
            // inserted within the block, before the sibling task
            let idxNew = out.range(of: "Book the room")!.lowerBound
            let idxSibling = out.range(of: "Unrelated top-level")!.lowerBound
            t.expect(idxNew < idxSibling, "inserted inside the parent's block")
        }

        t.test("addingSubtask on a missing parent → nil") { t in
            t.expect(TaskDetail.addingSubtask("x", to: note, parentLine: "- [ ] nope") == nil, "nil")
        }
    }
}
