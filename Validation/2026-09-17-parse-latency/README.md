# Parse latency, parse application and render failures

**No measurement in this directory was executed.** The work in these three commits was written in a
Linux container with no Swift toolchain and no macOS: `swift`, `xcodebuild` and the Xcode SDKs are
absent, `AirMarkEditor` and `AirMarkRender` need AppKit and WebKit, and the network policy of this
environment refuses `download.swift.org`, so no toolchain could be installed either. Nothing here
was built, no test was run, and no before/after number is recorded. The benchmarks and tests below
are the ones to run on the development host; until they are run, the reasoning in each section is a
code argument, not an observation.

Everything under the other `Validation/` directories was measured on Mac17,3, 24 GiB, macOS 27.0,
Release. Keep that host and the measurement rules of `PLAN-2026-09-17.md` §5 when producing the
numbers for this directory: three independent runs for any tail claim, nearest-rank percentiles,
and the same fixtures and repetition counts before and after.

## Reproduction

```sh
# 1. Settle time after typing stops (100KB, 1MB)
swift test -c release --disable-sandbox --filter 'ScaleTests/typingSettleTimes'
# ... and at 10MB
AIRMARK_SCALE_10MB=1 swift test -c release --disable-sandbox --filter 'ScaleTests/tenMegabyteTypingSettleTime'

# 2. Keystrokes with 50,000 failed elements, and the parse application that follows them
AIRMARK_SCALE_HISTORY=1 swift test -c release --disable-sandbox --filter 'ScaleTests/renderFailureKeystrokeCosts'

# 3. Parse application with a full render history
AIRMARK_SCALE_HISTORY=1 swift test -c release --disable-sandbox --filter 'ScaleTests/artifactHistoryKeystrokeAndScrollCosts'

# Correctness of the two new differential paths
swift test -c release --disable-sandbox --filter 'PresentationStoreTests'
swift test -c release --disable-sandbox --filter 'ArtifactStoreDifferentialTests'

# Whole suite
swift test -c release --disable-sandbox
```

Take the `before` runs at `cb8c3df` (the commit these three sit on) and the `after` runs at each
commit. `ScaleTests/typingSettleTimes` prints `SETTLE_…`, the failure benchmark prints
`FAILURES_…`, and both print the `EditorPhases` split per keystroke.

## 1. Settle time after typing stops (`SETTLE_…`)

`MarkdownParsingWorker` still cannot stop a running parse; only a waiter that has not started
leaves the queue. So a parse begun while typing continues runs to the end and the parse of the
final text waits behind it, and the user's "typing stopped → formatting caught up" delay can be two
parses. At the parser costs already recorded here (`2026-09-16-review`: 33.6 ms at 100KB, 342.8 ms
at 1MB, 3,534.8 ms at 10MB) that is up to about 7 s at 10MB.

`ScaleTests/typingSettleTimes` measures it directly: 15 keystrokes 80 ms apart in the middle of the
document, then the wait until `editor.parsed.revision == editor.revision`, repeated three times.
It also reports how many parses each burst started (`parses=`) and how many of those were already
stale when they finished (`stale=`). Polling is every 2 ms, so the resolution is 2 ms, and this is
the time until the editor holds a current parse — not key-to-display latency, which needs W6's
Instruments path.

The change is the first step only, not a new parser: the wait before a parse and the limit on
unparsed time now follow the measured cost of a parse of this document.

- `parseDelay = clamp(lastParseCost, 45 ms, 250 ms)`: at 100KB it stays at today's 45 ms, and at
  1MB and above it is 250 ms, longer than a fast typist's gap between keys, so a burst starts no
  parse that the next key will make stale.
- `parseStalenessLimit = max(4 × lastParseCost, 150 ms)`: unchanged at 100KB. It replaces the fixed
  150 ms, which on a large document forced a refresh parse that was certain to be stale and that
  the next parse then had to wait behind. Continuous typing still refreshes, but a refresh may
  occupy at most a fifth of the burst instead of running back to back.

`lastParseCost` is what the parse itself took, reported by `MarkdownParsingWorker`; it excludes
time spent waiting for an earlier parse, so a queue does not inflate the pacing.

Expected from the code, to be confirmed or refuted by the run:

| | before | after |
|---|---|---|
| 100KB | unchanged | unchanged (delay 45 ms, limit 150 ms) |
| 1MB | several parses per burst, most stale | at most one refresh parse per burst; settle ≈ 250 ms + one parse |
| 10MB | settle up to two parses (≈ 7 s) | settle ≈ 250 ms + one parse |

If the 1MB or 10MB settle time does not fall, the pacing is not the cause and the next step is
block/incremental parsing, not a larger debounce. Record whichever the run shows.

## 3. Render failures per keystroke (`FAILURES_…`)

`errors` was a `[SourceSpan: RenderIssue]` dictionary rebuilt in full on every keystroke
(`Dictionary(uniqueKeysWithValues: errors.compactMap …)`), the same shape the old dictionary-backed
`ArtifactStore` had before `2026-09-17-artifacts-mermaid-tables`. A normal document has almost no
failures, so nothing shows; a document scrolled through with thousands of broken images, invalid
formulas or rejected diagrams keeps one entry each, and the keystroke cost becomes proportional to
the failures visited so far — the same "allocation per keystroke proportional to browsing history"
the artifact store had.

`ScaleTests/renderFailureKeystrokeCosts` is the benchmark: 50,000 formulas, every one of them
recorded as permanently failed through the new `EditorController.seedRenderFailures()` hook, then
30 keystrokes at the head, the middle and the tail, against the same document with no failures.
It prints the per-keystroke `EditorPhases` split; failures now move inside the `artifacts` phase,
which already covers the artifact spans moved by the same edit.

`errors` is now a `SpanList<RenderIssue>`, the sorted span list the artifact store uses: an edit
shifts the entries after it as integers with no allocation, a lookup is a binary search, and a
parse drops the records of changed elements in one pass. The semantics are unchanged — a record is
kept exactly when `PresentationEdit.unchanged` keeps its span, which is what `SpanList.apply` does.

`EditorTests/renderFailuresFollowEdits` covers the behaviour without a renderer: an edit before
every failure moves the records, an edit inside a failed element drops its record.
`RenderLifecycleTests/failedElementIsNotRetriedByUnrelatedEdits` still covers the same through a
real WebKit failure.

Expected from the code: keystroke cost with 50,000 failures becomes indistinguishable from the
no-failure document, as it did for artifacts (3.89 ms → 0.13 ms p50 there). Record the actual pair.
