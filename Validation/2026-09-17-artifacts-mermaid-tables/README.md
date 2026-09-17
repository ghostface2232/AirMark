# Artifact history, Mermaid 11.17.2, large tables

Host: Mac17,3, 24 GiB RAM, arm64, macOS 27.0 (26A428), Xcode 27.0 (27A266a), Swift 6.4. Release builds unless noted. OS cache state uncontrolled; `uptime` load averages are in the raw files (a background `duetexpertd` used one core during several runs). These are observations on this machine, not PLAN.md budget certifications.

## 1. ArtifactStore with a long render history

### Problem

`ArtifactStore` kept metrics and pixels in one `[SourceSpan: Entry]` dictionary. Metrics are kept for every element rendered in the current environment, so after scrolling through a long document the dictionary holds every element while only a bounded set holds pixels. Two per-event paths walked all of it:

- `apply(edit)` rebuilt the whole dictionary (and the id map) on every keystroke, wherever the edit was.
- `releasePixels` iterated every entry and sorted the resident ones after each render completion that took the store over budget.

### Harness

- `ARTIFACT_STORE` (`swift test -c release --disable-sandbox --filter artifactStoreHistoryCosts`): the store alone with 1k/10k/50k measured elements (64×40 artifacts, 64MiB budget, so 6,553 resident). 200 single-character edits at head/middle/tail, then a scroll from top to end where twelve elements per step store pixels and release.
- `HISTORY_SCALE` (`AIRMARK_SCALE_HISTORY=1 swift test -c release --disable-sandbox --filter artifactHistoryKeystrokeAndScrollCosts`): W1's document-backed keystroke measurement on the W1 block repeated to 50,000 formulas (6.5MB), once with no history and once after `seedArtifactHistory` records metrics for all 50,000 elements (pixels then bounded by the budget). 30 keystrokes at head/middle/tail, then 20 scroll steps through the document with a visible window so renders complete. `artifacts` is the new `EditorPhases` interval around the store's edit move and pixel release.
- `DOCUMENT_SCALE` (1MB W1 fixture, no history) is included in the same runs as a W1 regression check.

Files: `artifact-store-before.txt` / `artifact-store-after.txt`, `artifact-history-before.txt` / `artifact-history-after.txt` (three runs each for the history test).

### Change

Metrics and resident pixels are separate collections. Both are `SpanList`s: spans sorted by start (render elements never overlap) with parallel payloads. An edit binary-searches the first span it reaches, removes the contiguous touched entries and shifts later starts as integers. Pixels are a dictionary by drawing identity, so drawing never searches spans. Release looks only at resident spans: the farthest remaining one is always the first or last outside the protected range, so release takes from both ends and removes a prefix and a suffix. Parse retention (`retain`) is still linear; `applyParse` was ~49ms with and without history before the change, so it was not changed.

`ArtifactStoreDifferentialTests` runs the previous dictionary implementation (in the test target, with ties between equal distances broken toward the earlier element) against the new store on 60×400 random stores, edits, releases, retentions and removals, comparing counts, pixel bytes, metrics, identities, `needsPixels`, `hasPixels` and drawability after every step. It failed under two deliberate mutations (edit removal bound, release window bound); a mutation of the tie-break alone was not detected, because the original order among equal distances was unspecified and such ties are rare.

### Results

Store alone, 50,000 measured / 6,553 resident, per call:

| | before p50 / p95 | after p50 / p95 |
|---|---:|---:|
| edit at head | 3.323 / 3.763 ms | 0.0137 / 0.0137 ms |
| edit at middle | 3.336 / 3.613 ms | 0.0060 / 0.0062 ms |
| edit at tail | 3.182 / 3.531 ms | 0.0000 / 0.0001 ms |
| release after a render | 1.972 / 2.073 ms | 0.0023 / 0.0026 ms |
| store a render | 0.0002 / 0.0007 ms | 0.0384 / 0.0745 ms |

Storing a new element now inserts into sorted arrays (a memmove of the later entries); at 50,000 it costs about 0.04ms per render, against the 2ms release it replaces in the same completion.

Editor, 6.5MB document with 50,000 formulas, keystroke p50/p95 (main-thread time of one `performEdit`):

| position | no history | history before | history after (3 runs) |
|---|---:|---:|---:|
| head | 2.82 / 3.07 ms | 6.74 / 7.23 ms | 2.66 / 2.91 ms |
| middle | 1.35 / 1.52 ms | 5.52 / 5.99 ms | 1.41 / 1.63 ms |
| tail | 0.13 / 0.18 ms | 3.89 / 4.38 ms | 0.13–0.14 / 0.21–0.22 ms |

With history, the `artifacts` phase was 3.7–4.1ms p50 per keystroke before and 0.00–0.01ms after; the rest is W1's style rebase, unchanged. Release during scrolling: p95 2.06ms before, 0.003ms after (708 calls). The 1MB `DOCUMENT_SCALE` numbers are unchanged (tail 0.12/0.15ms before and after).

### Scroll steps and CPU state

The synchronous scroll step (`scrollRangeToVisible` + `viewportDidChange`) with history was p50 17.0–17.6ms before (three runs) and 18.6–19.7ms after (four runs); without history it was 15.3–16.4ms in both. Interleaved old/new pairs reproduced the difference (`artifact-scroll-ab-probe.txt`, which includes temporary sub-timings that are not in the committed code). The extra time was inside TextKit: per call, `renderWindows` 0.57–0.62 → 0.98–1.12ms and `textLayoutFragment(for:)` 0.148 → 0.384ms, while the number of paragraphs generated (6,519 vs 6,540 over the scroll), their total time (149 vs 145ms), scroll positions, document heights and residency matched step for step, and a `sample` of each run showed no store frames under those calls.

Putting a 2ms busy-wait back into the new store's release (the time the old release spent) returned those TextKit calls to 0.568ms and 0.159ms. So the difference is the main thread idling between render completions and running TextKit on a less warmed-up core, not work added by the store. The step's p50 in that run was 18.48ms, so the busy-wait does not account for the whole step; step times at this sample size (20 steps) are noisy and are not claimed as an improvement or a regression. No change was made for this.
