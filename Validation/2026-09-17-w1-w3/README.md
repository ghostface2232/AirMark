# W1–W3 validation evidence

Host: Mac17,3, 24 GiB RAM, arm64, macOS 27.0 (26A428), Xcode 27.0 (27A266a), Swift 6.4. Release builds. OS cache state uncontrolled. These are observations on this machine, not PLAN.md budget certifications (the reference machine is an M1 8GB on macOS 26).

## W1 — input path

- `scale-before-1.txt`: `swift test -c release --disable-sandbox --filter ScaleTests` at `4a019d0`, before the presentation store.
- `scale-10mb-store-only.txt`: `AIRMARK_SCALE_10MB=1 swift test -c release --disable-sandbox --filter tenMegabyteDocumentKeystrokeCosts` after `76c5187` (store), before `51f0304` (pending-range merge). The tail keystroke still cost 3.2ms with rebase and snapshot at zero; this is what led to splitting the edit and finding 230,665 pending invalidation ranges.
- `scale-w1-after.txt`: `AIRMARK_SCALE_10MB=1 swift test -c release --disable-sandbox --filter ScaleTests` after `51f0304`.

Keystroke durations are synchronous main-thread time of one `performEdit`. The document-backed test then lays out the edited paragraph and reports that separately (`layout`). The `_PHASES` lines are per-keystroke sums of `EditorPhases` intervals. Neither is key-to-display latency.

## W3 — adversarial inputs

- `adversarial-before.txt`: `swift run -c release --disable-sandbox AirMarkBench --adversarial` before the W3 changes. `query2000` is 2,000 caret-sized (6-unit) style queries at deterministic random positions on the presentation store.

## W4 — WebKit render lifecycle

- `w4-before.txt`: `swift test --disable-sandbox --filter RenderLifecycleTests` against the renderer at `a83df84`, with only two observation hooks added (a render attempt counter and a page load counter) and a test-local stub for failure classification.
- `w4-after.txt`: the same suite after the lifecycle change.

Two corrections to the before run. Its slow diagram was top-to-bottom, which on its own exceeds the 12-megapixel display limit, so the "exceeds the display limit" failures after killing the process and closing the window came from the diagram, not from those events. The final tests use a left-to-right diagram that is scaled to the column (0.31 s alone; the kill at 0.15 s lands mid-render). The before run also counted attempts on the shared render service, which other suites use in parallel; the final test counts requests on its own editor.

What the before run did establish: 8 of 40 concurrent formulas failed permanently as "Renderer unavailable"; a render in a minimized window was a permanent failure; a failed formula was resubmitted on every unrelated edit (3 attempts for 3 edits); and a termination callback naming another web view discarded the current page (2 loads instead of 1). No indefinite wait was reproduced in any scenario, before or after.

## W3 — scaling curves

- `adversarial-scaling-before.txt`: `swift run -c release --disable-sandbox AirMarkBench --adversarial` at `92eb8a7`. Each corpus is measured at doubling sizes; `parse_exponent` and `query_exponent` are log2 of the time ratio to the previous size.

Only paths whose curve is superlinear are changed. Every parse exponent over document-sized corpora is 0.93–1.08, including nested containers, which are slow but linear, so the parser's walk is left alone. Two curves are not:

- A caret-sized query inside a long block quote or nested containers has an exponent of 1.00 per query: one query scans the container. A normal document stays at 0.11–0.23.
- Parsing one line of `$1 ` or `$a ` repeated has an exponent of 1.95–2.02: each unclosed `$` rescans the rest of the line.

The long-list and unclosed-display query exponents move between 0.08 and 0.76 without a trend, at 0.3–0.7 ms for 2,000 queries; that is not treated as evidence.

### Queries inside long containers

- `adversarial-scaling-query-after.txt`: after returning only nearby markers and querying a maximum tree. Long-quote queries fall from 229.8 to 1.2 ms per 2,000 at 1MB and nested containers from 425.7 to 1.8 ms; query exponents are 0.10–0.22 for every corpus.
- `adversarial-scaling-markers-only.txt`: an experiment, not committed code. Nearby markers with the old linear scan still give exponents of 0.96–1.22 in long quotes and nested containers, so both causes are needed. The tree's cost in a normal document is about 0.24 ms per 2,000 queries at 1MB (0.27 → 0.50 ms).
- The first attempt changed only the scan to a tree and left the exponent at 1.00: each query copied every `>` marker of the quote into its result.

### One-line dollar signs

- `adversarial-scaling-math-after.txt`: after the scanner remembers where a failed scan stopped. One line of `$1 ` or `$a ` now has parse exponents of 0.90–1.00 (80KB: 947.7 → 0.63 ms). Lines of bounded length were already linear in document size; they lose the per-line rescanning factor (currency lines at 1MB: 140.7 → 9.5 ms). Other corpora are unchanged within noise.
- `MathScannerTests` compares the scanner with the original on 3,000 random inputs with random, possibly overlapping protected spans. It fails if the two delimiter kinds share one remembered boundary or if the boundary is extended to the end of the source. Recording the boundary one position later is not a defect: no opener can start at a line break, inside a protected span or at the end.

## W2 — rendered pixels

- `memory-before.txt` / `memory-after.txt`: `AIRMARK_MEMORY=1 swift test -c release --disable-sandbox --filter MemoryTests`. 150 distinct 1600×1200 PNG images, each downsampled to the 1360-pixel column (about 5.9MB decoded), one per short paragraph. The editor scrolls to every third image and back.

How the numbers were obtained matters. ImageIO thumbnails decode lazily: 150 of them cost 7MB when created and 798MB after each was drawn once (measured separately). A test window is never composited and draws nothing, so the first runs showed 16MB of growth while the editor held 890MB of nominal pixels. The test now draws each image the editor holds once into a small context, standing in for the screen. It measures app-process `phys_footprint`; WebKit content processes are not involved for images and are not counted.

| | before | after |
|---|---:|---:|
| peak footprint growth | 903.1MB | 65–71MB (two runs) |
| images holding pixels after scrolling down | 150 | 14 |
| elements with layout metrics | 150 | 150 |
| render requests scrolling down / back up | 138 / 0 | 177 / 138 |

Scrolling back requests each image at most once. The first pass requests 177 for 150 images: some images rendered ahead of scrolling were released for the budget before they came into view.

Two intermediate designs failed this test and are recorded because they explain the final one. Releasing pixels relative to the viewport controller's range produced a render/release loop (1,177 stores for 71 images) because, in the offscreen window, that range fell back to the start of the document between layout passes. Measuring windows in UTF-16 units held 39 images: a one-line image reference can be a screen tall, so ±2,000 units spanned about 40 screens. Windows are now screen heights derived from the scroll position.
