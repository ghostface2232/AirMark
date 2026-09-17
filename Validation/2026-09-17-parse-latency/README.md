# Parse latency, parse application and render failures

The three original commits (`aeaf008`, `8a5da84`, `1a06e31`) were written without a toolchain and
not run. Everything below was measured afterwards on the development host, then three changes were
stacked on them: fixed pacing restored (`65ca984`), stale parses installed moved through later edits
(`881d4d8`), and a cheaper parse (`8dba8b9`). Sections 4 and 5 compare `main`, `881d4d8` and
`8dba8b9`.

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

The benchmark reads `parseCompletedCount`/`staleParseCount` and, from `881d4d8` on,
`presentationRevision` (the revision of the source the installed presentation was parsed from).
`main` has none of these, so the `main` worktree added the two counter lines `aeaf008` adds to
`scheduleParse` and `presentationRevision { parsed.revision }`; nothing else differed. With stale
parses installed, `applied` counts every installation and a key's latency ends at the first
installation whose source includes it.

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

## 4. Stale parses installed, and a cheaper parse

`step2-step3/`: `main` (`cb8c3df`), `step2` (`881d4d8`) and `step3` (`8dba8b9`), three runs each,
order rotated per run. p50 / p95 / max in ms, pooled.

| scenario | size | main | step2 | step3 |
|---|---|---|---|---|
| idle key → current parse | 100KB | 113 / 114 / 118 | 108 / 109 / 111 | 93 / 94 / 95 |
| | 1MB | 383 / 390 / 394 | 380 / 385 / 392 | 274 / 296 / 310 |
| | 10MB | 3,130 / 3,180 / 3,182 | 3,092 / 3,148 / 3,167 | 2,014 / 2,037 / 2,039 |
| slow typing, per key | 100KB | 117 / 123 / 134 | 113 / 118 / 122 | 98 / 103 / 106 |
| | 1MB | 2,168 / 9,102 / 14,251 | 407 / 552 / 601 | 265 / 298 / 333 |
| | 10MB | 21,580 / 37,352 / 39,116 | 4,531 / 5,897 / 6,069 | 2,958 / 3,816 / 3,940 |
| 80 ms typing for 35 s, per key | 100KB | 563 / 3,192 / 5,358 | 84 / 95 / 117 | 77 / 85 / 102 |
| | 1MB | 18,023 / 33,851 / 35,549 | 457 / 595 / 629 | 304 / 404 / 437 |
| | 10MB | 21,531 / 37,312 / 39,397 | 4,685 / 6,063 / 6,253 | 3,034 / 3,935 / 4,158 |
| parses installed during 35 s at 80 ms | 1MB | 1 of 111 | 115–116 of 115–116 | 162–179 of 162–179 |
| | 10MB | 1 of 13 | 13 of 13 | 19 of 19 |
| burst settle | 100KB | 87 / 89 / 89 | 85 / 87 / 88 | 75 / 78 / 79 |
| | 1MB | 495 / 506 / 509 | 482 / 495 / 497 | 323 / 343 / 364 |
| | 10MB | 5,019 / 5,104 / 5,104 | 5,063 / 5,144 / 5,144 | 2,886 / 2,953 / 2,953 |
| settle after 35 s at 80 ms, per run | 10MB | 4,433 / 3,874 / 3,847 | 5,492 / 5,503 / 5,372 | 3,908 / 2,981 / 3,336 |
| latest key during 35 s at 80 ms, max, per run | 10MB | 90 / 90 / 92 | 114 / 97 / 109 | 110 / 108 / 109 |

Standalone parse + `PresentationStore`: `step3` 16 ms (100KB), 166 ms (1MB), 1,701 ms (10MB), against
26–27, 274 and 2,764–2,800 ms.

What this shows:

- Installing stale parses bounds how long typing goes without a new parse to about two parses:
  the longest wait for a key during 35 s of 80 ms typing fell from 5.4 s to 117 ms at 100KB, from
  35.5 s to 629 ms at 1MB, and from 39.4 s to 6.3 s at 10MB. Slow typing at 1MB no longer waits
  seconds (max 14.3 s → 601 ms). Single keys after idle are unchanged, since nothing is running then.
- `step2` costs two things at 10MB. When typing stops while a parse runs, the parse of the final
  text starts only after it, so settling after 35 s of typing took 5.4–5.5 s instead of 3.8–4.4 s.
  Installing a 10MB parse runs on the main actor, and the latest key during typing arrived up to
  114 ms after the previous one instead of 90–92 ms, up to 34 ms late each time a parse lands
  (about every 3 s).
- `step3`'s cheaper parse shortens everything that includes a parse by about 40% and removes the
  settle regression: 3.0–3.9 s after 35 s of typing, 2.9 s after a burst (main 5.0 s). The hitch
  when a 10MB parse lands remains (108–110 ms).
- Burst parses per burst stay at five at 1MB and two at 10MB: the same parses run, but none is
  wasted, and at 1MB `step3` runs more of them (6–7) because each is shorter.

## 5. Where a 10MB parse went (`8dba8b9`)

Sampled with `sample` on a release executable parsing the fixture repeatedly
(2.82 s per parse before):

- `NSRegularExpression.init` for the list item and block quote patterns, compiled per item and quote:
  about 28% of parse samples. Compiled once: 2.82 → 2.28 s.
- `SourceIndex.offset(line:utf8Column:)` at the top of about 12% of samples, searching 156,000
  checkpoints and walking scalars; `ClosedRange.contains` in the scalar width was not inlined. A
  column inside a line's leading ASCII run now maps directly: 2.28 → 1.99 s.
- `walk` computed spans for every `Text`, `SoftBreak` and `LineBreak` and ran the type switch on them,
  though they add no style and their spans have no side effects: 1.99 → 1.65 s.
- `swift-markdown`'s `Document(parsing:)` is now most of what remains (about 0.9 s).

The parser output (styles with markers, elements, checkboxes) was compared byte for byte before and
after the three changes on every Markdown file in the repository and on 4,000 generated documents
mixing headings, nested quotes and lists, indented continuation lines, fences, tables, reference
links, HTML, math, CRLF/CR endings, tabs, Hangul, emoji and combining marks: 35,092 styles and 4,737
elements, identical.

## 6. Reparsing only the blocks an edit touched

`block-window/`: `main` (`cb8c3df`), `s3` (`8dba8b9`, the cheaper whole parse) and `win` (`10fc3c9`,
block windows), three runs each, order rotated per run. p50 / p95 / max in ms, pooled.

| scenario | size | main | s3 | win |
|---|---|---|---|---|
| idle key → applied | 100KB | 113 / 114 / 119 | 93 / 95 / 98 | **51 / 52 / 57** |
| | 1MB | 382 / 388 / 390 | 273 / 278 / 315 | **56 / 57 / 58** |
| | 10MB | 3,149 / 3,185 / 3,231 | 2,008 / 2,065 / 2,069 | **93 / 100 / 107** |
| slow typing, per key | 1MB | 1,994 / 9,085 / 14,240 | 258 / 278 / 300 | **60 / 65 / 68** |
| | 10MB | 21,899 / 37,670 / 39,422 | 2,909 / 3,799 / 3,935 | **97 / 105 / 112** |
| 80 ms typing for 35 s, per key | 100KB | 647 / 3,523 / 7,366 | 77 / 87 / 103 | **54 / 60 / 61** |
| | 1MB | 18,055 / 33,862 / 35,577 | 292 / 380 / 415 | **58 / 63 / 68** |
| | 10MB | 22,048 / 37,818 / 39,694 | 3,034 / 3,921 / 4,098 | **75 / 87 / 101** |
| burst settle | 100KB | 86 / 88 / 89 | 74 / 79 / 81 | **51 / 54 / 54** |
| | 1MB | 501 / 508 / 509 | 320 / 360 / 368 | **55 / 59 / 59** |
| | 10MB | 5,069 / 5,158 / 5,158 | 2,875 / 2,967 / 2,967 | **29 / 75 / 75** |
| stale parses per burst | 1MB | 4 of 5 | 5.9 of 6.9 | **0 of 15** |
| | 10MB | 1 of 2 | 1 of 2 | **5.7 of 15** |
| latest key during 35 s at 80 ms, max, per run | 10MB | 90 / 90 / 90 | 114 / 110 / 107 | **90 / 90 / 90** |

At 10MB a keystroke now reaches the screen's parse in about 100 ms rather than 2–40 s, the window
install costs nothing the key gap can see (90 ms, as on `main`), and typing no longer waits for a
parse of the whole document: each key starts its own parse of its block. At 100KB and 1MB every key
of a 35 s burst is parsed and installed (438 of 438) instead of 33–46 (`main`).

The windows stay small on this fixture (one heading, paragraph, task item per block). On the
repository's own Markdown with random typing they were a few hundred to a few thousand UTF-16 units,
except in `DEV_LOG.md`, where one top-level list is a single block and the window is that list.

### The cost on documents that cannot be reparsed in part

`block-window-references/`: the same fixture with one link reference definition appended, which makes
every parse whole, two runs each. `winref` is `10fc3c9`, `wintuned` is `fa5de7c`, which takes the
block spans from the walk instead of a second pass.

| | size | s3ref | winref | wintuned |
|---|---|---|---|---|
| standalone parse | 1MB | 167 ms | 170 ms | 165 ms |
| | 10MB | 1,679 ms | 1,789 ms | 1,701 ms |
| idle key → applied (p50) | 1MB | 277 | 293 | 288 |
| | 10MB | 2,021 | 2,228 | 2,158 |
| 80 ms typing, per key (p50 / max) | 10MB | 3,022 / 4,063 | 3,361 / 5,071 | 3,232 / 4,302 |

Recording block spans in a second pass over the document's children cost 61 ms of a 1,742 ms 10MB
parse (measured directly, with the `]:` scan at 12.5 ms); taking them from the walk brought the parse
to 1,681 ms. What remains on a document that is always parsed whole is about 1% of the parse plus the
`]:` scan, and about 6% of the wait after a keystroke at 10MB (2,021 → 2,158 ms p50).

## Remaining

- A document that may define link references (`]:` anywhere) is parsed whole on every keystroke, which
  is 2.2 s at 10MB, and costs about 6% more than before the block window existed.
- A top-level list is one block, so editing inside a long list reparses the whole list.
- A whole parse still holds the main actor for about 35 ms at 10MB when it lands (the style and element
  diff), and the presentation and edit log still store absolute offsets, so an edit moves every entry
  after it. Both are proportional to the document, not to the change.
- swift-markdown gives no source range to a paragraph that a GFM table directly below splits; such a
  document has no block spans and is parsed whole.

## Tests

`swift test -c release --disable-sandbox` passed at each commit: 86 editor/integration and 38 core
tests at `65ca984`, 88 and 38 at `881d4d8` and `8dba8b9`, 88 and 39 at `8a1f141`, 88 and 42 at
`2ffcf5b`, 89 and 42 at `10fc3c9`, 89 and 43 at `fa5de7c` (environment-gated scale benchmarks
skipped). `EditorTests/staleParseIsInstalledMovedThroughLaterEdits` failed with the move through later
edits removed and passed with it. `PresentationStoreTests`, `ArtifactStoreDifferentialTests`,
`EditorTests` and `RenderLifecycleTests` also passed on `1a06e31` before the revert.
