# Session Q&A Log: Radio Operator Six-Area Uplift Plan

**Date:** 2026-07-06
**Mode:** New Feature (existing Swift codebase)
**Scope:** Deep
**Phases completed:** 0 (Intake/Route), 1 (Ground — pre-done via full source review), 2 (Challenge — compressed per owner signal), 3/4 (Define + Structure — roadmap produced)
**Outcome:** Full sequenced, dependency-aware uplift plan produced (`docs/plans/uplift-plan.md`) + visual roadmap artifact. Awaiting owner decisions D1–D10 to greenlight Phase 1.

---

## Questions & Answers by Phase

### Phase 0/2: Intake & Scope

**Q:** You said "4 main areas" but listed 3 (Speech, Platform & Distribution, Extensibility/Ecosystem). What's the 4th?
**User:** "The above 3 as well" — i.e., also Security & distribution trust, Feature depth & AI, and Reliability & engineering.
**AI position:** Treated the scope as a comprehensive six-area uplift rather than a narrow three.
**Resolved:** Six areas in scope: Speech, Platform & Distribution, Extensibility/Ecosystem, Security & Distribution Trust, Feature Depth & AI, Reliability & Engineering.

**Q:** For Platform & Distribution, is the ambition to fix distribution on Mac, go cross-platform (Win/Linux), or fix-Mac-now-portable-later?
**User:** Stay Mac-native, fix distribution.
**AI position:** Argued this is the highest-ROI path — it preserves the native Swift + Apple-STT core that earns the security/performance wins, which a cross-platform rewrite (e.g. Tauri + whisper.cpp) would sacrifice.
**Resolved:** Keep the native single-process architecture. Add Developer ID notarization, hardened runtime, Sparkle auto-update, iCloud-folder sync, and lower the OS floor. No cross-platform rewrite.

### Phase 2: Premise Pressure-Test (surfaced inline before planning)

**AI position (flagged 3 tensions):**
1. "Drop the macOS-26 floor" conflicts with "keep Apple SpeechAnalyzer" (a 26-only API). Bundling an alternate engine (WhisperKit) solves the floor AND multilingual AND a benchmarkable engine simultaneously — highest-leverage move.
2. Notarization is achievable; full App Sandbox is not (process tap + Accessibility + app activation are sandbox-hostile). Trust win = Developer ID + hardened runtime + notarization.
3. Cross-device sync may be near-free: data is already plain files; point `notesFolder` at an iCloud/Obsidian folder. CloudKit is the heavier path.
**Resolved:** All three carried into the plan. WhisperKit adopted as the single gated alternate engine; App Sandbox documented as out; iCloud-folder sync adopted as the cheap sync path.

---

## Key Decisions

| Decision | Chosen | Phase | Rationale |
|----------|--------|-------|-----------|
| Scope | Six areas (all flagged) | 0 | Owner confirmed "the above 3 as well" |
| Platform strategy | Stay Mac-native, fix distribution | 0 | Preserves the security/perf moat |
| Alternate engine | One WhisperKit behind one `TranscriptionEngine` protocol, gated behind WER | 3 | Serves sub-26 + multilingual-benchmark; avoids duplicate work |
| Encryption | CryptoKit AES-GCM app-layer (not SQLCipher) | 3 | Only choice keeping library-validation ON with zero cs.* exceptions |
| Auto-update | Sparkle 2.x, self-controlled appcast host | 3 | Only native non-App-Store updater; restated single-egress narrative |
| MCP posture | Read-only (search/get/list), `ask` deferred | 3 | Preserves zero-side-effect, zero-egress safety story |
| Command Mode | Parallel `CommandController`, never a DictationController branch | 3 | Proves dictation hot path gains zero latency |
| Sequencing | Trust → Reach/engine → Ecosystem/AI → Hardening | 3 | Front-load cheap high-impact wins; nothing ships without a signed binary |

---

## Positions Where AI Pushed Back

| Topic | AI Position | User Response | Final Resolution |
|-------|------------|---------------|------------------|
| Cross-platform vs Mac-native | Going cross-platform would mean a rewrite off native Swift/Apple-STT, sacrificing the security/perf edge | Chose "stay Mac-native" | Native architecture preserved; distribution fixed in place |
| macOS-26 floor vs Apple STT | Dropping the floor isn't free — it forces a second STT engine (WhisperKit), which then also serves multilingual + benchmarking | (pending — D2) | WhisperKit planned but GATED behind the WER harness + a confirmed sub-26 need |

---

## Gating decisions — LOCKED 2026-07-06

- **D1 Apple Developer Program → keep options open.** Build entitlements + hardened-runtime signing + notarize scaffolding now; hold Sparkle + $99 until distribution is committed.
- **D2 sub-macOS-26 → let the benchmark decide.** Floor stays 26; WhisperKit gated on the WER harness result.
- **D3 locales → English-only for now.** De-hardcode the locale; defer the picker/corpus/multilingual UI.
- **D4 appcast host → deferred** (tied to D1). Default: self-controlled domain.
- **D5 encryption → DB-only.** CryptoKit on the SQLite history; notes/audio stay plaintext (documented).

Still open (not blocking Phase 1): D6 Command Mode v1 scope · D7 MCP read-only vs read-write · D8 panic-wipe scope · D9 soak threshold · D10 self-hosted CI runner. Resolve at their phase.
