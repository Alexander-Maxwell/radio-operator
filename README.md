# Radio Operator

**Speak anywhere. Capture every meeting. Nothing leaves this Mac.**

Radio Operator is a native macOS menu-bar app that replaces Wispr Flow (dictation) and
Granola (meeting notes) with one local-first, Claude-powered tool:

- **Dictation** — hold Right-⌘ anywhere, speak, release: your words stream live
  in a floating pill (Apple's on-device SpeechAnalyzer — works in airplane mode,
  zero model downloads) and land at your cursor, cleaned deterministically
  (fillers, personal dictionary, snippets) with **no LLM latency in the hot path**.
- **Meetings** — one click captures your mic ("Me") *and* system audio ("Them",
  via a Core Audio process tap — no bot joins your call, works with Zoom, Meet,
  Teams, FaceTime, and in-person). Live transcript, crash-safe (the note is on
  disk from minute zero), and the moment you hit stop, **Claude writes the
  summary, decisions, and action items automatically**.
- **Ask Radio Operator** — chat over everything you've dictated and every meeting
  you've captured, with file citations. Uses your existing Claude Code
  subscription via the `claude` CLI — **no API key, no account, no telemetry**.
  (Optional: add an Anthropic API key in Settings for lower latency.)
- **Your data is files** — meetings are plain markdown with YAML frontmatter in
  `~/Documents/Radio Operator` (point it at your Obsidian vault in Settings).
  Optional local audio retention (off by default).

## Build & install

Requires macOS 26+, Apple Silicon, and Xcode Command Line Tools (no Xcode).

```bash
cd radio-operator
make test      # unit tests (cleanup engine, transcript assembler, notes store)
make install   # build, bundle, sign, copy to /Applications
open /Applications/Radio Operator.app
```

## First run — permissions

Onboarding walks you through these; all are one-time grants:

| Permission | Why | When |
|---|---|---|
| Microphone | hear you | first dictation |
| Accessibility | paste at your cursor | onboarding |
| Input Monitoring | see your hold-to-talk key | onboarding |
| System Audio Recording | hear the other side of meetings | first meeting |

If dictation stops responding right after granting, relaunch the app
(onboarding offers a button). `make reset-tcc` clears stale grants after
rebuilds.

### Signing, hardened runtime, and (optional) notarization

Every build signs with the **hardened runtime** and the minimal entitlements in
`resources/RadioOperator.entitlements` (exactly `device.audio-input` +
`automation.apple-events` — the paste, event-tap, and process-tap machinery is
gated by TCC, not entitlements, so nothing else is needed). `bundle.sh` asserts
this stays true and fails the build on any unexpected entitlement.

Identity preference: **Developer ID Application** (if enrolled) → the stable
self-signed **"Radio Operator Dev"** certificate (keeps TCC grants across
rebuilds; trust it once via `security add-trusted-cert`) → ad-hoc.

To distribute Gatekeeper-clean builds to other people, enroll in the Apple
Developer Program, then:

```bash
make release   # bundle → notarytool submit → staple → verify
```

Without a Developer ID identity, `make release` explains and exits cleanly.

### Why no App Sandbox

The sandbox blocks the app's core mechanics: posting synthetic ⌘V (CGEvent),
the recording-scoped key tap, activating the target app, and the Core Audio
process tap. Compensating controls: hardened runtime ON, least-privilege
entitlements (asserted at build), on-device speech, single network egress
(opt-in API mode only), history encrypted at rest, keys in Keychain.

## Data at rest

- **Dictation history** (`history.sqlite`) is **AES-256-GCM encrypted** per
  column; the key lives in the login Keychain, device-only. Deleting the key is
  a cryptographic erase. `PRAGMA secure_delete` is on, and Clear History
  VACUUMs, so cleared rows aren't recoverable from the file.
- **Meeting notes and dictation logs** in `~/Documents/Radio Operator` are
  **plain markdown by design** — they're yours, they're Obsidian-compatible,
  and Ask's CLI mode greps them directly. FileVault covers them at rest.
  (Deliberate trade-off; see docs/plans/uplift-plan.md, decision D5.)

## Sync across Macs

The notes folder is repointable (Settings → General). Point it at a folder in
iCloud Drive — or your Obsidian vault synced by any means — and meetings +
dictation logs sync across machines with zero configuration. The dictation
history database and settings stay local to each Mac.

## Probes

Headless checks that need no permissions:

```bash
.build/debug/RadioOperator --run-tests                      # unit tests
.build/debug/RadioOperator --probe-transcribe test.aiff     # full STT pipeline on a file
.build/debug/RadioOperator --probe-wer clips/manifest.json  # accuracy benchmark (WER/CER)
```

The WER manifest is a JSON array of labeled clips — the reproducible number
that gates every transcription-engine decision:

```json
[{ "audio": "clip-01.aiff", "reference": "exactly what was said", "locale": "en_US" }]
```

## Architecture (one paragraph)

Single Swift process, no sidecars. Dictation: NSEvent flagsChanged hold-to-talk
→ mic broadcaster (one AVAudioEngine tap, N subscribers) → SpeechAnalyzer
streaming session (volatile results → pill, finals → deterministic
CleanupEngine) → clipboard-swap paste with preconditions (secure-input check,
frontmost verification, guarded restore). Meetings: mic + Core Audio process
tap → two SpeechAnalyzer sessions → TranscriptAssembler (ordered Me/Them
merge, optional echo guard auto-enabled on speakers) → incrementally persisted
markdown note → `claude` CLI summary on stop with a per-note in-flight
registry. History in SQLite; settings in JSON; API key (optional) in Keychain.
