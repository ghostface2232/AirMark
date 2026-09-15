#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
xcodebuild -project AirMark.xcodeproj -scheme AirMark -configuration "${1:-Release}" -derivedDataPath build -destination 'platform=macOS,arch=arm64' build
