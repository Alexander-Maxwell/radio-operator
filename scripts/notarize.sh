#!/bin/bash
# Notarize + staple "build/Radio Operator.app" for Gatekeeper-clean distribution.
#
# Prerequisites (one-time):
#   1. Apple Developer Program membership ($99/yr).
#   2. A "Developer ID Application" certificate installed in the keychain.
#   3. Stored notary credentials:
#        xcrun notarytool store-credentials radio-operator-notary \
#          --apple-id <you@example.com> --team-id <TEAMID> --password <app-specific-pw>
#
# Without a Developer ID identity this script explains and exits cleanly, so
# `make release` is safe to run before enrolling (decision D1: options open).
set -euo pipefail
cd "$(dirname "$0")/.."

APP="build/Radio Operator.app"
PROFILE="${NOTARY_PROFILE:-radio-operator-notary}"
ENTITLEMENTS="resources/RadioOperator.entitlements"

IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
  | grep -o '"Developer ID Application[^"]*"' | head -1 | tr -d '"' || true)"
if [ -z "$IDENTITY" ]; then
  echo "notarize: no 'Developer ID Application' identity found — skipping."
  echo "          The app stays self-signed (fine for this Mac). To distribute:"
  echo "          enroll at developer.apple.com, install the cert, store notary"
  echo "          credentials (see header of this script), then re-run 'make release'."
  exit 0
fi

[ -d "$APP" ] || { echo "notarize: $APP missing — run 'make app' first"; exit 1; }

# Re-sign with the distribution identity: hardened runtime + secure timestamp.
xattr -cr "$APP"   # Finder metadata is "detritus" to codesign --strict
codesign --force --options runtime --timestamp \
  --entitlements "$ENTITLEMENTS" --sign "$IDENTITY" "$APP"

ZIP="build/RadioOperator-notarize.zip"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$APP"

# Prove the result: Gatekeeper accepts it offline.
spctl --assess --type execute -v "$APP"
stapler validate "$APP"
echo "Notarized + stapled: $APP"
