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

## 2026-09-17 — Multi-document recovery, live resize, table raster

Host: a Linux container with **no Swift toolchain and no macOS SDK**. Nothing in this entry was
compiled, run or measured. The three changes below are code and tests written against a reading of the
source at `cb8c3df`; `Validation/2026-09-17-recovery-resize-tables/` says, per test, which assertion the
previous code fails and why, and that is a claim about the code, not a result. Run the Swift and UI
suites on macOS before trusting any of it.

- **Multi-document recovery.** `LaunchPlan.resolve` took `records.first` and returned one plan, and the
  launch path opened that one. Several unsaved drafts open at once therefore left one recoverable and
  the rest in the recovery directory with nothing in the app that could reach them. `resolve` now
  returns one plan per document, in the order to open them, and `applicationDidFinishLaunching` opens
  all of them, bounded at eight, unsaved drafts first. A record also carries `state` — open, quit or
  closed — and `hasUnsavedChanges`. The two answer different questions: a launch restores the documents
  that were open when AirMark stopped, whether it stopped by quitting or crashing, and reopens the most
  recently closed one only when nothing was left open, which is what a single-record launch did. A file
  another app edited after a clean close now opens as a file instead of coming back as a dirty
  "Recovered —" draft. Records from older builds have neither field and read as open with work to
  recover, but a launch uses only the most recent of them and only when nothing was left open, which is
  exactly what a launch did with every record before — restoring them all would open a window for each
  of the tens of documents a long-standing recovery directory holds. Restored windows step down from
  each other rather than stacking exactly. There is no limit on how many documents a launch restores:
  a record left unrestored would be work with no way to reach it, and the same records would be left
  out at every later launch. Not addressed: records are still never removed, so one accumulates on disk
  per document identity ever opened, including empty untitled ones.
- **Live resize.** Any environment change, down to one point of width, cancelled every render, ran
  `artifacts.removeAll()` and invalidated every element, so a window drag replaced each rendered element
  with its Markdown source and back at every step and discarded the layout that scroll eviction keeps.
  The editor now measures and draws in the environment it last settled on; a geometry-only change arms
  a 150 ms wait that every further change restarts and that never fires during a live resize. When it
  fires, `ArtifactStore.holdGeometry` keeps what was measured as temporary geometry — each element keeps
  its attachment at its measured size, scaled into the width there is now, and its last pixels — until
  the new render replaces it. A changed font size, theme or background still measures from scratch. The
  150 ms comes from PLAN-2026-09-17 §W8; nothing here measured it, and no frame time or page-load count
  during a drag was measured either. One consequence to know: while the environment is unsettled no
  render starts at all, so an element scrolled into view or added by a parse during a long drag shows
  its source until 150 ms after the drag ends.
- **Table raster.** `drawTable` read the scale and color space from `NSScreen.main` while every other
  element followed the host window's backing scale through the render environment, so a window on a 1×
  display beside a Retina main display got its tables at 2× and everything else at 1×. The scale was
  also in the cache key without the bitmap following it. The raster is now `environment.scale`, which is
  that window's backing scale captured with the rest of the environment and keyed with it, and the color
  space of that window's screen; a window moving between screens reaches the editor through
  `NSWindow.didChangeBackingPropertiesNotification`. The equivalence test against the previous AppKit
  drawing is kept with the same corpus, but it now compares the two drawings inside one raster instead
  of also deciding which raster is right — following the window matters more than reproducing the old
  bitmap. Two consequences on a multi-screen setup, neither tested: the set of tables rejected as too
  large moves in both directions, because the cost check and the display limit now use the same scale;
  and a move between two screens of the same scale but different color profiles does not re-render,
  because `RenderEnvironment` carries no color space — the bitmap is tagged, so it is converted rather
  than shown wrong. Still unverified, and unverifiable here: a real two-screen machine, and
  right-to-left locales, where cell text continues to align by the user's language direction rather
  than the host view's.

### Review of the three changes above

A review agent read the branch diff against `main` in the same container, so it could not compile it
either; it traced every changed expression by hand and found no compile error. It found four real
defects in the launch logic, which are fixed in the commits that follow, and four inaccurate statements
in the documents written alongside, which are corrected:

- Records from older builds decoded as open with unsaved work, and every non-closed record was
  restored, so the first launch after an upgrade would have opened a window for each of the tens of
  records a long-standing recovery directory holds — most of them documents put away weeks ago, shown
  as dirty "Recovered —" drafts. They now decode as `.unknown` and only the most recent is used.
- A record whose file is gone was dropped when nothing was marked unsaved. An unmounted volume is
  enough to reach that state, and the record is then the only copy the app can reach. It comes back as
  a draft again, as before.
- The eight-window cap stranded drafts 9 and beyond permanently — the same defect the first commit
  claims to fix, at a higher threshold. The cap is gone.
- `isTerminating` was never cleared if a quit was vetoed after `applicationShouldTerminate` returned,
  after which no closed document would ever be recorded again. It is cleared on the next turn of the
  run loop, which a real quit never reaches.
- Bringing the newest document to the front looked it up by identity, which a document opened from a
  file does not have yet at that point, so it silently did nothing for exactly the common case. The
  plan that belongs in front now asks for it where its window is made.
- The `didEndLiveResize` observer restarted the 150 ms wait instead of ending it, and the re-arming
  wait already notices the end of a drag on its own. Removed.
- Corrected in `Validation/2026-09-17-recovery-resize-tables/`: a false claim that single-record
  launches behave exactly as before (three cases do not, now listed), a test described as passing
  before the change that does not compile before it, a `--filter` argument that matches no test, and a
  comment claiming windows restore a remembered frame, which nothing in that method does.
