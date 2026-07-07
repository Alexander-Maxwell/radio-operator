.PHONY: build test test-core test-json probe probe-ask probe-wer smoke app run install release clean reset-tcc

build:
	swift build

test: build
	.build/debug/RadioOperator --run-tests

# CI merge gate (D10): deterministic/offline suites only — no hardware, TCC,
# or network. Identical to `test` until a device-tier suite exists.
test-core: build
	.build/debug/RadioOperator --run-tests --core-only

# Core tier plus machine-readable results at build/test-results.json
# ({passed, failures, suites}).
test-json: build
	@mkdir -p build
	.build/debug/RadioOperator --run-tests --core-only --tests-json build/test-results.json

probe: build
	@echo "usage: .build/debug/RadioOperator --probe-transcribe <audiofile>"

# End-to-end Ask round-trip against a seeded note. Needs this session's Claude
# auth (subscription or API key); not part of `make test`.
probe-ask: build
	.build/debug/RadioOperator --probe-ask

# Accuracy benchmark over a labeled clip set (JSON manifest of
# {audio, reference, locale?}). The number that gates engine decisions.
probe-wer: build
	@echo "usage: .build/debug/RadioOperator --probe-wer <manifest.json>"

app:
	bash scripts/bundle.sh

run: app
	open "build/Radio Operator.app"

install: app
	rm -rf "/Applications/Radio Operator.app"
	cp -R "build/Radio Operator.app" "/Applications/Radio Operator.app"
	@echo "Installed /Applications/Radio Operator.app"
	@echo "→ run 'make smoke' to verify the live dictation mic path (must print PROBE-RESULT PASS)."

# Live-mic smoke gate: asserts the dictation path actually receives non-silent
# audio (peak > 0). The check that would have caught the 0.3.0 meeting-AEC
# regression, where the shared mic went silent for dictation but every unit
# test stayed green (none touch the live engine). Runs the INSTALLED, signed
# binary because it needs the Microphone TCC grant — the debug build is ad-hoc
# signed and has none. Run `make install` first. Ambient noise passes it; speak
# a sentence to also confirm transcription end to end.
smoke:
	"/Applications/Radio Operator.app/Contents/MacOS/RadioOperator" --probe-capture 4

# Distribution build: bundle, then notarize + staple (no-ops with guidance
# until a Developer ID identity exists — see scripts/notarize.sh).
release: app
	bash scripts/notarize.sh

# Recovery: clear stale TCC grants after a re-signed rebuild stops responding.
reset-tcc:
	tccutil reset Microphone com.warroom.radiooperator || true
	tccutil reset Accessibility com.warroom.radiooperator || true
	tccutil reset ListenEvent com.warroom.radiooperator || true
	tccutil reset AudioCapture com.warroom.radiooperator || true

clean:
	rm -rf .build build
