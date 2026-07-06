.PHONY: build test probe probe-ask probe-wer app run install release clean reset-tcc

build:
	swift build

test: build
	.build/debug/RadioOperator --run-tests

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
