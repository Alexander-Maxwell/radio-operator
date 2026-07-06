#!/bin/bash
# Log-hygiene audit: fail if any logging call in Sources/ can leak dictation,
# transcript, or selection CONTENT into os_log/NSLog/stdout. Metadata (status
# codes, device names, file paths, durations) is fine; the words the user
# spoke are not — the local-only diagnostics export reads os_log, so one
# content-bearing log line turns the export into a transcript leak.
#
# Two-stage grep, portable across BSD (macOS) and GNU grep:
#   1. find logging call sites (NSLog / os_log / print / os.Logger methods),
#      excluding files whose stdout IS the product (see EXCLUDES);
#   2. flag any of those lines that reference a content-bearing identifier
#      (word-bounded, so "plaintext" does not trip "text").
#
# The fix for a hit is to remove the content from the log line (log lengths
# or hashes instead) — never to weaken this script.
set -euo pipefail
cd "$(dirname "$0")/.."

# Files whose printed output is a deliberate channel, not ambient logging:
#   TestRunner + *TestCases — in-binary test harness verdicts on stdout.
#   ProbeRunner            — user-invoked CLI probes; --probe-transcribe
#                            printing the transcription IS the feature.
#   MCPRunner              — the JSON-RPC stdio protocol channel.
EXCLUDES='^Sources/RadioOperator/(Core/TestRunner\.swift|Core/[A-Za-z]+TestCases\.swift|Core/ProbeRunner\.swift|MCP/MCPRunner\.swift):'

# Identifiers that carry user speech / selection content. Word-bounded when
# matched; compound names are listed explicitly because the boundary check
# (correctly) keeps "cleaned" from matching "cleanedText".
SENSITIVE='raw|rawText|cleaned|cleanedText|text|transcript|transcriptMarkdown|transcriptSnippet|finals|utterance|utterances|pillFinal|pillVolatile|selection|selectedText|instruction|userNotes|prompt|question|summaryMarkdown'

# Non-identifier boundary ([^A-Za-z0-9_] instead of \b: BSD grep -E has no \b).
W='[^A-Za-z0-9_]'

log_sites=$(grep -rnE "(^|${W})(NSLog|os_log|print|logger\.(log|debug|info|error|fault))\(" \
    Sources/ --include='*.swift' 2>/dev/null \
  | grep -vE "${EXCLUDES}" || true)

violations=$(printf '%s\n' "${log_sites}" \
  | grep -E "(^|${W})(${SENSITIVE})(${W}|$)" || true)

if [ -n "${violations}" ]; then
  echo "LOG HYGIENE FAILURE: logging call references dictation/transcript content:" >&2
  printf '%s\n' "${violations}" >&2
  echo "" >&2
  echo "Remove the content from the log line (log lengths/hashes, not words)." >&2
  exit 1
fi

count=$(printf '%s' "${log_sites}" | grep -c . || true)
echo "log hygiene OK: ${count} logging call sites audited, none carry content"
