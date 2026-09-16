# Validation evidence

Baseline: clean `f9ec70f`; after: the accompanying working-tree patch. No dependency version changed.

Host: Mac17,3, 24 GiB RAM, arm64, macOS 27.0 (26A428), Xcode 27.0 (27A266a), Swift 6.4. Release builds, OS cache state uncontrolled. These are observations on this machine, not PLAN.md budget certifications.

- `bench-before.json`, `bench-after.json`: `swift run -c release --disable-sandbox AirMarkBench`. Same pre-existing short-line fixture, 20/10/3 samples. Index construction is included in parse time; the separately reported index time also includes the benchmark's length assertion.
- `long-lines-before.txt`, `long-lines-after.txt`: `swift run -c release --disable-sandbox AirMarkBench --long-lines`. Same new benchmark harness against the original and changed implementations, 5 samples at each size. Each token contains Hangul, an emoji and a combining mark. Lookups assert UTF-16 offsets; parses assert expected style counts.
- `swift-release.txt`: summary extracted from the full Release Swift test log (43 passing tests). The editor-only SCALE line predates correction of its percentile ranks; prefer `scale-release.txt` for that measurement.
- `scale-release.txt`: final isolated `swift test -c release --disable-sandbox --filter ScaleTests` output, nearest-rank percentiles, 30 edits per measured position. Both tests passed. The editor-only fixture and document-backed fixture differ in window/render/viewport state and are not an A/B pair. The 9.05ms editor-only p95 exceeds the 4ms budget; no typing-speed improvement is claimed.

The tests exercise byte preservation (including BOM and mixed line endings), every UTF-8 column against independent decoding, 400 deterministic random index edits, saving failures, stale parse rejection, external content restoration, Save As/Save To, recovery ordering, marked-text attributes and rendered image invalidation/labels. UI failures, fixes, final result-bundle locations and remaining limitations are recorded in `../../DEV_LOG.md`.
