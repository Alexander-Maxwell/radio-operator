# Device-tier checklist (manual, pre-release)

Per D10 there is no self-hosted CI runner: everything CI cannot prove on a
hosted image — real hardware, TCC grants, a signed-in Claude CLI, live
speech models — is verified by hand on a real Mac before any release or
before merging a change that touches audio, paste, meetings, or the Claude
bridge. CI's core tier (`.github/workflows/ci.yml`) covers build + the
deterministic offline suites; this list covers the rest.

Run everything from the repo root on the target Mac. Build first:

```
swift build
make test        # full in-binary tier — must print ALL TESTS PASSED
```

Record results in the PR/release notes: date, macOS build, hardware, and a
check per line.

## 1. Probes (headless, `.build/debug/RadioOperator …`)

| # | Probe | Command | Pass criteria |
|---|---|---|---|
| 1.1 | Transcribe | `--probe-transcribe <clip.wav>` | Events stream, finals match the clip's speech, exit 0. Proves the SpeechAnalyzer contract + model presence on this OS build. |
| 1.2 | Dual session | `--probe-dual <clip1.wav> <clip2.wav>` | Both files transcribe concurrently (meeting-mode shape: two analyzer sessions), no starvation or crash, exit 0. |
| 1.3 | Mics | `--probe-mics` | Every physically attached input device is listed with UID + channels; default matches System Settings. |
| 1.4 | Ask | `--probe-ask` (`make probe-ask`) | Round-trip answer cites the seeded note. Needs this Mac's Claude CLI auth — this is the check that the CLI discovery + auth path works off the dev machine. |
| 1.5 | WER | `--probe-wer <manifest.json>` | WER/CER prints for the labeled clip set and stays within the accepted baseline for the release. Gate number for any engine decision (D2). |
| 1.6 | Churn | `--probe-churn 40` | 3–5 RSS samples print after the warm-up cycles, then `PROBE-RESULT PASS`. FAIL fires only when growth vs the post-warm-up baseline exceeds 50% on EVERY sample (D9) — judge flapping from the printed samples, never one reading. Exercises MicCapture subscribe/feed/unsubscribe + Transcriber start/cancel teardown. |
| 1.7 | Soak | `--probe-soak 300` | Same D9 verdict over one held mic subscription + live transcriber session. RSS plateau expected; growth >50% on every sample = leak. |
| 1.8 | Live capture | `make smoke` (`… --probe-capture 4`) | **The dictation-alive gate.** Subscribes to the real shared mic exactly as dictation does (VPIO off) and asserts non-silent audio arrives (`peak > 0.001`) → `PROBE-RESULT PASS`, exit 0. Prints `fmt`/`peak`/`rms`; speak during the window to also see a live transcript. Would have caught the 0.3.0 meeting-AEC regression (mic silent, `peak ≈ 0` → FAIL). **Must run from the INSTALLED, signed app** (the mic TCC grant follows the signature; the debug build has none) — so `make install` first. |

## 2. Paste smoke (needs Accessibility + Input Monitoring TCC)

> Precondition: `make smoke` (probe 1.8) prints `PROBE-RESULT PASS` first. If
> the live mic is silent, every check below fails for one upstream reason and a
> broken-dictation build is caught here deterministically — not by eyeballing a
> paste that silently never happens (how 0.3.0 shipped).

- [ ] Hold hotkey, dictate a sentence into TextEdit → text pastes at cursor,
      pill dismisses, clipboard restored to prior contents after ~2s.
- [ ] Same into a Chromium app (Chrome/Slack) → paste lands, no focus loss.
- [ ] Dictate with a password field focused (secure input) → NO paste; pill
      shows "Secure input active — press ⌘V to paste"; text on clipboard.
- [ ] Quit the target app mid-dictation → clipboard-only outcome with the
      "app closed" reason, nothing pasted elsewhere.
- [ ] Clipboard manager check: dictated text does NOT appear in clipboard
      history (concealed-type marker honored).
- [ ] Double-tap lock: two quick presses → hands-free recording; single
      press ends and pastes.
- [ ] Sub-120ms tap → silent discard, no pill error, nothing pasted.

## 3. Meeting smoke (needs mic + system-audio TCC, real call audio)

- [ ] Start a meeting (menu or auto-start on mic activity) while playing
      far-end audio → note file appears with Me/Them utterances interleaved.
- [ ] Stop → summary generates, note retitled from Claude's title, audio
      files land next to the note, frontmatter `summary: done`.
- [ ] Dictate DURING the meeting → dictation pastes normally and the meeting
      transcript keeps flowing (broadcaster fan-out intact).
- [ ] Pull AirPods (or switch input) mid-meeting → capture recovers on the
      new route, no dead transcript.
- [ ] Degraded path: deny system-audio tap → meeting still records mic-only
      and the note carries the microphone-only banner.

## 4. Command Mode smoke (D6)

- [ ] Select text in TextEdit, hold Fn, speak an instruction → selection
      replaced; one ⌘Z restores the original.
- [ ] Empty selection → spoken instruction inserts at cursor.
- [ ] In Terminal and in a password field → Command Mode REFUSES (no
      transform, clear notice), per D6.
- [ ] Command Mode during active dictation → refuses to start; dictation
      unaffected.

## 5. MCP smoke (read-only, D7)

- [ ] `claude mcp add` per docs, then from Claude: `search_dictations`,
      `list_meetings`, `get_note` each return real corpus data.
- [ ] With the login Keychain unavailable (fast user switch / locked), MCP
      calls return a JSON-RPC error — no crash, no plaintext fallback.

## 6. Cold-start honesty

- [ ] Fresh macOS user account: app launches, asks for permissions in a sane
      order, and every missing grant degrades with a visible explanation —
      no silent dead features (mic, Accessibility, Input Monitoring, system
      audio, Claude CLI absent).
- [ ] Old `settings.json` from the previous release loads without loss
      (resilient decoding), hotkeys still registered.
