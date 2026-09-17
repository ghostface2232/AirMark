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

## 2. Mermaid 11.12.0 → 11.17.2

### Harness

There was no Mermaid corpus before this change; `MermaidCorpusTests` was written and run against 11.12.0 first, and its expectations are what 11.12.0 did:

- 24 well-formed diagrams covering every diagram type (flowchart with shapes and subgraphs, Hangul labels, sequence, class, state, ER, gantt, pie, journey, gitGraph, mindmap, timeline, quadrant, xychart, sankey, block, requirement, C4, packet, architecture, kanban, radar, treemap): each must render with visible ink.
- 8 malformed sources (empty, unknown type, dangling edge, unclosed label, incomplete sequence, unclosed class body, non-numeric pie value, bad state arrow): each must fail as a source error (`RenderFailure.invalid`), not a transient failure.
- 13 adversarial sources: 600 edges (over `maxEdges`), 60KB of text (over `maxTextSize`; Mermaid draws its own error message, which 11.12.0 returned as a rendered image), an init directive raising limits and `securityLevel`, script in labels, `click` callbacks and `javascript:` links, an init directive enabling HTML labels, script in sequence notes, a remote image and icon, a remote `url()` style, CSS/`</style>` injection in `classDef`, 60 nested subgraphs and a 10k-character label (both exceed the editor's 12-megapixel display limit), bidi and control characters. After every entry and again 300ms after the group, `window.airmarkInjected` must be undefined on the page.
- Positive control for the injection check: with the page temporarily inserting `<img src=x onerror=…>` next to the diagram, every following entry failed the check. Temporarily switching the page to `securityLevel: 'loose'` with HTML labels did not make any of the corpus vectors execute on 11.12.0.
- Existing suites: `RenderLifecycleTests` (killed content process, closed and minimized windows, script timeout, cancellation, 40 concurrent requests, in-flight limit, failed-element retries), `RenderTests` and `LayoutTests`.

Command: `swift test -c release --disable-sandbox --filter "MermaidCorpusTests|RenderLifecycleTests|RenderTests|LayoutTests"` → `mermaid-11.12.0-release.txt`, `mermaid-11.17.2-release.txt` (and the first Debug corpus run, `mermaid-corpus-11.12.0.txt`).

### Change

- `Tooling/package.json`: `mermaid` 11.17.2 exactly; `npm install --save-exact` updated the lockfile. KaTeX (0.16.22) and esbuild are unchanged. Mermaid 11.17.2 requires `katex ^0.16.47`, so npm installs a second KaTeX inside Mermaid for its label math; the editor's formulas still use 0.16.22 and its CSS and fonts. Parser 0.6.3 → 1.2.1 (drops langium/chevrotain and the vscode-languageserver packages), dagre-d3-es 7.0.11 → 7.0.14, new es-toolkit, fastdom, strictdom and @upsetjs/venn.js.
- `Scripts/vendor.sh` rebuilt `libraries.js`: 2,721,947 → 3,728,467 bytes; two consecutive rebuilds gave the same SHA-256 (`e88c3c70…`). Before changing anything, a rebuild at 11.12.0 reproduced the committed bundle byte for byte.
- `Licenses/JavaScript-dependencies.txt` is now generated by `Scripts/licenses.py`, called from `vendor.sh`. Run on the 11.12.0 tree, the generator reproduced the committed file byte for byte. It then also lists nested copies by install path (such as `mermaid/node_modules/katex 0.16.47`, and `d3-sankey/node_modules/d3-array`, which the old file omitted although they are bundled).
- The render cache key names `mermaid-11.17.2`.
- `WebRenderer.evaluateOnCurrentPage` is a test hook for the injection check.

### Results

- All 45 corpus entries have the same outcome on both versions; no entry defined `airmarkInjected`. Sizes are identical except block 166×80 → 159×106, requirement 188×393 → 176×393, C4 688×371 → 688×413 and gitGraph 282×185 → 282×184. Malformed-source messages are unchanged in kind (parser positions and expectations).
- Every lifecycle scenario prints the same outcome on both versions. The 400-node diagram alone took 0.333s → 0.385s (one sample each).
- First render on a fresh page, which includes loading the bundle (`AIRMARK_MERMAID_MEASURE=1 swift test -c release --disable-sandbox --filter firstRenderOnAFreshPage`, ten fresh pages per kind, three interleaved rounds per version, `mermaid-first-render.txt`): diagram p50 119.4–120.0 → 129.3–131.2ms, formula p50 108.1–113.8 → 117.7–118.6ms. Formulas load the same bundle, so they pay for its size too. This is once per renderer page.
- Full Release Swift suite: 102 tests passed (69 editor/integration, 33 core), and three more full runs passed. The first full run failed `killedContentProcessEndsTheRenderAndRecovers`, which requires exactly one new WebContent process while it runs: the corpus, running in parallel, created fresh render services. The corpus now shares one service and the fresh-page measurement is opt-in.
- UI: `testShowcaseRendersSpecialContent` passed against the Release app; `mermaid-11.17.2-showcase-top.png` is its capture with the showcase diagram.

Not done: Mermaid 12.x migration; a visual diff of every diagram type between versions beyond size and ink.

## 3. Large tables off the main actor

### Problem

`RenderService.drawTable` ran on the main actor: it decoded the table's JSON, measured every cell with `NSString.size(withAttributes:)`, and only then compared the size with the 12-megapixel display limit. A table that passed was drawn through an `NSImage` drawing handler and rasterized with `cgImage(forProposedRect:)`, and `RenderService` then rejected results over its 48MiB memory limit.

Probing the old output (`TableProbeTests`, removed after use) showed what "the old output" is exactly: the bitmap uses the main screen's backing scale (2 here, also for an environment at scale 1), `ceil(points × scale)` pixels per side, 16-bit float components with premultiplied alpha (8 bytes per pixel), in the main screen's color space ("Color LCD"). So the memory limit, not the display limit, was the effective one at scale 2: a table between about 1.6 and 3 million square points was measured and rasterized in full, then rejected.

### Harness

`AIRMARK_TABLE_MEASURE=1 swift test -c release --disable-sandbox --filter pathologicalTablesMainThreadStalls`: while `RenderService.render` handles a table, a main-actor task wakes every 1ms and records the longest gap. Five renders per table on a fresh service (failures are not cached); p50 and max. `stall` has a floor of about 2ms from the sleep granularity.

The first three names were chosen before the probe: `accepted-100x6`, `accepted-2x300` and `accepted-long-cells-50x3`, and `accepted-hangul-emoji-60x4`, pass the display limit but all fail the memory limit. The `renders-*` tables, added afterwards, display. `table-stall-before.txt` is the unmodified code. `table-stall-after.txt` runs, for every table, both the previous AppKit code (kept in the test target as `ReferenceTableRenderer`, called from a main-actor task as `RenderService` did) and the new path; the reference rows reproduce the before file.

### Change

- `TableRenderer` (AirMarkRender) measures cells with CoreText line bounds and draws with CoreText frames into a CoreGraphics bitmap of the same format, scale and color space, in a detached task. `RenderService` reads the screen's scale and color space and the user's writing direction on the main actor and passes them in.
- Before measuring any cell, `TableRenderer.preflight` uses the row and column counts: the height is exact and the width lies between every column at 70pt and every column at 300pt. A table whose narrowest possible width already fails the display limit fails with the display-limit message. A table whose widest possible width still passes the display limit but whose narrowest possible bitmap exceeds the memory limit fails with the memory-limit message. Anything else is measured, as before. After measuring, the memory limit is checked before rasterizing.
- Two AppKit behaviors had to be reproduced to match the reference: measured widths include trailing whitespace (`CTLineGetTypographicBounds`, not the framesetter's suggested size, which dropped it and narrowed a column), and natural alignment follows the user's language direction rather than each cell's script (a Hebrew or Arabic cell is left-aligned in a left-to-right locale). Both were caught by the equivalence test below and fixed. Only a left-to-right locale and a single 2x screen were available; the right-to-left locale path and scale/color space with several screens are unverified.

### Equivalence with the AppKit drawing

`matchesTheAppKitReference` renders 15 tables (ragged rows, empty cells, Hangul and emoji, trailing spaces, wrapped long cells, wide tables, RTL, symbols, and tables at and over both limits) at 16pt/680pt/2x light, 13pt/600.25pt/1x dark and 19pt/720.5pt/2x light, through the reference and the new renderer. Every pair has the same outcome and failure message; successful pairs have the same point size, pixel size, bytes, baseline, label, bitmap format and color space (`table-equivalence.txt`). Pixels, compared as 8-bit sRGB channels: 12 of the 15 tables are identical at all three settings; Hangul/emoji differ by a mean of 0.14–0.25 per channel (color glyph antialiasing; visually identical), RTL by 0.00–0.35. The test bounds the mean difference at 1.0 and the share of channels differing by more than 32 at 1%.

### Results (Release, main-thread stall p50 / total p50)

| table | JSON | outcome | AppKit on main | CoreText off main |
|---|---:|---|---:|---:|
| rejected-tall-20000x4 | 876KB | display limit | 327–345 / 327–345 ms | 2.1 / 17.1 ms |
| rejected-wide-10x5000 | 489KB | display limit | 194–204 / 194–204 ms | 2.1 / 6.4 ms |
| rejected-long-cells-2000x3 | 8.5MB | display limit | 1,086–1,088 / 1,088 ms | 3.2 / 8.2 ms |
| accepted-100x6 | 4.9KB | memory limit | 13.1–13.7 / 13.7 ms | 2.1 / 1.7 ms |
| accepted-2x300 | 7.6KB | memory limit | 12.6–13.1 / 13.0–13.1 ms | 2.1 / 1.8 ms |
| accepted-long-cells-50x3 | 176KB | memory limit (after measuring) | 53.3–53.6 / 53.5–53.6 ms | 2.1 / 24.0 ms |
| accepted-hangul-emoji-60x4 | 4.6KB | memory limit | 15.4–15.9 / 15.6–15.9 ms | 2.1 / 0.1 ms |
| renders-40x6 | 1.9KB | 680×1648pt | 5.4 / 5.4 ms | 2.1 / 5.6 ms |
| renders-2x100 | 2.4KB | 9677×82pt | 4.4 / 4.4 ms | 2.1 / 3.7 ms |
| renders-long-cells-20x3 | 68KB | 900×824pt | 21.5 / 21.4 ms | 2.1 / 21.0 ms |

Ranges are the before run and the reference rows of the after run. Tables that display take about as long as before, now off the main thread. The remaining cost for rejected tables is JSON decoding (the 8.5MB case) and, for `accepted-long-cells-50x3`, measuring cells whose widths decide the outcome.

Tests: full Release Swift suite 105 passed in three runs (72 editor/integration, 33 core); full Debug suite 105 passed. `testShowcaseRendersSpecialContent` passed against the Release app, and `table-coretext-showcase-top.png` shows the showcase table's header row drawn by the new path. The capture further down the document was covered by a System Settings window that was open on the machine at the time and is not kept.
