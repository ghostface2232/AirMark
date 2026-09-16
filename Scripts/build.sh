#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
# Derived data stays outside the source tree: test runners launched from ~/Documents hit the
# folder-access permission dialog, and the app bundle should not live next to the sources.
export AIRMARK_DERIVED_DATA="${AIRMARK_DERIVED_DATA:-$HOME/Library/Developer/Xcode/DerivedData/AirMark}"
xcodebuild -project AirMark.xcodeproj -scheme AirMark -configuration "${1:-Release}" -derivedDataPath "$AIRMARK_DERIVED_DATA" -destination 'platform=macOS,arch=arm64' build
