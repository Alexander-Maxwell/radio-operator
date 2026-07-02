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

### Optional: stable code-signing identity

Builds are ad-hoc signed by default, which resets TCC grants on every rebuild.
For a stable identity, trust the generated "Radio Operator Dev" certificate once
(GUI password prompt):

```bash
security add-trusted-cert -r trustRoot -p codeSign \
  /private/tmp/.../adj_cert.pem   # or re-create: see scripts/bundle.sh
```

`scripts/bundle.sh` automatically prefers the "Radio Operator Dev" identity when it
is valid.

## Probes

Headless checks that need no permissions:

```bash
.build/debug/RadioOperator --run-tests                      # unit tests
.build/debug/RadioOperator --probe-transcribe test.aiff     # full STT pipeline on a file
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
