# AirMark development log

## 2026-09-16 — Initial native implementation

- Xcode is now installed at `/Applications/Xcode.app`, selected by xcode-select. Swift 6.4 / macOS 27; deployment target macOS 26, arm64.
- Added the Xcode host and local Core/Editor/Render packages, pinned swift-markdown 0.8.0 and cmark 0.8.0.
- Added source coordinate mapping, byte-preserving UTF-8/BOM IO, recovery snapshots, Markdown semantic parsing, and math extensions.
- Added TextKit 2 paragraph presentation with source-length-preserving replacements, active paragraph reveal, IME deferral, and native undo.
- Added bundled Mermaid 11.12.0 and KaTeX 0.16.22, independent lazy workers, bounded in-memory render cache, native table/local-image rendering.
- Added the document app, menus, autosave/recovery, external conflict protection, and find/replace.
- Validation: Debug Xcode build succeeded; 8 core tests and 3 editor integration tests passed. These include source round-trip, random position-index edits, reference links, math exclusions, stale recovery writes, presentation/source separation, native undo, and marked-text preservation.
- Actual screen behavior and WebKit snapshots are still being verified. No claim yet for the target performance budgets, VoiceOver completeness, or runtime compatibility on macOS 26.

## 2026-09-16 — Rendering fixes and document verification

Validation host: macOS 27.0 (26A428), Xcode 27 / Swift 6.4. macOS 26 runtime behavior is still unverified.

- **Overlapping blocks (Mermaid, tables, display math drawn over the following text).** Measured with a layout-fragment dump: lines carrying a rendered attachment kept the plain 27pt text height. Two causes. TextKit 2 sizes attachments from `attachmentBounds(for:location:textContainer:proposedLineFragment:position:)`, not from `bounds`, so `ArtifactAttachment` now overrides it and draws its image directly (`allowsTextAttachmentView = false`). Independently, concealing markers by replacing them with U+200B made TextKit 2 drop the attachment height for any line that contained one (reproduced in isolation: `"\u{FFFC}\u{200B}\n"` lays out at 27pt, `"\u{FFFC}x\n"` at 55pt). Concealment now keeps the source characters and applies a 0.01pt font and clear color. `LayoutTests` asserts that layout fragments of the showcase fixture never overlap.
- **First inline formula blank.** Only the first KaTeX render in a WebView was empty; later ones were fine. KaTeX glyphs are invisible until their @font-face files load, and `document.fonts.ready` resolved before the lazily triggered loads. `renderer.html` now loads every bundled face before the first render. `RenderTests` checks ink coverage of the first inline render, display math, Mermaid and native tables.
- **Clipped superscripts.** The snapshot rectangle followed the element box, which excludes overflowing glyphs. The renderer pads the output box to the union of text leaf rects in `.katex-html`. The hidden MathML tree and SVG elements are excluded: KaTeX draws stretchy delimiters such as `\sqrt` with 400em-wide SVGs clipped by their parent, and including them produced a 6484pt box that the editor then scaled down to a smudge. `RenderTests` renders a `\sqrt` display formula after a small inline one and checks its width. The WebView is also given a wide measuring frame before each render and the output padding is reset per render.
- Table header cells are measured with the bold font they are drawn with. Block quote `>` prefixes are markers and are concealed.
- **Document verification without XCUIAutomation.** `MarkdownDocument` and `DocumentSnapshot` moved from the app target into `AirMarkEditor` (Info.plist `NSDocumentClass` = `AirMarkMarkdownDocument`; the recovery store is injected at launch). `DocumentTests` covers five sequential saves with BOM/CRLF bytes and self-notifications, an external change while edited (save refused, Save As keeps the edits), an external change while clean (reload), and recovery records.
- The file-change notification could arrive after a newer save had replaced the last persisted bytes; the snapshot now remembers every byte sequence the document read or wrote and treats any of them as its own.
- UI tests (`UITests/AirMarkUITests.swift`): the repeated-save test passed twice on an idle machine; with the machine in use it failed from interference (typing arrived through the active Korean input source, focus moved). They synthesize keyboard input and need an idle session. `testInlineMathFixtureScreenshot` and `testShowcaseRendersSpecialContent` attach window captures; export them with `xcrun xcresulttool export attachments --path <bundle> --output-path <dir>`. The window state assertion was replaced by "app still running and no sheet"; under XCUITest the app reports `runningBackground` even while receiving input, whereas a LaunchServices launch brings it to the front normally.
- Known limitations: `-`/`[ ]` list and task markers and code-fence lines are shown verbatim; images in the fixture are not exercised; no VoiceOver, dark mode or performance measurements yet.

## 2026-09-16 — Marker presentation and caret rules

- Inline formulas pad 1pt horizontally and 2pt vertically in the renderer; display formulas keep 4pt.
- Unordered list markers show as bullets and fenced code delimiters are hidden; the closing fence marker includes the following line break so its line collapses (a fence line of 0.01pt characters lays out at zero height). Task items hide their list marker and show an SF Symbol box (`square` / `checkmark.square.fill`) as a text attachment; clicking it toggles `[ ]`/`[x]` through the normal edit path. Tinting uses a source-in fill: source-atop left the symbol's black underneath a translucent color.
- Caret rules (`EditorController.concealUnits`, `normalizedCaret`): opening markers avoid `[start, end)` and snap to the text after them, closing markers avoid `(start, end)` and snap to the nearer boundary, rendered elements are skipped whole. The direction comes from the text view's movement overrides; clicks and Home/End use the nearest rule. One consequence is a "sticky" step at run edges: Right from the end of bold text first lands after the hidden closing marker, then moves on. Backspace after an opening marker removes that marker; after a closing marker it deletes the character before the marker; at an element edge it enters the source. Verified by `caretStaysOutsideConcealedMarkers` and `deletingAtMarkerEdgesEditsSourceUnits`.
- `koreanCompositionSequenceInsideBold` replays a two-set composition (ㅎ→하→한, ㄱ→글) through `setMarkedText`/`insertText`. A real input-method session is still a manual check; the automated test does not exercise the IME's own candidate handling.
- Layout observation used while testing these: a paragraph whose characters are all 0.01pt has zero height, so concealed fence lines need no separate paragraph style.

## 2026-09-16 — Files that move or vanish, images, find

- The launch decision is `LaunchPlan.resolve` in the core package: newest recovery record whose bytes match its file → open the file with the record's selection; a record with newer text or no file → an unsaved draft titled "Recovered — name"; otherwise the most recent document, else a blank note. A force quit never reaches `close()`, so the record written 600ms after the last edit is what a relaunch sees; `forceQuitRecoveryReopensUnsavedEdits` checks that path.
- Moved or renamed files (`presentedItemDidMove`) update the editor's base URL, drop image artifacts so relative paths re-resolve, and rewrite the recovery record with the new path. A deleted file (`accommodatePresentedItemDeletion`) detaches the document: `fileURL` becomes nil, the title reads "Deleted — name", the change count is set so Save prompts for a location, and nothing is written back to the old path. Both are exercised by calling the presenter hooks directly; the OS delivers them through file coordination, which the tests do not simulate.
- Local images: `Fixtures/swatch.png` (64×40) is referenced from the showcase document. The render test checks downsampling to the column width at 2× (a 32×20pt result), the accessibility label, and that relative paths without a document location and remote URLs are refused.
- Find: NSTextFinder reads the system find pasteboard when the text view is created, so a programmatic `nextMatch` only sees a search string set before the editor exists. `findSelectsMatchesAndReplacingKeepsMarkdown` covers next-match selection, replacing the selection as a normal undoable edit, and the surrounding `**` surviving. Replace All through the find bar is a UI test.
- UI suite on an idle machine (`Scripts/test-ui.sh`): all four tests pass — five sequential saves with relaunch restore, the showcase and inline-math captures (the swatch image renders in place), and typing/undo/redo plus Replace All through the find bar. Two infrastructure problems were found first. The runner read fixtures from the source tree under `~/Documents`, so macOS showed a folder-access dialog; the first test waited on it until its two-minute allowance ran out and the following tests were denied access. Fixtures now ship inside the UI test bundle and derived data lives in `~/Library/Developer/Xcode/DerivedData/AirMark`. The find bar also pre-fills the last search from the system find pasteboard (the unit test had left "this" there, giving "thisalpha"), so the UI test clears the field first and the unit test restores the pasteboard.
- Not covered: OS-delivered move/delete notifications through file coordination, and Save As from the "Deleted —" state in the real app.

## 2026-09-16 — Large documents, dark appearance, accessibility, measurement

- **1MB document.** A scale test (`ScaleTests`, Debug build, 1MB of the showcase-like block: 7,693 render elements, 46,158 style runs, 23,079 paragraphs) exposed two O(n²) paths. Applying the first parse invalidated the whole document, and TextKit 2 regenerates every paragraph in an edited range at once, while each regenerated paragraph scanned every style run: 26 s on the main thread. Keystrokes cost 72 ms for the same reason plus whole-document string copies (`textView.string` bridges a copy; `String` comparisons against that NSString-backed value normalize every scalar and took about a second each in the test itself). Fixes: styles are sorted by start with a prefix-maximum-end index so paragraphs and caret rules binary-search the runs that touch them; elements are binary-searched too; the text storage's own `mutableString` is used instead of bridged copies; render candidates come only from the viewport window; and invalidation outside the viewport is deferred until scrolling reaches it (`pendingInvalidation`, applied from the bounds-change and layout paths). After the changes the parse applies in about 0.8 s and a keystroke costs about 23 ms in Debug (dominated by the per-keystroke O(n) rebase of 46k runs; Release numbers are in the measurement section below). The test also materializes a far paragraph before the parse and checks it is restyled when scrolled into view.
- Not addressed: the per-keystroke rebase is still linear in the number of style runs, and paragraph lookups inside very long containers (one block quote spanning thousands of paragraphs) still walk that container's runs. 10MB was not exercised in the editor; the parser alone takes about 4.1 s for 10MB in Release (`AirMarkBench`).
- **Dark appearance.** WebKit snapshots cannot be captured transparent with public API, so formulas and diagrams sat on white boxes. The render environment now carries the editor's resolved text background as a CSS color and the renderer paints it behind the page; the environment is part of the cache key, so an appearance change re-renders. `--appearance dark|light` pins the appearance for screenshot tests; `RenderTests` checks a corner pixel is dark and glyphs are light. Table, code, quote and checkbox colors were already dynamic.
- **Accessibility and keyboard.** The text view exposes the label "Markdown editor", the identifier `markdown-editor` and the source as its value; rendered elements carry descriptions ("Completed task", "Table, 2 rows", formula source, diagram source, image alt text) checked by `accessibilityExposesLabelsAndElementDescriptions`. The UI typing test now selects a word with Option-Shift-Left and applies Cmd-I, then undoes it, so open → type → format → save is covered keyboard-only across the UI tests. A VoiceOver walkthrough (heading/link/table navigation, how concealed markers are announced) has not been done; VoiceOver reads the source text, so markers are spoken.
- **Quit hung.** `applicationShouldTerminate` returned `.terminateLater` and replied from a main-actor Task; AppKit waits for that reply in a nested event loop that never runs the Task, so Cmd-Q (and the measurement's automatic quit) hung forever. Found by sampling the stuck process. Recovery records are now written synchronously and the delegate returns `.terminateNow`; `testInlineMathFixtureScreenshot` presses Cmd-Q and checks the process ends and a record exists. UI tests run immediately after `Scripts/measure.sh` once failed to activate the app ("Running Background"); a clean rerun passed.
- **Measured (Release build, Mac17,3 / Apple M5, 24 GB, macOS 27.0, `Scripts/measure.sh`).** Milestones are milliseconds from process start as reported by the kernel; the document is the showcase text repeated (formulas, a diagram, a table and an image per copy). 100KB, 10 launches: window shown p50 136 / p95 157, editable p50 132 / p95 154, first parse applied p50 176 / p95 198, first render p50 185 / p95 201. 1MB, 3 launches: window shown p50 139, editable p50 135, first parse applied p50 359 / p95 364, first render p50 369. Steady state with the 1MB document after 10 s: 217 MB RSS for the app process (WebKit content processes are separate and were not attributed), 0.0% CPU. Keystroke on the 1MB fixture (Release `ScaleTests`): p50 3.3 ms, p95 3.4 ms, max 7.0 ms of main-thread time per insertion; parse 409 ms off the main thread. Not measured: input-to-display latency at 60/120 Hz, scrolling frame times, and formatting latency after typing stops; these need Instruments. Against PLAN.md's budgets these launch, keystroke and idle numbers are inside the targets on this machine, but the reference machine there is an M1 MacBook Air 8GB on macOS 26, which was not used.

## 2026-09-16 — Review of f9ec70f, correctness regressions and parser scaling

- Started from a clean working tree at `f9ec70f`; inspected the recent commits and all first-party Swift implementation modules, tests and measurement scripts. Baseline `swift test --disable-sandbox`: 35 tests passed (25 editor/integration, 10 core). Initial sandboxed build could not write the compiler cache; authorized execution outside the sandbox succeeded. No dependencies or deployment target changed.
- Added regression assertions first. The unmodified implementation failed to reload an external restoration of previously saved bytes; retained the conflict flag after Save As and rejected the next save; reused an image's old accessibility description; and changed marked-text attributes during composition. All four failures were observed before fixing them. Existing save-failure behavior was also tested and already preserved the saved baseline.
- Replaced historical-content suppression with comparison against the current persisted snapshot and rejection of reads whose baseline or file URL changed while suspended. Removed the 16-entry whole-file history. A successful Save As clears conflict; Save To leaves the original baseline unchanged. Added failed-save, export-then-save and externally-restored-content coverage. These tests invoke file-presenter callbacks directly, not OS-delivered coordinated changes.
- Recovery's synchronous quit writer now shares a lock and revision/date ordering gate with actor saves. Older pending writes and older selection-only records cannot replace a newer record in the same store. The synchronous path still avoids waiting for a main-actor task during AppKit termination. The new test deterministically checks write ordering; it is not a probabilistic process-kill race test.
- Paragraph presentation returns storage's original attributed substring when it intersects marked text. Tests compare attributes as well as characters and retain Korean composition/caret checks. Image labels are attached per request while CGImage pixels remain cached. Applying a parse retains artifacts only for unchanged full elements, so changing a distant image reference drops the old image even when its span is unchanged. Stale-revision and composition-time parse application are directly rejected in tests.
- Long-paragraph profiling by scaling revealed repeated full-line allocations and UTF-8 decoding in `SourceIndex.offset`. It now uses sparse scalar checkpoints, per-line byte starts and a bounded scan (at most 65 UTF-16 units). The parser no longer creates source substrings for AST nodes that do not use them. Tests independently decode every byte prefix, including invalid interiors, CR/LF/CRLF, combining marks, Hangul, emoji and U+2028/U+2029, including after 400 deterministic random edits. Source and AST serialization behavior did not change.
- **Release measurements:** Mac17,3, 24 GiB, macOS 27.0 (26A428), Xcode 27.0 (27A266a), Swift 6.4, arm64; OS cache state uncontrolled. Normal parser p50: 99,912 bytes **40.219 → 33.648 ms** (20 samples), 999,948 bytes **400.562 → 342.762 ms** (10), 9,999,894 bytes **4,106.253 → 3,534.830 ms** (3). Long single paragraphs: 15KB **130.182 → 6.749 ms**, 60KB **2,039.388 → 15.660 ms**, 240KB **32,533.939 → 62.585 ms** (5 each). At 240KB, 16,000 coordinate lookups fell from **5,397.623 → 1.657 ms** p50. Full before/after p50/p95 output is preserved under `Validation/2026-09-16-review/`; 10MB has too few samples for a robust tail claim. Extra index construction is a tradeoff: 1MB index-only p50 **4.058 → 4.475 ms**, included in the overall parse measurements.
- Final full Release Swift run: **43 tests passed** (31 editor/integration, 12 core). Earlier Debug run after the main fixes passed 41 tests; the final export and document-scale additions were validated in Release. Full-suite editor-only 1MB input: p50 **3.77 ms**, p95 **6.26 ms**, max **8.48 ms**. New NSDocument-backed input test includes source snapshot copying and dirty-state callbacks: 30 insertions each, head p50/p95 **3.59/4.00 ms**, middle **3.46/3.69 ms**, tail **3.53/3.84 ms**. These are synchronous method-call durations, not key-to-display latency, and do not establish an input-speed improvement. The original editor-only test does not include NSDocument's callback cost.
- After correcting the old ScaleTests p50/p95 rank selection, an isolated Release `--filter ScaleTests` run passed both tests: editor-only p50/p95/max **3.69/9.05/10.26 ms**; NSDocument-backed head **3.57/3.93/4.92 ms**, middle **3.47/3.78/3.81 ms**, tail **3.28/3.51/3.57 ms**. The editor-only run includes visible-window/viewport and rendered-artifact work, so these fixtures are not an A/B comparison with the document-backed test. The editor-only p95 exceeds the 4ms budget even on this host. This patch does not fix or explain that tail through profiling; whole-style rebasing remains a follow-up. Full-suite timings in the preceding bullet used the original editor-only percentile calculation; use this isolated run for its corrected percentiles.
- Fixed `Scripts/measure.sh` to propagate test failures, use nearest-rank percentiles, print document-backed measurements and stop labeling the first run as cold. `bash -n` passed. The full launch/RSS/idle script was not rerun; its prior measurements above are historical, not results of this patch.
- UI validation initially failed because the active Korean input method converted synthesized `Save` keystrokes to `ㄴㅁㅍㄷ`. A first test-harness attempt selected the backing ASCII layout, which returned `paramErr` because that layout was not selectable. The harness now requests the ASCII-capable keyboard **input source**, and restores the previous source at teardown. macOS also exposed the temporary input-source indicator as a dialog; it was identified by its `InputSource` button, and repeated clicks raced its disappearing accessibility element. The save test now stays on the keyboard and permits only that identified indicator; file-byte, error-sheet and other-dialog checks remain. After the focused save/relaunch test passed, the **final complete UI suite passed all 5 tests in a single Release run**, confirming input-source restoration across tests: `/tmp/airmark-review-complete-20260916.xcresult`. Inline math/quit 7.089 s; five saves/relaunch 13.581 s; dark appearance 11.879 s; showcase 15.354 s; keyboard format/undo/redo/Replace All 13.049 s. Earlier failing bundles remain in `/tmp/airmark-review-*.xcresult`; they are not reported as successes. UI tests do not constitute a manual visual or VoiceOver review.
- Detailed rationale, review findings and the staged follow-up plan are in `REVIEW.md`. Remaining limitations include per-edit linear style rebasing, editor-held artifacts outside the renderer's cache budget, long-container/adversarial-math scaling, WebKit timeout/process termination lifecycle coverage, real input-method/VoiceOver validation, macOS 26 execution, 10MB editor workflows and frame-time measurement. No performance-budget compliance or production-readiness claim is made.

## 2026-09-17 — Artifact history, Mermaid 11.17.2, large tables

Host and raw output: `Validation/2026-09-17-artifacts-mermaid-tables/` (Release, Mac17,3, macOS 27.0; not the PLAN.md reference machine).

- **Artifact history.** Metrics and resident pixels are separate sorted span lists in `ArtifactStore`; edits shift integers after the first affected entry and release takes from the two ends of the resident list. With 50,000 measured formulas, a tail keystroke in the editor went from 3.89 ms p50 to 0.13 ms (equal to no history) and release after a render from 2.06 ms p95 to 0.003 ms. Storing a render costs 0.04 ms at that size (sorted insert). A differential test against the previous dictionary store covers random operations. The synchronous scroll step with history measured about 1.5 ms slower in TextKit calls; the paragraph work matched and a busy-wait experiment attributed it to CPU state, so it was not changed and no scroll improvement is claimed. Full Release Swift suite: 98 tests passed.
- **Mermaid 11.17.2.** Updated from 11.12.0 (KaTeX stays 0.16.22; Mermaid bundles its own 0.16.47 for label math). A new `MermaidCorpusTests` corpus of 24 diagram types, 8 malformed and 13 adversarial sources was recorded on 11.12.0 first; all 45 outcomes are identical on 11.17.2, no injection executed, and the lifecycle suite prints the same outcomes. The bundle grew 2.72 → 3.73MB and the first render on a fresh page grew about 10ms for diagrams and formulas. `Scripts/licenses.py` now generates the JavaScript license file (it reproduced the old file exactly) and lists nested package copies. Full Release Swift suite: 102 tests passed; the Showcase UI test passed. Mermaid 12 is left for a separate change.
- **Tables.** `TableRenderer` measures with CoreText and draws with CoreGraphics in a detached task, into the same 16-bit float bitmap at the screen's scale and color space that AppKit produced. Row and column counts decide, before any cell is measured, the tables that must fail either limit. Main-thread stall for a 20,000-row table went from 327–345 ms to the benchmark's 2 ms floor, and for an 8.5MB table from 1,088 ms to 3 ms; displayable tables take about as long as before, off the main thread. An equivalence test against the previous AppKit code checks identical outcomes, messages, sizes, bytes and format for 15 tables at three settings; 12 are pixel-identical and the rest differ only by glyph antialiasing. It found two AppKit behaviors to reproduce (trailing whitespace in widths, natural alignment by locale). Right-to-left locales and multi-screen scale selection are unverified. Full Release and Debug Swift suites: 105 tests passed.

## 2026-09-17 — Running render cancellation, recovery writes

Host and raw output: `Validation/2026-09-17-render-cancel-recovery/` (Release, Mac17,3, macOS 27.0; not the PLAN.md reference machine).

- **Running renders whose callers left.** Measured first: an obsolete running diagram held the WebKit page until it finished, so the next diagram waited 342 ms after a cancelled 480-edge chain and 1,035 ms after a 490-edge crossing graph. Editing that graph while it rendered showed the new one after 2,270 ms. Replacing a page costs 125–135 ms. `WebRenderer` now abandons a running job, discarding its page, only when no caller waits for it, another job is queued, and it has run 150 ms. The next diagram then waits 250 ms in both cases, and editing the dense graph takes 1,490 ms. A 250-edge chain (about 200 ms) is now abandoned just before finishing, so the next diagram waits 234 ms instead of 140 ms. That regression is bounded by one page load and is recorded, not hidden. `RenderService` passes the shared entry's live waiter count, so a render another caller still waits for, or one rejoined after a keystroke, keeps running. Typing elsewhere during a render caused no page loads at 100 ms or 30 ms per keystroke. Queued cancellation is unchanged.
- **Recovery writes.** Measured first on a 9.54 MB document: every caret move or scroll followed by a 600 ms pause rewrote a 10.12 MB JSON record, taking 164 ms to encode the bridged source, and ten screens read 1.5 s apart wrote 101 MB. Idle wrote nothing. A record is now `<id>.json`, which holds the metadata and names the file with the source, plus `<id>.<token>.source` with raw UTF-8. A save with the same revision replaces only the JSON, so caret and scroll saves write about 4 KB in 0.3 ms, and the reading session writes 0.04 MB. An edit writes the 9.54 MB source in 17.5 ms. A new source is written before the JSON that names it, and old sources are removed after, so a crash leaves a complete record. Records with the source inline still load. The revision is now `DocumentSnapshot`'s version, not the editor's, because a document without an editor can read new bytes without an editor revision, and deduplicating on the editor's revision kept the stale source (a test fails with it). UI: the two typing tests failed because keys arrived through the Korean input method, and failed identically on the commit before these changes. Only the three non-typing UI tests, including quit and recovery, validated this run.


## 2026-09-17 — Parse pacing, parse application, render failures

Nothing in this session was built, run or measured. The work was done in a Linux container with no
Swift toolchain, no macOS SDK and no network route to one, while `AirMarkEditor` and `AirMarkRender`
require AppKit and WebKit. `Validation/2026-09-17-parse-latency/` records the reproduction commands
and what each change is expected to do; the before/after numbers and the test results still have to
be produced on the development host. Nothing below is a measured result.

- **Parse pacing.** A running parse still cannot be stopped, so one started while typing continues
  runs to the end and the parse of the final text waits behind it. `ScaleTests/typingSettleTimes`
  measures what that costs a reader: 15 keystrokes 80 ms apart, then the wait until the editor holds
  a parse of the final text, with the number of parses each burst started and how many were already
  stale. `MarkdownParsingWorker.parsePresentation` now also returns what the parse itself took, and
  the editor paces from it: the wait after a keystroke is `clamp(lastParseCost, 45 ms, 250 ms)` and
  changes may stay unparsed for `max(4 × lastParseCost, 150 ms)` before one parse starts anyway.
  At 100KB both are today's values. No parser change; block or incremental parsing stays the long
  answer.
- **Applying a parse.** `installParse` hashed the spans of every unchanged element into a set and
  invalidated every render element of both parses, so applying a parse cost as much as the document
  is long whether or not anything changed (about 49 ms on 50,000 formulas, recorded in
  `Validation/2026-09-17-artifacts-mermaid-tables/` and left alone then).
  `PresentationStore.elementDiff(comparedTo:)` replaces `unchangedElements`: one merge walk returns
  the spans that differ and the spans equal in both. Only the first are invalidated; artifacts and
  render failures are retained by the second through `SpanList.retainAll(in:)`, a merge of two sorted
  lists rather than a set. The randomized `PresentationStoreTests` now checks the diff against the
  set operations it replaces, and `ArtifactStoreDifferentialTests` keeps the hashing store as the
  reference for the merge.
- **Render failures per keystroke.** `errors` was a dictionary rebuilt in full on every keystroke,
  the shape the artifact store had before it moved to sorted span lists. It is now a
  `SpanList<RenderIssue>`, so an edit shifts the entries after it as integers and a parse drops the
  records of changed elements in one pass; a record is kept exactly when `PresentationEdit.unchanged`
  keeps its span, as before. `ScaleTests/renderFailureKeystrokeCosts` (50,000 formulas, all failed,
  against the same document with none) is the benchmark, and `EditorTests/renderFailuresFollowEdits`
  covers the move-and-drop rule without a renderer.

## 2026-09-17 — Parse pacing measured on the development host

Host and raw output: `Validation/2026-09-17-parse-latency/` (Release, Mac17,3, macOS 27.0; not the PLAN.md reference machine).

- **The pacing above, measured.** `ParsePacingBench` types into an on-screen document at 100KB, 1MB and 10MB: single keys after idle, 35 s at 200–400 ms gaps, 15-key bursts at 80 ms, and 35 s at 80 ms, three alternating runs against `main`. `clamp(lastParseCost, 45 ms, 250 ms)` made a single keystroke's parse land about 200 ms later at 1MB (386 → 584 ms p50) and 142 ms later at 10MB, made 1MB bursts settle later (505 → 583 ms), and left 1MB slow typing with no parse installed for 35 s (main installed 11–14). It helped only 10MB bursts (5.1 → 3.3 s). `max(4 × lastParseCost, 150 ms)` cut wasted parses (111 → 25 at 1MB) but every refresh it started was stale on arrival. Both are reverted to the fixed 45 ms and 150 ms; the worker's cost report and the parse counters stay. With them reverted, 1MB and 10MB runs match `main` in every scenario.
- **Stale presentation during typing is not a pacing problem.** On `main` and with either pacing, a parse that outlasts the gap between keys is dropped, so continuous 80 ms typing installed no parse until typing stopped: 35 s at 1MB and 10MB, and up to 5.8 s at 100KB, where the in-app parse and its application take about 67 ms after the wait.
- **Parse application and render failures, measured.** On 50,000 formulas, `previous_applyParse` fell from 47–54 ms to 23–25 ms, not to the size of the change, because the style and element diffs still walk the document. With 50,000 recorded failures, keystrokes fell from 8.0/6.5/5.1 ms to 2.8/1.3/0.12 ms at head/middle/tail, the same as the document without failures.
- Tests: `swift test -c release --disable-sandbox` passed (86 editor/integration, 38 core).
- **Stale parses installed.** Character edits are numbered and logged until the parse that saw them finishes; a stale parse's presentation is moved through the later edits off the main actor and installed, while `parsed` keeps waiting for a parse of the current text. While a parse runs, keystrokes schedule nothing and its completion starts the next. Against `main`, three runs each: the longest wait for a key during 35 s of 80 ms typing fell from 5.4 s to 117 ms at 100KB, 35.5 s to 629 ms at 1MB and 39.4 s to 6.3 s at 10MB; single keys after idle unchanged. Costs at 10MB: settling after typing took 5.4–5.5 s instead of 3.8–4.4 s (the final parse waits for the running one), and installing a parse delays the next key by up to 34 ms about every 3 s.
- **Cheaper parse.** Profiled a 10MB parse: per-item `NSRegularExpression` compilation (~28%), checkpoint search and scalar walks in `SourceIndex.offset`, and span work for text nodes. Fixed all three: 10MB parse 2.82 s → 1.65 s (1MB 274 → 166 ms), output byte-identical on the repository's Markdown and 4,000 generated documents. With it, single keys after idle land in 274 ms at 1MB and 2.0 s at 10MB, 35 s of 10MB typing waits at most 4.2 s for a key, and settling after it takes 3.0–3.9 s.
- Tests: `swift test -c release --disable-sandbox` passed at each commit (88 editor/integration and 38 core after the stale-parse tests were added). Not measured: key-to-pixel latency, IME input, UI tests.

## 2026-09-18 — Parse locality

- **Display math ends at a blank line.** `mathSpans` searched for a closing `$$` across paragraphs, so typing an opening `$$` paired it with the next formula's opener, however far, and flipped every later pairing until it was closed; a parse could not be confined to the edited blocks either. A line of only spaces and tabs (LF, CRLF or CR) now ends the search, as a paragraph break is an error inside TeX display math. Behaviour change: a `$$ … $$` containing a blank line is shown as source. `MathScannerTests` covers it explicitly and in the differential scanner test, whose reference follows the same rule; both fail with the rule removed.
- **Block-window reparse.** `MarkdownParser.reparse` parses only the top-level blocks an edit touched, with at least one unchanged block on each side, widened to blank lines between blocks, and accepts the result only when those margin blocks reparse to exactly their previous spans; otherwise the margins double, and past a quarter of the document (or 64KB) it declines. A document containing `]:` (a possible link reference definition) is always parsed whole. A parse now records its top-level block spans; swift-markdown gives no range to a paragraph that a GFM table directly below splits, and then the spans are empty and the document is parsed whole. `BlockReparseTests` compares the result with a whole parse after 18,000 random edit batches (fences, HTML, quotes, lists, setext, math, tables, CR/CRLF, Hangul, emoji); it failed under each of four mutations (no margin check, no blank-line widening, no reference guard, later edits ignored). On the repository's own Markdown with random typing, windows were a few hundred to a few thousand UTF-16 units and never differed from the whole parse; a long top-level list (DEV_LOG) is one block, so its window is the list.
- **Windowed parses in the editor.** `MarkdownParsingWorker` keeps its last parse and the edit number it was made at; the editor sends the logged edits since then, and the worker reparses the touched blocks when it can. When the drawn presentation came from that same parse, the editor compares only the elements inside the reported window and invalidates only the window, instead of diffing every style and element (about 25 ms of a 35 ms install at 10MB, measured with temporary timers). The worker also keeps the previous parse until the next one, so the editor's release of a document-sized parse is not the last one. `EditorTests/windowedParsesDrawWhatAWholeParseDraws` types with parses landing in between and checks that the drawn styles and `parsed` equal a whole parse; it failed when one logged edit was left out.
- **Measured.** Against `main` and against the cheaper whole parse (`8dba8b9`), three rotated Release runs each. A keystroke after a pause reaches the presentation in 51/56/93 ms at 100KB/1MB/10MB (`main`: 113/382/3,149 ms). During 35 s of typing 80 ms apart every key is parsed and installed — 438 of 438 at 100KB and 1MB, where `main` installed 33–46 and 1 — and the longest a key waited was 61 ms at 1MB and 101 ms at 10MB, against 35.6 s and 39.7 s on `main`. Typing 200–400 ms apart on 10MB waits 112 ms at worst instead of 39.4 s. Settling after a burst at 10MB is 75 ms instead of 5.1 s. The key gaps during typing are back to `main`'s 90 ms, so installing a windowed parse costs nothing a key can see. Raw output and the whole table: `Validation/2026-09-17-parse-latency/`.
- **What it costs.** A document with `]:` anywhere is parsed whole on every keystroke; recording block spans and scanning for `]:` then makes it about 6% slower than before this work (10MB keystroke 2,021 → 2,158 ms p50), of which the block spans were 61 ms of a 1,742 ms parse until they were taken from the walk (`fa5de7c`, 1,681 ms). A top-level list is one block, so editing in a long list reparses that list.

## 2026-09-18 — Recovery sessions, discard, table raster, live resize

Everything below landed on this branch on 2026-09-18, on top of the parse-locality work. It replaces an
earlier entry for the same changes that was written in a container with no toolchain and described code
that has since changed: the settle delay, the table's colour space and the launch's session scoping are
all different now, and all of it has since been built, run and measured.

Host: Mac17,3, arm64, macOS 27.0 (26A428), Xcode 27.0 (27A266a), Swift 6.4, idle machine. Raw output
under `Validation/2026-09-18-*/`. Each change below is problem, fix, and what was actually run.

### Restore the last session, not every session

A record says a document was open when AirMark stopped, not at which stop, and only that document
rewrites it. A session launched on a file from Finder restores nothing, so it left the session before it
with `.open`/`.quit` records untouched and every later launch reopened them. Records now carry
`sessionID` (one per store, one store per launch) and `order`; the newest record names the last session,
so no manifest. An excluded record still qualifies as the single most-recently-put-away document, so
nothing becomes unreachable. — 3 new tests fail on the old logic with 5 assertions; end to end,
`UITests.testRelaunchRestoresTheLastSessionAndNotTheOneBefore` restores two documents and leaves the
older session's alone.

### The closed record is durable, and the quit flag stays set

`close()` handed the `.closed` record to a detached Task, so closing and quitting straight after left
the record saying the document was open. It now goes through `saveImmediately`. Separately,
`isTerminating` was cleared by a Task on the next run-loop turn; measured that the flag is load-bearing
— with it never set, a real Cmd-Q leaves `.closed` — so it stays set for the whole quit and only the
`.terminateCancel` path clears it. — `closingWritesTheRecordBeforeItReturns` reads the JSON off disk
with no await and fails on the old code; `UITests.testQuitRestoresTheDocumentThatWasOpen` covers the
round trip. **The `isTerminating` race was never reproduced** (5/5 passes with the Task in place); that
change removes a dependence on scheduling, not an observed failure.

### Discarded changes are not offered back

Clicking Delete on an unsaved draft left a `.closed` record holding the discarded text, and the launch
fallback revived it. `close()` now asks whether the changes are being kept: a draft's record is removed,
a document with a file keeps a clean record of the file. Cancel needs no code. Probed first rather than
assumed: a document **with a file is never asked about** — `autosavesInPlace` writes the edit and closes
— so there is no Don't Save for a saved file; a draft is asked, and macOS labels the discard button
**Delete**. — 2 tests fail on the old `close()` with 7 assertions;
`UITests.testDiscardedDraftIsNotRestoredAfterRelaunch` fails on it with "the discarded draft came back".

### One table raster policy, named by the cache key

`drawTable` read the host screen's colour space and the process writing direction; the key carried
neither, so two windows at one scale on differently profiled screens shared an entry.
`TableRenderer.raster(for:)` is now the only place the policy lives and the key hashes what it reads:
the window's scale, a fixed sRGB, and the alignment. Fixing sRGB is safe and the test says why, measured
— a table draws neutral greys, and greys are byte-identical in sRGB and Display P3, so the test fails if
a table ever draws a saturated colour. — Dropping the scale from the key fails the cache test on 4
assertions, including a 1× window handed the 2× bitmap.

### A launch reads the records, not every document

`records()` loaded every source in full and `resolve` then ran on the main actor, reading each
document's file and comparing. Most comparisons decided nothing: a record written while the text was on
disk is not the only copy, and both answers open the file. `RecoveryMetadata` carries the source's
length, taken from the directory listing; `launchPlans` resolves inside the store actor. Release, p50 of
3, against the old decision written out in full:

| documents × size | old way | `launchPlans` | files read |
|---:|---:|---:|---:|
| 1 × 10 MB | 4.63 ms | **0.09 ms** | 0 |
| 8 × 10 MB | 37.86 ms | **0.43 ms** | 0 |
| 32 × 10 MB | 148.16 ms | **1.41 ms** | 0 |

The shape is the point: cost no longer follows document size (one document is 0.08 ms at 1 MB and
0.09 ms at 10 MB). Warm cache, which flatters the old numbers, not the new.

### A drag says when it is over

The editor armed a 150 ms wait while geometry moved and re-armed it whenever it woke during a drag, so a
drag was a poll and its end was noticed up to 150 ms late, on a number with no basis. Nothing is armed
during a drag now; `didEndLiveResize` adopts, 0.3 ms after the event. Geometry that reports no end is
still coalesced, and the measurement keeps it: adopting every layout pass turns a 21-step burst into 21
rounds of renders. The wait only has to outlast the gap between two displayed frames, so it is 50 ms.
Release, 12 elements, 21 steps: 0 renders for widths passed through, all 12 keeping their metrics, one
round starting 53.4 ms after the last step with pixels back at 58.8 ms, main thread held 0.75 ms per
step (0.95 ms worst, 16.4 ms over the drag).

### Tests and measurement

`RecoveryResizeTableBench` holds the Release numbers, gated on `AIRMARK_BENCH` and skipped in 0.001 s
without it. Nothing in it repeats the parse benchmarks. Table: a 40×5 miss is 12–14 ms, a hit 0.02 ms,
and 1×/2× stay two entries with the table on the same points and both bitmaps sRGB.

Suites at the time of these changes: Release 109 tests in 16 suites and 55 in 4 suites, Debug the same,
and the whole UI file passing in Release, 11 of 11, including both typing tests. The core count is 60
after the review fixes below; the UI state after them is in that entry.

### Not verified

- `view.inLiveResize == true` was uncovered here, and is covered since — see the live-resize entry
  below. XCUITest's own drag resizes nothing and a title-bar double click does not zoom; HID `CGEvent`s
  and the accessibility API failed only because the test runner was not trusted for Accessibility. The
  full-screen button resizes the window too, but terminating out of its space broke the next test, so
  that test was written, measured and removed.
- `Close → Don't Save` on a saved file cannot be reached while `autosavesInPlace` is true. The handling
  exists and is unit-tested against a programmatic close; no UI test opens that panel.
- The close panel's Save button is not driven from the UI: the app is sandboxed, so that panel is the
  system's powerbox. What Save leads to is asserted at the document level.
- `repeatedSavesPreserveBytesWithoutFalseConflicts` failed about one run in ten before this work. The
  cause was found — an autosave-in-place between the append and the assertion, which clears the dirty
  flag, caught by overriding `updateChangeCount(withToken:for:)` — and the assertion moved to before the
  first await, where no autosave can intervene. 640 append-and-save cycles since, with no failure.

## 2026-09-18 — Three fixes from review

`Validation/2026-09-18-review-fixes/`. Debug and Release, 109 tests in 16 suites and 60 in 4 suites.

- **An unreadable source size is not zero.** `metadata()` wrote `?? 0` when the listing could not size a
  source, and a zero-byte record is an empty one — no window, and nothing else holds a draft's text, so
  the draft was silently lost. An unknown size is now left out and the loader falls back: listing, stat,
  then the file. Only a source that cannot be read at all still drops the record. The stat failure is
  not injectable, so the tests cover the fallback and say so; this is a defensive fix.
- **Window order applied, not inherited.** The launch asked the last plan to come to the front and left
  the rest to whatever order the asynchronous opens completed in, though the session had recorded which
  window was in front. The opens still run together, each reporting into a main-actor collector, and
  when the last lands the windows are ordered back to front and the last made key. Verified end to end
  by restoring three documents and asserting the whole stacking: the old code gave
  `["Middle.md", "Front.md", "Back.md"]` in two runs of three, this change `["Front.md", "Middle.md",
  "Back.md"]` in five of five. The first version of that test used two documents and passed on the old
  code too, so it was rewritten until it could fail. It could not be run for a while — from 14:21 every
  UI run failed to activate the app, reproduced with `main.swift` reverted — and ran once the machine
  was attended to; a prompt waiting on the console is the likely cause, not observed from here.
- **Discard is one writer operation.** `discardRecovery` removed the record, ignored the result, then
  saved a replacement at the same revision — and the writer reuses the source it last wrote for a
  revision, so a failed remove left the discarded text on disk under a record claiming the file's.
  `discardImmediately(_:replacingWith:)` drops the record, drops its sources and writes the replacement
  fresh under one lock. The JSON goes first, the opposite of `save`'s order and for the opposite reason:
  it is the only thing that makes a source reachable, so an interrupted discard leaves nothing of what
  was discarded. Three tests; the two that matter fail on the old two-step path with the discarded text
  surviving.
- **Also.** `recordsNameTheSessionThatWroteThem` resolved a launch over every record in a recovery
  directory shared with the suites running alongside, so a neighbour's record could decide it. It failed
  that way once here and now resolves over its own two records.
- **UI tests after the fixes.** Release, the whole file: 7 of 11. The seven that type nothing pass,
  including the window-order test above. The four that type fail, and all four for one reason: the
  keystrokes arrive through the active Korean input method — `"DISCARD ME"` became `"얀ㅊㅁㄲㅇ 뜨"`,
  `"Save 1."` became `"ㄴㅁㅍㄷ 1."`. The machine was in use, with the third-party input method
  `com.pritype.inputmethod.v2` selected. `useASCIIInputSource()` does select `com.apple.keylayout.ABC`,
  and selecting it after focusing the editor instead of before made no difference, so it does not
  overcome this input method. The same four passed at 12:16 on an idle machine. Not a regression in
  this branch; run the typing tests with ABC selected.
- **Then 11 of 11.** Run at the console, Release, the whole file: 11 tests, 0 failures, including all
  four that type and the window-order test. That settles both the input-method diagnosis and the branch.

## 2026-09-18 — A real edge drag, and quitting without Cmd-Q

`Validation/2026-09-18-live-resize-ui/`, with captures.

- **`view.inLiveResize == true` is covered.** `testLiveResizeByDraggingTheWindowEdge` drags the window's
  right edge with HID mouse events, the ones a hand produces, from a frame pinned at 880 points through
  the argument domain — the window autosaves its frame, and a second run that started where the first
  one's drag left it had nothing left to drag. Three consecutive runs, 880 → 640, passing. Without
  Accessibility it skips rather than failing.
- **What the drag showed.** Text reflows during the drag and no rendered element falls back to its
  source. A diagram wider than the new width is not scaled while the drag lasts — the paragraphs are not
  rebuilt, so it keeps its old size and the window clips it — and is rendered for the final width once
  the mouse comes up. `ResizeTests` said elements were scaled during a drag; its fixture never met the
  case, and it now says what the real drag showed.
- **Quitting through the menu.** Three tests failed with "Cmd-Q did not quit the app", alone as well as
  in the suite, with no product change since they last passed. The recording showed the menu bar reading
  `한`: with the Korean input method selected, a synthesized Cmd-Q arrives as Cmd-ㅂ and matches no menu
  item. The two tests that pinned an ASCII input source first passed in the same run, which settles it.
  All five Cmd-Qs now go through a helper that clicks AirMark ▸ Quit AirMark — the same terminate path,
  independent of the layout — and the three pass with the Korean input method still selected.
- **UI, Release, the whole file:** 11 passed and the drag test skipped, because the rebuild that brought
  in the helper dropped the runner's grant; the drag test itself did not change in that rebuild. The
  runner is ad-hoc signed, so any change to the UI tests drops its Accessibility grant: remove the entry
  and add the new build, then run with `test-without-building`. Toggling the old entry is not enough.

## 2026-09-18 — Keystroke cost, re-measured

`Validation/2026-09-18-keystroke-cost/`, Release, commit `f8f1112`, three independent runs.

- **The per-keystroke target is met.** The last recorded 1MB editor-only cost was p95 9.05 ms against a
  target of 4 ms (2026-09-16 above). Measured again with the same tests: p95 **0.44–0.48 ms**, max
  2.06–2.44 ms. At 10MB with the document's snapshot and dirty state included, head p50 is 4.12–4.35 ms
  against a target of 8 ms; middle 2.2–2.9 ms, tail 0.12 ms. The worst single keystroke in any run is a
  space at 10MB, 7.32 ms — inside a 120 Hz frame, not by much.
- **Not attributed.** No commit between the two measurements was measured, so which change did this is
  not known; PR #1's rebase and presentation work is the likely one.
- **Not end to end.** These stop when `performEdit` returns. Input-to-screen latency and the time for
  formatting to catch up after typing are different measurements and were not taken here.


## 2026-09-19 — cmark's tree read directly, a flat edit shift, and a review

`Validation/2026-09-19-direct-cmark/`. Release, base `fd44d09` in a separate worktree, runs alternated.

- **A whole parse is five times cheaper.** Sampled at 10MB, cmark-gfm was 6% of a parse; swift-markdown
  converting cmark's tree into its own was 37%, and walking that tree 43%, mostly dynamic casts from
  `any Markup`. `MarkdownTree` reads cmark's nodes in place — same cmark-gfm 0.8.0, same options and
  extensions, same position adjustments as swift-markdown's `Document(parsing:)`. p50: 100KB 19.1 → 3.5 ms,
  1MB 193 → 35 ms, 10MB 1,959 → 374 ms, three alternating runs each. The two depth-256 adversarial corpora
  did not move (1.0–1.1×); their cost is marker matching over each nested container's text.
- **This keeps PLAN.md's rule and changes its letter.** PLAN.md leaves Markdown semantics to swift-markdown
  and rules out a parser of our own. Semantics are still decided by the cmark-gfm that swift-markdown wraps,
  at the version it pins; what was removed is the conversion layer. swift-markdown stays in the package as
  the core tests' reference and is no longer linked into the app.
- **Held to the old parser.** `ReferenceParser` is the previous `parse` word for word. 3,000 generated
  documents, 300 documents through 10 random edits each, and every Markdown file in the repository, native
  and bridged, produce identical styles, markers, elements, checkboxes and block spans. Dropping
  `CMARK_OPT_SMART` or the backtick widening fails these tests; dropping the end-before-start guard does
  not, and that guard is uncovered.
- **The benchmarks parsed text the app never sees.** They use native strings; the editor's text is bridged
  from `NSString`. At `fd44d09` 10MB parsed in 1,992 ms native and 2,222 ms bridged. The UTF-8 is now
  produced once per parse, in bulk, for the estimates, the `]:` scan and cmark; `AirMarkBench --bridged`
  measures both (10MB: 366 / 363 ms).
- **An edit's shift is flat.** Moving the styles after an edit went style by style and recomputed each
  reach from its markers; it is four passes over contiguous integers, and elements move through a
  specialized protocol instead of a key path. `--edits` 1MB head 75 → 16 ms per 200 edits, interleaved. In
  the editor at 10MB: head p50 4.12–4.35 → 1.19–1.20 ms, plain space max 7.32 → 4.80 ms, Return 2.05–2.19 →
  0.61–0.63 ms. The earlier figures are 2026-09-18's, not re-run today. Still linear in what follows the
  edit; not input-to-screen latency.
- **Review fixes.** `EditorController` never removed its five block observers, so each closed document left
  them registered, three listening to every window; removed in an `isolated deinit`, with a test that the
  editor deallocates. `insertNewline` compiled its expression and bridged the document three times per
  Return. `willProcessEditing` copied the replaced text only to count it. `fileLocationChanged` and
  `adoptEnvironment` used `parsed`'s stale coordinates while a parse was pending. A scroll step in a
  document with nothing to render still laid out screens of text to find render and release windows.
- **Tried and dropped.** Bulk-encoding `DocumentBytes.data` measured the same 13 ms for a bridged 10MB
  source as before; the cost is the transcoding. Reverted.
- **Tests.** Debug and Release: 110 tests in 16 suites and 64 in 5 suites. Release app build succeeded and
  has no swift-markdown symbols. UI tests not run: the runner timed out enabling automation mode before any
  test, which needs someone at the console.

## 2026-09-19 — A quit with an edit pending, and where a quit can be cancelled

`Validation/2026-09-19-quit-review/`. Debug, base `fd44d09` in a separate worktree.

- **The case left open was not there.** A probe app logging AppKit's order shows that every point where
  a quit can be called off, Cmd-Q or a logout Apple Event, comes before `applicationShouldTerminate`,
  and nothing after `.terminateNow` does. The documents of a clean quit close after
  `applicationWillTerminate`, not merely after the delegate.
- **A quit right after an edit lost the session.** With any document edited, AppKit reviews and closes
  every document, clean ones too, before the delegate. Each close wrote `.closed`, and the delegate found
  nothing to record. `testQuitRightAfterAnEditRecordsTheDocumentAsQuit` (Edit ▸ Paste, then quit through
  the menu, nothing typed) fails on the base with `closed`.
- **Fix.** `AirMarkDocumentController.reviewUnsavedDocuments` begins the quit, recording `.quit` and
  setting the flag before AppKit's review, and clears the flag when the review's `didReviewAll` answer
  says the quit was cancelled. That answer is the callback the earlier note said did not exist, and the
  quit now begins before a point that can cancel it. A close during a quit writes `.quit` again, keeping
  the window order taken when the quit began. An edited document at close is still discarded, which is
  what Delete in the review panel means.
- **Tests.** Three new UI tests pass. The Cancel test fails with the flag-clearing line removed. The
  existing quit and session tests and all five typing tests pass. The typing tests now run under PriType's
  English mode instead of ABC, because PriType is the only input method on the machine they run on. Unit:
  109 + 60. One batch run had `testCancelledCloseKeepsTheDraftAfterRelaunch` miss its sheet; it passed
  alone on base and fix and in a full rerun.
- **Not verified.** A real logout; the review panel's Save; Release.
