#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
cd Tooling
npm ci --ignore-scripts --no-audit --no-fund
./node_modules/.bin/esbuild renderer.js --bundle --format=iife --platform=browser --minify --outfile=../Sources/AirMarkRender/Resources/libraries.js
cp node_modules/katex/dist/katex.min.css ../Sources/AirMarkRender/Resources/
mkdir -p ../Sources/AirMarkRender/Resources/fonts ../Licenses
cp node_modules/katex/dist/fonts/*.woff2 ../Sources/AirMarkRender/Resources/fonts/
cp node_modules/katex/LICENSE ../Licenses/KaTeX.txt
cp node_modules/mermaid/LICENSE ../Licenses/Mermaid.txt
cd ..
python3 Scripts/licenses.py Tooling > Licenses/JavaScript-dependencies.txt
