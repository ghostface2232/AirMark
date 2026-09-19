#!/bin/bash
# Checks the parser and its seam with cmark-gfm. Run it after changing the parser or `reparse`, and
# before merging a swift-cmark upgrade (change the `exact:` pin in Package.swift, `swift package update`,
# then run this).
#
# AirMark reads cmark's tree in place and uses parts of cmark that its headers declare but do not document
# as API: the reference map (`parser->refmap`, entries made as `cmark_reference_create` makes them), and
# node fields (`as.list.marker_offset`, `as.list.padding`, `as.heading.setext`). A change to their layout
# fails to compile; a change to what they mean does not, which is what the steps below are for.
#
#   1. The core tests: the parser against the swift-markdown reference, `reparse` against `parse`.
#   2. The same under AddressSanitizer, for the map entries AirMark allocates and cmark frees.
#   3. A long fuzz of `reparse` against `parse`, which is where differences have shown up before.
#   4. The partial-parse benchmarks, to see that windows are still partial where they should be.
#
# About 5 minutes, the first time about 8. FUZZ_ROUNDS and FUZZ_SEEDS lengthen or shorten step 3.
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
rounds="${FUZZ_ROUNDS:-400}"
seeds="${FUZZ_SEEDS:-1,2,3}"

step() { printf '\n== %s\n' "$1"; }
# Runs a command, shows the lines of its output that matter, and fails the script if the command failed.
run() {
  local log status=0
  log="$(mktemp)"
  "$@" >"$log" 2>&1 || status=$?
  grep -E '^FUZZ|^✘|reproduce\(|Test run with|error:|AddressSanitizer|SUMMARY' "$log" || true
  rm -f "$log"
  if [ "$status" -ne 0 ]; then echo "failed: $*"; exit "$status"; fi
}

step "swift-cmark as resolved"
python3 -c 'import json; [print(p["identity"], p["state"].get("version"), p["state"]["revision"]) for p in json.load(open("Package.resolved"))["pins"]]'
echo "cmark fields read or written outside its API:"
grep -nE 'pointee\.(refs|size|ref_size|mem|as\.|entry|url|title|attributes|is_attributes_reference|linebuf|current)|refmap' \
  Sources/AirMarkCore/MarkdownTree.swift | sed 's/^/  /'

step "1. core tests"
run swift test --disable-sandbox --filter AirMarkCoreTests

step "2. core tests under AddressSanitizer"
# A separate build directory, so the sanitized build does not replace the normal one. Release: in Debug the
# sanitizer's padding makes each frame of the tree walk large enough that the nesting tests overflow even
# the parser's 16MB stack, at a depth the app handles.
run swift test -c release --disable-sandbox --sanitize=address --scratch-path .build/asan --filter AirMarkCoreTests

step "3. fuzz, $rounds rounds per pool, seeds $seeds (Release)"
AIRMARK_FUZZ_ROUNDS="$rounds" AIRMARK_FUZZ_SEEDS="$seeds" run swift test -c release --disable-sandbox --filter ReparseFuzzTests

step "4. partial-parse benchmarks (Release)"
swift build -c release --disable-sandbox --product AirMarkBench >/dev/null 2>&1
.build/release/AirMarkBench --references
.build/release/AirMarkBench --lists
echo
echo "Every REFERENCES line should say partial=true, and LISTS flat and nested should have small windows."
