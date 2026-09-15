#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
bash Scripts/build.sh Debug
open build/Build/Products/Debug/AirMark.app
