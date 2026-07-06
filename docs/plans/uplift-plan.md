# Radio Operator — Six-Area Uplift Plan

**Version:** 1.0
**Status:** Draft (planning complete, awaiting owner decisions)
**Date:** 2026-07-06
**Baseline:** v0.2.0, competitive scorecard vs Wispr Flow + OpenWhispr
**Constraint:** Stay Mac-native (single Swift process + Apple SpeechAnalyzer primary). No Electron, no cross-platform rewrite. Preserve the security/privacy posture that scored highest.

---

## Strategy in one line

**Ship trust first** (notarize + Sparkle auto-update + iCloud-folder sync + at-rest encryption — ~1 week, cheap, unblocks everything), **then reach & engine** (measurable accuracy, multilingual on-device, gated WhisperKit fallback), **then ecosystem & AI depth** (local MCP server + Command/Transform Mode), **then hardening** (CI, stress, preflight).

Two cross-area collisions resolve cleanly:
- **One alternate engine, not two.** Speech wanted whisper.cpp (multilingual/benchmark); Platform wanted a way to run below macOS 26. Both collapse into **one `WhisperKit` engine behind one `TranscriptionEngine` protocol** — CoreML/ANE-accelerated, native Swift, serving *both* jobs. It stays **gated** behind the WER benchmark: it ships only if Apple proves materially weaker on real audio, or sub-26 support becomes a hard requirement.
- **One entitlements/notarization pipeline.** Platform owns the *mechanics* (codesign/notarytool/Sparkle nested signing); Security owns the *contents* (exactly `device.audio-input` + `automation.apple-events`, no sandbox, no `cs.*` exceptions, library-validation ON).

---

## The scoreboard this addresses

| Area | Now | Target lever |
|---|---|---|
| Speech / Transcription | 6.0 | Measure it (WER harness) → multilingual (Apple, zero deps) → gated WhisperKit |
| Platform & Distribution | 2.2 | Notarize + hardened runtime + Sparkle + iCloud sync + lower OS floor to 14.4 |
| Extensibility & Ecosystem | 4.6 | Local zero-dep MCP server + URL scheme + Obsidian contract |
| Security & Distribution Trust | 7.8 | CryptoKit at-rest encryption + notarization + entitlement hygiene |
| Feature Depth & AI | 7.8 | Command/Transform Mode (the Wispr-gap closer) + per-app styles + meeting templates |
| Reliability & Engineering | 7.7 | CI on macOS-26 runner + extracted hot-path tests + soak/churn stress + preflight |

---

## Decisions locked (2026-07-06)

| # | Decision | Locked answer | Effect on the plan |
|---|---|---|---|
| D1 | Apple Developer Program | **Keep options open** | Build entitlements + hardened-runtime signing + notarize *scaffolding* now (no runtime deps, no $99 needed). **Hold** the Sparkle dependency + EdDSA + appcast until distribution is committed. Flip to Developer ID whenever you enroll. |
| D2 | Sub-macOS-26 support | **Let the benchmark decide** | Floor **stays macOS 26**; Apple stays the sole engine. `TranscriptionEngine` protocol lands as clean decoupling. WhisperKit built **only if** the WER harness proves Apple materially weaker. |
| D3 | Locales | **English-only for now** | De-hardcode the locale (cheap, future-proofs), but **drop** the language-picker UI + multilingual model-install + multilingual corpus. WER corpus = English dictation/meeting/accent variety. |
| D4 | Appcast host | Deferred (tied to D1) | Decide when distribution is committed. Default: self-controlled domain. |
| D5 | Encryption scope | **DB-only** | CryptoKit AES-GCM on the SQLite history columns. Notes/audio stay plain files (Ask keeps working), documented as a FileVault-covered gap. |

**Net effect:** Phase 1 becomes an encryption + hardening + notarization-*ready* bundle (no external blockers). Phase 2 shrinks to the WER harness + locale-parameterization + formatting polish + protocol extraction; the language UI and WhisperKit are deferred/gated. Phases 3–4 unchanged.

---

## Phase 1 — Ship-ready trust
*Make the app distributable and safe: notarized/stapled, auto-updating, encrypted at rest, cross-device note sync. Almost all S-effort, no interdependencies, and everything downstream presupposes a signed binary.*

| Unit | Area | Effort | Impact |
|---|---|---|---|
| Entitlements file + hardened-runtime signing (Platform mechanics + Security contents, merged) | Platform+Security | S | critical |
| Notarization + stapling pipeline (`notarytool submit --wait` → `stapler staple` → verify; Makefile `release`) | Platform | S | critical |
| HistoryStore column encryption — CryptoKit AES-256-GCM on `raw`/`cleaned`, key in Keychain (ThisDeviceOnly), off the paste hot path | Security | M | high |
| iCloud Drive notes-folder sync (verify + document; point `notesFolder` at iCloud/Obsidian — zero code) | Platform | S | medium |
| Sparkle SPM integration + updater wiring (inside-out nested signing, never `--deep`) | Platform | M | high |
| EdDSA keys + appcast generation + hosting (**back up the private key — losing it means no installed build ever gets a trusted update again**) | Platform | S | high |
| Quick security hardening bundle (`PRAGMA secure_delete=ON` + VACUUM after `deleteAll`; `--allowedTools Read,Grep,Glob` on `summarize()`/`meetingTitle()`; `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` on the API key) | Security | S | medium |
| App Sandbox incompatibility + posture record (README: sandbox out, hardened runtime in, compensating controls) | Security | S | low |

**Why the CryptoKit choice is here, not in isolation:** SQLCipher's binary xcframework would force either re-signing at bundle time or `com.apple.security.cs.disable-library-validation` — exactly the privilege least-privilege exists to avoid. CryptoKit app-layer AES-GCM is the *only* encryption choice that lets the notarized build keep library-validation ON with zero `cs.*` exceptions. SQLCipher stays a documented upgrade path only if ciphertext column-search ever becomes a hard requirement.

---

## Phase 2 — Reach & engine
*Measurable quality first, then multilingual on-device (zero new deps, confirmed API), then the gated WhisperKit engine that both lowers the OS floor and provides the benchmark baseline.*

| Unit | Area | Effort | Impact |
|---|---|---|---|
| **WER benchmark harness** (`ProbeRunner --probe-wer`) — pure token-Levenshtein WER/CER over a labeled clip set through the real Transcriber path. **KEYSTONE / gate.** | Speech | M | critical |
| De-hardcode `Locale` into a resolved language setting (replace 3 `en_US` sites in Transcriber.swift; fix the static `preferredFormat` cache to be locale-keyed) | Speech | M | high |
| On-device model install + language picker UI (from `supportedLocales`, install via `AssetInventory` with progress + reservation management) | Speech | L | high |
| Locale-aware deterministic formatting polish (make CleanupEngine capitalization Unicode-aware — `Character.isLowercase` not `isASCII` — so non-English output stops silently skipping) | Speech | M | medium |
| `TranscriptionEngine` protocol + macOS 14.4 availability gating (ONE sweep gating all `SpeechAnalyzer`/`AssetInventory` refs `@available(macOS 26,*)`; lower `Package.swift` + `LSMinimumSystemVersion` to 14.4) | Platform (absorbs Speech's protocol unit) | M | high |
| WhisperKit alternate engine — **GATED** (ships only if WER proves Apple materially weaker OR sub-26 becomes a hard need). Native Swift/CoreML/ANE, no Python. Per-engine echo-guard thresholds. | Speech+Platform (merged) | L | medium |

**Sequencing rule:** do the Apple-only multilingual work *first* (while the floor is still 26), then gate the *finished* surface once. Gating a moving target is the failure mode. WhisperKit is built *after* the harness measures Apple's real-audio WER — building it first would be adding a tens-to-hundreds-MB CoreML dependency on a hunch.

---

## Phase 3 — Ecosystem & AI depth
*Close the competitive gaps: a local zero-dep MCP server exposing the corpus to Claude, a URL-scheme automation trigger, and Command/Transform Mode as the flagship Wispr-gap closer. All native, single-egress, dictation hot-path untouched.*

| Unit | Area | Effort | Impact |
|---|---|---|---|
| MCP stdio core — hand-rolled JSON-RPC, **no SDK** (~250 lines Foundation, `--mcp` subcommand; the official Swift SDK drags in swift-nio/system/log and detonates zero-dep) | Ecosystem | M | critical |
| Corpus read handlers + headless store access (read notes path from settings JSON directly; factor `listMeetings` nonisolated; `get_note` needs a path-traversal guard) | Ecosystem | M | critical |
| MCP tool schemas — `search_dictations`/`list_meetings`/`get_note` read-only (**`ask` tool DEFERRED**) | Ecosystem | S | high |
| MCP tests + setup docs (Claude Desktop/Code config snippet + `claude mcp add` line) | Ecosystem | S | high |
| URL scheme trigger `radiooperator://` (CFBundleURLTypes + `kAEGetURL` → existing controllers; Shortcuts-callable via "Open URLs" today; App Intents deferred) | Ecosystem | S | medium |
| `ClaudeService.transform(selection:instruction:appContext:)` — DATA-framed prompt + fence stripper, reuses `run()` so CLI/API + injection guard inherited | Feature Depth | S | high |
| `SelectionReader` — AX `kAXSelectedText` first (no clipboard touch), Cmd-C copy-capture fallback for Electron; empty selection → insert-at-cursor | Feature Depth | M | high |
| `CommandHotkey` — separate configurable hold-hotkey (default Fn), **not** a double-tap (collides with hands-free lock) | Feature Depth | S | high |
| **`CommandController`** — parallel controller, **never** a branch in DictationController (proves dictation gains zero latency). hold→capture selection→transcribe instruction→transform→paste→undo. Refuses to start mid-dictation/meeting. | Feature Depth | L | critical |
| Undo/preview affordance (direct-apply for Wispr speed; one native ⌘Z reverses; 4s "⌘Z to undo" chip reusing the pill) | Feature Depth | S | medium |

---

## Phase 4 — Hardening, intelligence depth & honesty-on-any-Mac
*Turn "works on the maintainer's Mac" into "proven on any Mac": CI that gates merges, extracted hot-path tests, soak/churn stress, first-run preflight, local-only diagnostics, plus lower-priority AI-depth polish.*

| Unit | Area | Effort | Impact |
|---|---|---|---|
| Split test tiers (`--core-only` vs `--device`) + `--tests-json` + macOS-26 CI workflow (core tier on every PR — proves it builds on a non-dev machine) | Reliability | S×2 | high |
| PasteService precheck + DictationController edge-transition tests (extract paste-precondition + finalize outcomes to pure statics — highest-consequence untested branch; a wrong decision silently loses dictated text) | Reliability | S–M | high |
| MicCapture + ClaudeService pure-logic tests (format conversion 48k→16k/zero-length/full-scale; prompt-injection case; `cliCandidates` ordering — the no-Claude-installed path strangers hit) | Reliability | S×2 | medium |
| ProbeRunner soak + churn + tap-cycle stress modes (catch SystemAudioTap/MicCapture teardown leaks; sample 3–5× before declaring a leak) | Reliability | M | high |
| First-run robustness preflight (turn silent assumptions — model present, permissions, Claude CLI on PATH — into explicit degradable onboarding states) | Reliability | M | high |
| Local-only opt-in diagnostics export (`OSLogStore` → redacted user-reviewed file, manual share, **no telemetry SDK**; grep-audit that dictation text never reaches os_log) | Reliability | M | medium |
| Panic / secure-delete (cryptographic-erase via deleting the Keychain data key; confirmation-gated; depends on Phase-1 column encryption) | Security | S | high |
| Concealed-pasteboard + secure-input regression locks + entitlement-hygiene assertion | Security | S | medium |
| Meeting templates + `## Follow-ups` extraction (generalize the single `summaryTemplate` into named per-type templates; migrate legacy field into `templates[0]`) | Feature Depth | M+S | medium |
| Per-app writing styles (`AppRule` keyed on the already-recorded `app_bundle_id`; resolved only for Command Mode + opt-in summaries, **never** dictation) | Feature Depth | M | medium |
| Command Mode tests (transformPrompt DATA-framing, fence stripper, SelectionReader path-decision, template migration) | Feature Depth | S | high |

---

## Critical tensions and how they resolved

1. **Two alternate engines proposed → collapse to one.** WhisperKit behind one `TranscriptionEngine` protocol serves both the multilingual/benchmark job and the sub-26 fallback. Drop raw whisper.cpp. Engine stays gated behind the WER harness.
2. **Two authors of the entitlements file → one pipeline, split ownership.** Platform = mechanics, Security = minimal contents. Verified: CGEvent/Accessibility/Core-Audio-tap gate on TCC, *not* hardened-runtime entitlements — that's what keeps the file minimal.
3. **Encryption choice governs the entitlement set.** CryptoKit AES-GCM is mandatory because it's the only choice that keeps library-validation ON with zero `cs.*` exceptions.
4. **Sparkle adds a second network egress.** Restate the claim precisely: "single egress *for content*; update checks are separate, EdDSA-signed, to a self-controlled host." The appcast signature is an *added* integrity layer. (MCP server = zero egress — stays a clean claim.)
5. **WER harness is a cross-area gate, not one Speech unit.** Promoted ahead of both the multilingual UI and WhisperKit. No engine bet before the number exists.
6. **Command Mode + MCP both add LLM entry points.** Command Mode = parallel controller (never a DictationController branch). MCP `ask` tool = deferred (a client that has search/get/list doesn't need a nested ask). Both reuse `ClaudeService` so single-egress + injection-guard are preserved by construction.
7. **Availability-gating a moving target.** Land Apple-only multilingual first (floor still 26), then gate the finished surface once.

---

## Decisions for the owner (with recommendations)

| # | Decision | Recommendation |
|---|---|---|
| D1 | **Apple Developer Program ($99/yr)** — gates the entire Phase-1 critical path (Developer ID, notarization, Sparkle, trustworthy MCP binary). | **Confirm/buy now.** Nothing distributable ships without it. Hard blocker. |
| D2 | **Is running below macOS 26 a real user need?** Decides whether WhisperKit (the largest dependency in the program) is built at all. | If your fleet is all on 26: **keep the floor at 26**, land the `TranscriptionEngine` protocol as decoupling-only, skip WhisperKit until proven. |
| D3 | **Which non-English locales matter?** Scopes the reservation cap + the WER corpus. | Name a real target list (e.g., es, fr, de, pt) — not "all supported." Needed before Phase 2 sizing. |
| D4 | **Appcast host** — GitHub Releases vs self-controlled domain. Shapes `SUFeedURL` + the single-egress narrative. | **Self-controlled domain** if you want the cleanest "updates to a host I control" story; GitHub Releases if you want zero ops. |
| D5 | **Encrypt the `~/Documents` notes/audio too, or DB-only?** Encrypting notes breaks the Claude CLI Ask path (it Greps plaintext) and the "files you own" property. | **DB-only encryption.** Document the notes/audio plaintext surface as an accepted, FileVault-covered gap. Biggest residual, but encrypting it costs the Ask feature. |
| D6 | **Command Mode v1 scope** — (a) require selection or also empty-selection insert; (b) single-modifier or two-modifier chord; (c) allow in terminals/secure-input? | (a) support both; (b) single-modifier default (Fn), chord later; (c) **refuse in secure-input/terminals** (rewriting a shell command is dangerous). |
| D7 | **MCP posture** — read-only vs read-write; expose `ask`? | **Read-only (search/get/list), defer `ask`.** Preserves the strongest zero-side-effect, zero-egress safety story. |
| D8 | **Panic-wipe scope** — app-private DB+Keychain only, or also user notes/audio? | Default to **DB+Keychain (cryptographic-erase)**; offer notes/audio as an explicit second checkbox. |
| D9 | **Soak-probe leak threshold.** | Fail only on **>50% RSS growth after warm-up, sampled 3–5×** (per the flapping-monitor lesson). |
| D10 | **Self-hosted Mac CI runner for the device test tier?** | **Keep device tier a manual pre-release checklist** until a second maintainer exists; core tier runs on hosted macOS-26. |

---

## Biggest risks

- **Sparkle nested-binary signing is fragile** — wrong inside-out order or a stray `--deep` silently breaks XPC signatures and notarization fails. Most error-prone unit in Phase 1; verify with `spctl` on the first signed build.
- **Losing the EdDSA private key is unrecoverable** — installs only trust the baked-in `SUPublicEDKey`. Back it up to an encrypted store. Operationally critical.
- **Building WhisperKit before the WER harness proves need** = largest erosion of the zero-dep property, on a hunch. The gate must hold.
- **The 14.4 availability sweep must cover every SpeechAnalyzer ref including the new multilingual ones** — one ungated reference breaks the 14.4 build. Do multilingual first, gate the finished surface once.
- **Command Mode leaking latency into the dictation hot path** if implemented as a branch instead of a parallel controller — silently regresses the highest-scoring property. Enforce structural separation in review.
- **Diagnostics-export privacy is load-bearing and fragile** — if any path logs dictation/meeting text via os_log/NSLog/print, the export leaks content. Add a grep-audit now and a CI grep-guard.
- **`~/Documents` notes + `.m4a` audio stay plaintext after DB encryption** — largest residual at-rest surface, consumed in plaintext by the Claude CLI in Ask mode. Accepted, documented gap (see D5).

---

## Completeness gaps the plan itself flagged (address before/during build)

- **No unified migration/versioning story** across the encryption + settings additions (encrypted BLOB columns; `transcriptionLanguage`/`commandHotkey`/`appRules`/`summaryTemplates`). Add a single schema-version + settings-migration test that proves an old settings file and old DB survive every phase in sequence.
- **No Sparkle rollback/downgrade story** if a bad release ships. Add a minimum-system-version / phased-rollout plan.
- **The WER corpus is undefined** — how many clips, which accents/locales, who labels them, where they live. The harness is only as good as the corpus. Propose a default 20–40 clip in-repo set.
- **No cross-process concurrency model** when the GUI app + `--mcp` subprocess + a Command Mode transform all hit the same HistoryStore/notes folder (SQLite busy-timeout/WAL; iCloud materialization lag across Macs).
- **App's own UI stays English-only** while transcription goes multilingual — an unflagged inconsistency in the "reach" story.
- **No accessibility (VoiceOver/keyboard) pass** on the new config UIs — ironic for an app built on the Accessibility API.
- **Panic-wipe ↔ MCP interaction undefined** if the MCP subprocess is mid-read when the DB + Keychain key are deleted.
- **No spend visibility/cap** for the new API-mode LLM entry points (Command Mode transform, summaries).
- **No clean-uninstall story** (Keychain items + app-private data + iCloud residue).

---

## Fastest visible wins (ship in days, order-independent within Phase 1–2)

1. Entitlements file + hardened-runtime signing → unblocks the whole distribution path.
2. `notarize.sh` + Makefile `release` → every release Gatekeeper-clean offline.
3. Point `notesFolder` at iCloud Drive + a Settings hint → cross-device sync, zero code.
4. `PRAGMA secure_delete=ON` + VACUUM after `deleteAll` → "Clear history" actually overwrites freed bytes.
5. `--allowedTools Read,Grep,Glob` on summary subprocesses → stop inheriting Write/Bash/WebFetch.
6. `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` on the API key → never iCloud-syncs.
7. De-hardcode the 3 `en_US` sites + locale-keyed `preferredFormat` cache → parameterizes the engine before any UI.
8. `WordErrorRate` pure-Swift unit + 4–6 known-answer cases → the scoring core, offline-testable.
9. URL scheme trigger → immediately Shortcuts-callable.
10. `ClaudeService.transform()` → unblocks all of Command Mode.
11. `## Follow-ups` in the default summary template → instant meeting-intelligence depth.
12. `--core-only` test tier + GitHub Actions macOS-26 workflow → CI merge gate.

---

*Generated from a 7-agent research + synthesis pass (each area verified against current Apple/Sparkle/WhisperKit/MCP docs). Full per-area decision detail retained in the workflow transcript.*
