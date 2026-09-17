# Parse latency, parse application and render failures

The three original commits (`aeaf008`, `8a5da84`, `1a06e31`) were written without a toolchain and
not run. Everything below was measured afterwards on the development host.

Host: Mac17,3 (Apple M5), 24 GiB RAM, macOS 27.0, Xcode 27.0 (27A266a), Swift 6.4. Release builds
(`swift test -c release --disable-sandbox`). OS cache state uncontrolled. A background
`mediaanalysisd` used about half a core; load averages (1.6–2.7) are in `progress.log`. Branches were
built in separate worktrees and run alternately (A B B A …), one test process per run. These are
observations on this machine, not PLAN.md budget certifications.

## Harness

`Tests/AirMarkEditorTests/ParsePacingBench.swift`, enabled by `PACING_BYTES`:

```sh
PACING_BYTES=1000000 PACING_LABEL=pr-1000000-r1 PACING_OUT=pr-1000000-r1.json \
  swift test -c release --disable-sandbox --filter ParsePacingBench
python3 Validation/2026-09-17-parse-latency/summarize.py <directory with the JSON files>
```

The W1 block (`ScaleTests.source`) at 100KB, 1MB and 10MB, in a `MarkdownDocument` whose window is on
screen. Every key is `performEdit` of one character in the middle paragraph, so the document
snapshot, rebasing, viewport restyle and parse application all run as in the app; it is not HID
input and not IME. A key's **latency** is the time from the key until a parse whose source includes
it is installed (`onParseApplied`), polled on the main actor at 1 ms. It is not key-to-pixel time.

- `idle`: one key after the editor has held a current parse for 1 s (1.5 s at 10MB); 20 samples (10).
- `slow`: 35 s of keys with a deterministic 200–400 ms gap (117 keys, same sequence every run).
- `bursts`: 15 keys 80 ms apart, 12 bursts (6 at 10MB); settle is last key → current parse.
- `sustained`: 35 s of keys 80 ms apart (438 keys).
- `parses`/`stale`: parses that finished during the scenario, and those whose text had changed by then.

The benchmark reads `parseCompletedCount`/`staleParseCount`. `main` has no such counters, so the
`main` worktree added exactly the two lines `aeaf008` adds to `scheduleParse`; nothing else differed.

## 1. Parse pacing in `aeaf008`: measured, then reverted

`pr-original/`: `main` (`cb8c3df`) against `1a06e31`, three runs each. p50 / p95 / max in ms, pooled
over the three runs.

| scenario | size | main | aeaf008 pacing |
|---|---|---|---|
| idle key → current parse | 100KB | 111 / 114 / 116 | 119 / 124 / 125 |
| | 1MB | 386 / 391 / 393 | **584 / 591 / 608** |
| | 10MB | 3,182 / 3,210 / 3,220 | 3,324 / 3,377 / 3,384 |
| slow typing, per key | 1MB | 2,341 / 11,089 / 13,617 (11–14 parses installed) | **18,426 / 34,305 / 35,777 (1 installed)** |
| | 10MB | 22,320 / 38,043 / 39,688 | 22,474 / 38,354 / 40,543 |
| burst settle | 100KB | 87 / 88 / 88 | 82 / 84 / 84 |
| | 1MB | 505 / 511 / 538 | 583 / 599 / 625 |
| | 10MB | 5,115 / 5,196 / 5,196 | **3,329 / 3,373 / 3,373** |
| parses (stale) per burst | 100KB | 15 (13.1) | 15 (13.4) |
| | 1MB | 5 (4) | 1 (0) |
| | 10MB | 2 (1) | 1 (0) |
| sustained 80 ms, max latency | 100KB | 3,756 / 5,758 / 3,839 per run | 5,198 / 3,599 / 4,959 per run |
| | 1MB | 35,5xx every run; 111 parses, 110 stale, 1 installed | 35,2xx–35,5xx; 25–26 parses, 24–25 stale, 1 installed |
| | 10MB | 39,5xx–39,8xx; 13 parses, 12 stale | 38,2xx; 3 parses, 2 stale |

Standalone parse + `PresentationStore` of the fixture: 27 ms (100KB), 277 ms (1MB), 2,834 ms (10MB).

What this shows:

- `parseDelay = clamp(lastParseCost, 45, 250 ms)` saved one parse of waiting on a 10MB burst
  (−1.8 s), but made a single keystroke about 200 ms slower at 1MB (+142 ms at 10MB), made a 1MB
  burst settle 78 ms later, and on 1MB slow typing — 200–400 ms gaps, shorter than 250 ms plus a
  280 ms parse — no parse was installed for the whole 35 s.
- `parseStalenessLimit = max(4 × lastParseCost, 150 ms)` cut wasted parses (111 → 25 at 1MB,
  13 → 3 at 10MB), but every refresh parse it started was stale when it finished, so it bought no
  freshness.
- On both branches, when a parse outlasts the gap between keys, continuous typing installs no parse
  until typing stops: 35 s at 1MB and 10MB, and up to 5.8 s at 100KB where the in-app parse and
  application (~67 ms after the 45 ms wait) exceed 80 ms. The editor drops any parse whose revision
  is not current, and no delay can change that.

Step 1 restores the fixed 45 ms / 150 ms and keeps the worker's cost report. `step1-fixed-pacing/`
(one run per size, labels `main` and `pr` = step 1) confirms it behaves as `main`: idle 381 vs 388 ms
at 1MB and 3,128 vs 3,225 ms at 10MB, with identical parse and stale counts in every scenario.

## 2. Applying a parse (`1a06e31`)

`installParse` hashed the spans of every unchanged element into a set and invalidated every render
element of both parses. `PresentationStore.elementDiff(comparedTo:)` replaces it with one merge walk
that returns the spans that differ and the spans equal in both; only the first are invalidated, and
artifacts and failures are retained by merging sorted lists.

`AIRMARK_SCALE_HISTORY=1 swift test -c release --disable-sandbox --filter 'ScaleTests/renderFailureKeystrokeCosts|ScaleTests/artifactHistoryKeystrokeAndScrollCosts'`,
50,000 formulas (6.5MB), three alternating runs (`step1-fixed-pacing/history-*.log`). The `before`
side is `main` with `renderFailureKeystrokeCosts` and `seedRenderFailures` ported to its dictionary.

`previous_applyParse`, middle/tail, per run: `main` 47–54 ms, after 23–25 ms (one run 37.9 ms), with
and without a render history or failures. Applying a parse is halved, not reduced to what changed:
`changedStyleSpans` and `elementDiff` still walk every style and element.

## 3. Render failures per keystroke (`8a5da84`)

Same runs. Keystroke p50 per run, 50,000 failed elements:

| position | main | after |
|---|---|---|
| head | 7.98 / 7.81 / 7.73 ms | 2.79 / 2.88 / 2.78 ms |
| middle | 6.53 / 6.47 / 6.44 ms | 1.34 / 1.36 / 1.37 ms |
| tail | 5.23 / 5.13 / 5.13 ms | 0.124 / 0.121 / 0.121 ms |

With no failures both are 2.8–3.1 / 1.3–1.4 / 0.12–0.13 ms, so a failure history no longer costs a
keystroke anything measurable; what remains at the head and middle is the style rebase.

## Tests

Step 1: `swift test -c release --disable-sandbox` passed, 86 editor/integration and 38 core tests
(environment-gated scale benchmarks skipped). `PresentationStoreTests`, `ArtifactStoreDifferentialTests`,
`EditorTests` and `RenderLifecycleTests` also passed on `1a06e31` before the revert.
