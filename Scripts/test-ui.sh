#!/bin/bash
# Runs the XCUIAutomation suite. Needs an idle machine: the tests type into the app.
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
export AIRMARK_DERIVED_DATA="${AIRMARK_DERIVED_DATA:-$HOME/Library/Developer/Xcode/DerivedData/AirMark}"
result="${AIRMARK_TEST_RESULTS:-$AIRMARK_DERIVED_DATA/TestResults.xcresult}"
rm -rf "$result"
xcodebuild -project AirMark.xcodeproj -scheme AirMark -derivedDataPath "$AIRMARK_DERIVED_DATA" -destination 'platform=macOS,arch=arm64' \
  -resultBundlePath "$result" -test-timeouts-enabled YES -default-test-execution-time-allowance 120 "$@" test
echo "Result bundle: $result"
echo "Export captures with: xcrun xcresulttool export attachments --path \"$result\" --output-path <dir>"
