# Radio Operator — Tasks (Meeting-sourced Task Manager): Full Scope

**Version:** 1.0
**Status:** Draft (scoped 2026-07-07, awaiting build approval)
**Mode:** New Feature · Standard→Deep scope

## Problem Frame

Radio Operator already extracts **Action Items** from every meeting (Claude drafts
Summary / Decisions / Action Items / Follow-ups on meeting end; `MeetingNoteParser`
parses `- [ ]` lines into `ActionItem`; the meeting detail toggles them). But those
tasks are **siloed inside each meeting** — there is no one place to see everything
you owe, no due dates, no reminders, no way to add a task that didn't come from a
meeting. The work of *capturing* tasks is done; the work of *managing* them is missing.

This feature turns that latent, per-meeting action-item data into a **full task
manager** — cross-meeting aggregation + manual tasks + due dates/reminders +
priorities + projects + recurrence — **without abandoning the local-first,
notes-are-the-source-of-truth architecture** the app is built on.

## Grounding (what already exists — do not rebuild)

- `UI/MeetingNoteParser.swift` — `ActionItem { text, done, meta, sourceLine }`,
  `Note { actionItems, decisions, followUps, ... }`, `parse(_:)`, and
  `togglingCheckbox(in:sourceLine:)` (in-place, byte-preserving note rewrite).
- `Claude/ClaudeService.summaryPrompt` — already emits an Action Items section.
- `UI/MeetingsView.swift` — per-meeting action items with working checkbox toggle
  (`toggleAction` → `togglingCheckbox` → `NotesStore` write).
- `UI/HubView.swift` — `enum HubSection { dictations, meetings, ask, … }`, sidebar
  shell. A Tasks tab slots in here.
- Storage today: **markdown notes are canonical** (`NotesStore`, `Meetings/*.md`),
  `HistoryStore` (dictations only), `SettingsStore`. **No task database.**

## Key Decisions (locked with Maxwell 2026-07-07)

| Decision | Chosen | Rationale |
|----------|--------|-----------|
| Ambition | **Full task manager** | Maxwell wants RO to own tasks, not just list them. |
| Source of truth | **Notes / vault (markdown)** | Editable in Obsidian/V4, no note↔DB desync. |
| Metadata format | **Obsidian Tasks emoji format** | Interoperates with the V4 Obsidian vault's Tasks plugin; a standard, not bespoke. |
| v1 boundary | **Self-contained in RO** | No Apple Reminders / V4-action-center sync yet (fast-follow). |
| Index | **Derived cache, notes canonical** | Reminders + sorting need a query model; it is rebuilt from notes, never a 2nd SSOT. |

## How it looks (UI / UX)

**New Hub section: `Tasks`** — sidebar under Console, alongside Dictations / Meetings / Ask.
Sidebar item shows a **badge** = open + overdue count.

**Layout (top → bottom):**
1. **Quick-add bar** — "Add a task…". Accepts light inline tokens: `!high` priority,
   `#project` tag, and a natural due (`today`, `fri`, `2026-07-10`). Enter appends a
   task line to `Tasks.md`. A detail popover sets due/priority/project explicitly.
2. **Filter + sort bar** — filter by Status (Open / Done / All), Project, Due
   (Overdue / Today / Upcoming / None), Source (Meeting / Manual); sort by Due /
   Priority / Created / Meeting.
3. **Task list**, default **grouped by smart-date** (Overdue · Today · Upcoming ·
   No date); a toggle switches to **group-by-Project**. Each row:
   - checkbox (toggle → rewrites the source note in place),
   - task text,
   - chips: **due** (red overdue / amber today), **priority** flag, **#project**,
     **↩ from "Meeting title"** (deep-links to the source meeting detail),
     **🔁** glyph if recurring,
   - hover actions: set/clear due, set priority, edit, snooze, delete
     (delete only for manual tasks — meeting tasks are completed, never deleted,
     because they live in the meeting note).
4. **Empty state** — "No open tasks. Action items from your meetings show up here
   automatically."

**Reminders:** a macOS local notification fires when a task is due/overdue; clicking
it opens Tasks (or the source meeting). **Recurring:** completing a `🔁` task writes
the next occurrence back into its note.

## How it operates (data + flow)

**Source of truth = markdown notes.**
- Meeting tasks stay under `## Action Items` in each `Meetings/*.md`.
- Manual tasks live in a single **`Tasks.md`** inbox in the notes folder.
- Both are `- [ ]` lines in **Obsidian Tasks format**:
  `- [ ] Follow up with BevMo 📅 2026-07-10 ⏫ 🔁 every week #sip 🆔 a1b2c3`
  plus an optional `[[Meeting 2026-07-07 SIP Sync]]` backlink on meeting-sourced tasks.

**Derived index (cache, rebuildable):** on launch and on note change, scan
`Meetings/*.md` + `Tasks.md`, parse each task line into a `RadioTask`, hold them in
an in-memory index. The index drives the view, sort/filter, badge counts, and reminder
scheduling. Notes are canonical; edit a task in Obsidian and RO reconciles on rescan.

**Identity:** each task carries a `🆔`; meeting action items get one written lazily on
first interaction (toggle/edit) so reminders and recurrence can track them across edits.
Until then, identity = sourceFile + normalized text.

**Writes** reuse the existing in-place rewrite discipline (`togglingCheckbox` pattern):
toggling done, editing due/priority, and recurrence-spawn all rewrite the exact source
line in the source file, preserving everything else.

### Data model

```swift
struct RadioTask: Identifiable, Equatable, Sendable {
    let id: String                 // 🆔 or synthesized (sourceFile+normalizedText)
    var text: String
    var done: Bool
    var due: Date?
    var priority: Priority?         // .high / .medium / .low
    var project: String?            // #tag
    var recurrence: RecurrenceRule? // parsed from 🔁
    let source: Source              // .meeting(noteURL, title) | .manual
    let sourceFile: URL
    var sourceLine: String          // exact original line for in-place rewrite
}
```

## Requirements

| ID | Requirement | Priority |
|----|-------------|----------|
| R1 | Aggregate open + done action items across all meeting notes into one Tasks view | Must |
| R2 | Add manual tasks (quick-add) persisted to `Tasks.md` | Must |
| R3 | Toggle done rewrites the source note in place; recurring spawns the next occurrence | Must |
| R4 | Due dates; smart-date grouping (Overdue/Today/Upcoming/None); macOS reminder notifications | Must |
| R5 | Priorities (high/med/low) with sort + filter | Must |
| R6 | Projects (`#tag`) with grouping + filter | Must |
| R7 | Recurring tasks (Obsidian Tasks `🔁` semantics, common rules) | Must |
| R8 | Obsidian Tasks metadata format; notes remain canonical; index is a rebuildable cache | Must |
| R9 | Source link from a meeting task back to its meeting detail | Must |
| R10 | Sidebar (and menu-bar) badge: open + overdue count | Should |
| R11 | Inline edit of text / due / priority / project | Should |
| R12 | Snooze, bulk select, keyboard nav | Nice |

**Out of scope (v1):** Apple Reminders / EventKit two-way sync; V4 action-center push;
global quick-capture hotkey; subtasks; task dependencies; phone reminders.

## Implementation Units (recommended delivery order)

All four feature areas are in v1, but shipped in this sequence so a usable core lands
first and the riskiest pieces (reminders, recurrence) come after it is proven.

- **Unit 1 — `TaskLine` parse/format (pure, TDD).** `Core/TaskLine.swift` +
  `Core/TaskLineTestCases.swift`. Obsidian Tasks line ↔ `RadioTask` (checkbox, 📅 due,
  ⏫/🔼/🔽 priority, 🔁 recurrence, #project, 🆔). No I/O. Register in `TestRunner`.
  *Tests:* every field present/absent, round-trip, malformed line, unicode.
- **Unit 2 — Extend `MeetingNoteParser` + `TaskIndex`.** Teach the parser the emoji
  metadata; add `Core/TaskIndex.swift` that scans `Meetings/*.md` + `Tasks.md` → `[RadioTask]`,
  rebuildable, watches note changes. *Tests:* aggregation across files, dedup by id, done/open split.
- **Unit 3 — `TasksView` core (ships usable).** `UI/TasksView.swift` + `HubSection.tasks`
  + sidebar/routing in `HubView.swift`. Aggregation list, done-toggle (reuse
  `togglingCheckbox`), source deep-link, empty state.
- **Unit 4 — Manual add + edit.** Quick-add bar → append to `Tasks.md` (`NotesStore`
  gains `Tasks.md` read/append); inline edit rewrites source line.
- **Unit 5 — Query layer.** Due parsing + smart-date grouping, priority + project,
  sort/filter bar. Pure sort/filter logic unit-tested against the index.
- **Unit 6 — Reminders.** `Core/TaskReminders.swift` schedules `UNUserNotificationCenter`
  local notifications from the index; permission request + delegate in `RadioOperatorApp`;
  entitlement/bundle check. Reschedule on rebuild.
- **Unit 7 — Recurrence.** On completing a `🔁` task, compute next due and write the next
  `- [ ]` occurrence into the note (Obsidian Tasks semantics). Pure next-date logic unit-tested.
- **Unit 8 — Badges + settings + polish.** Sidebar/menu-bar counts; Settings → Tasks
  (Tasks.md location, reminders on/off, default reminder time).

**Touch points:** `MeetingNoteParser.swift`, `HubView.swift`, `NotesStore.swift`,
`RadioOperatorApp.swift`, `Claude/ClaudeService.swift` (optionally teach the summary
prompt to emit due/owner in the emoji format), `scripts/bundle.sh` + entitlements
(notifications), `TestRunner.swift`. New: `TaskLine.swift`, `TaskIndex.swift`,
`TaskReminders.swift`, `TasksView.swift` + test files.

## Risks

| Risk | Mitigation |
|------|-----------|
| Task identity/dedup drifts as notes are edited in Obsidian (desync-lite) | `🆔` written lazily; notes canonical; reconcile on rescan |
| Reminder correctness (timezones, reschedule after rebuild, duplicate fires) | Single scheduler owns notifications, keyed by task id; reschedule = clear+rebuild |
| Notifications permission is a new user prompt + entitlement | Request lazily on first due-date set; degrade gracefully if denied |
| Recurrence rule surface is large in Obsidian Tasks | v1 supports common rules (every day/week/month/N days); others parsed but not auto-spawned |
| Matching Obsidian Tasks emoji set exactly so the vault plugin agrees | Pin the exact glyph set in `TaskLine`; unit-test against real plugin examples |
| Writing `🆔` into meeting notes mutates the meeting note | Lazy + byte-preserving; the note stays the record of truth |

## Outstanding Questions

| # | Question | Impact if wrong |
|---|----------|-----------------|
| Q1 | Manual tasks: single `Tasks.md` inbox vs per-project files? (Recommend single inbox v1) | Data-model + write path |
| Q2 | Write `🆔` back into meeting notes on first interaction? (Recommend yes, lazy) | Identity stability for reminders/recurrence |
| Q3 | Default reminder time for a date-only due (e.g. 9am)? | Notification UX |
| Q4 | Should the meeting summary prompt start emitting `📅/owner` in emoji format? | Reduces manual due-setting, but changes Claude output |
