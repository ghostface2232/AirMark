#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
bash Scripts/build.sh Debug
open "${AIRMARK_DERIVED_DATA:-$HOME/Library/Developer/Xcode/DerivedData/AirMark}/Build/Products/Debug/AirMark.app"
