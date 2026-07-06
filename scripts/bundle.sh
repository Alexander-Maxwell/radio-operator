#!/bin/bash
# Builds "Radio Operator.app" from the SPM release binary. No Xcode required.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="0.3.0"
swift build -c release

APP="build/Radio Operator.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/RadioOperator "$APP/Contents/MacOS/RadioOperator"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleExecutable</key>
	<string>RadioOperator</string>
	<key>CFBundleIdentifier</key>
	<string>com.warroom.radiooperator</string>
	<key>CFBundleName</key>
	<string>Radio Operator</string>
	<key>CFBundleDisplayName</key>
	<string>Radio Operator</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>${VERSION}</string>
	<key>CFBundleVersion</key>
	<string>${VERSION}</string>
	<key>LSMinimumSystemVersion</key>
	<string>26.0</string>
	<key>LSUIElement</key>
	<true/>
	<key>NSMicrophoneUsageDescription</key>
	<string>Radio Operator transcribes your speech on-device. Audio never leaves this Mac.</string>
	<key>NSAudioCaptureUsageDescription</key>
	<string>Radio Operator captures meeting audio from other apps so it can transcribe your meetings on-device. Nothing is uploaded.</string>
	<key>NSSpeechRecognitionUsageDescription</key>
	<string>Radio Operator uses Apple's on-device speech recognition to turn your voice into text.</string>
	<key>NSAppleEventsUsageDescription</key>
	<string>Radio Operator activates the app you were using so it can paste your dictated text at the cursor.</string>
	<key>NSHumanReadableCopyright</key>
	<string>© 2026 War Room</string>
</dict>
</plist>
PLIST

if [ -f resources/RadioOperator.icns ]; then
  cp resources/RadioOperator.icns "$APP/Contents/Resources/"
  /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string RadioOperator" "$APP/Contents/Info.plist" 2>/dev/null || true
fi

# Sign with the hardened runtime + least-privilege entitlements everywhere,
# so the dev build exercises the exact runtime posture a notarized release
# ships with. Identity preference: Developer ID (distribution) → stable
# self-signed "Radio Operator Dev" (keeps TCC grants across rebuilds) → ad-hoc.
ENTITLEMENTS="resources/RadioOperator.entitlements"
IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | grep -o '"Developer ID Application[^"]*"' | head -1 | tr -d '"' || true)"
if [ -z "$IDENTITY" ]; then
  IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | grep -o '"Radio Operator Dev[^"]*"' | head -1 | tr -d '"' || true)"
fi
if [ -n "$IDENTITY" ]; then
  case "$IDENTITY" in
    "Developer ID Application"*) TIMESTAMP="--timestamp" ;;
    *)                           TIMESTAMP="" ;;  # timestamp service rejects self-signed certs
  esac
  codesign --force --options runtime $TIMESTAMP --entitlements "$ENTITLEMENTS" --sign "$IDENTITY" "$APP"
else
  codesign --force --options runtime --entitlements "$ENTITLEMENTS" --sign - "$APP"
fi

# Hygiene assertion: the shipped binary carries exactly the two expected
# entitlements — a stray addition fails the build here, not in a review.
GRANTED="$(codesign -d --entitlements - --xml "$APP" 2>/dev/null | plutil -convert json -o - - 2>/dev/null || echo '{}')"
for KEY in com.apple.security.device.audio-input com.apple.security.automation.apple-events; do
  echo "$GRANTED" | grep -q "$KEY" || { echo "ENTITLEMENT MISSING: $KEY"; exit 1; }
done
UNEXPECTED="$(echo "$GRANTED" | tr '{},' '\n' | grep -o '"com\.apple\.security\.[^"]*"' \
  | grep -v 'device\.audio-input' | grep -v 'automation\.apple-events' || true)"
if [ -n "$UNEXPECTED" ]; then
  echo "UNEXPECTED ENTITLEMENTS: $UNEXPECTED"; exit 1
fi

echo "Built $APP (signed: ${IDENTITY:-ad-hoc}, hardened runtime on)"
