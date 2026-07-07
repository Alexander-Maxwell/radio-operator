.PHONY: build test test-core test-json probe probe-ask probe-wer eval eval-quick eval-baseline app run install release clean reset-tcc

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

# Quality scorecard over the golden meeting set (spec: eval/ + the V4 vault's
# eval-harness spec). Golden data is private and lives OUTSIDE this repo:
# set GOLDEN_DIR. Exit codes: 0 pass, 1 regression, 2 hard gate, 3 infra,
# 4 integrity/anti-circularity.
EVAL_OVERRIDES = $(if $(SUBSET),--subset "$(SUBSET)") $(if $(REPORT_DIR),--report-dir "$(REPORT_DIR)")

eval: build
	.build/debug/RadioOperator --eval "$${GOLDEN_DIR:?set GOLDEN_DIR to the private golden-set directory}" $(EVAL_OVERRIDES) $(EVAL_FLAGS)

# Diagnostic run with unverified (draft) references: numbers print, nothing is
# gradeable, the baseline is never written or compared (the binary refuses).
eval-quick: build
	.build/debug/RadioOperator --eval "$${GOLDEN_DIR:?set GOLDEN_DIR}" --allow-draft-references $(EVAL_OVERRIDES) $(EVAL_FLAGS)

# Ratchet: full eval then commit the new baseline in the SAME PR (spec 5.3).
eval-baseline: build
	.build/debug/RadioOperator --eval "$${GOLDEN_DIR:?set GOLDEN_DIR}" --write-baseline $(EVAL_OVERRIDES) $(EVAL_FLAGS)

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
