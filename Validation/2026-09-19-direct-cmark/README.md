# Reading cmark's tree directly, and a flat edit shift

Mac17,3, arm64, macOS 27.0, Swift 6.4. Release builds. Base is `fd44d09`, built in a separate worktree;
`base` and `new` ran alternately (base, new, base, new, base, new), one process per run, load average
about 3. OS cache state uncontrolled. Observations on this machine, not PLAN.md budget certifications.

## Where a whole parse went

`sample` on `AirMarkBench` at `fd44d09`, 2,107 samples inside `MarkdownParser.parse` on the 10MB fixture:

| | samples | share |
|---|---|---|
| cmark-gfm itself (`S_parser_feed`, `cmark_parser_finish`, `cmark_node_free`) | 132 | 6% |
| swift-markdown converting cmark's tree into its own (`convertAnyElement`) | 779 | 37% |
| `walk` over the converted tree | 896 | 43% |
| index, nesting estimates, math, sort | 300 | 14% |

The top of the stack inside `walk` was `tryCast` and `__swift_instantiateConcreteTypeFromMangledName`:
every `node is Strong`, `node as? Paragraph` and `case let heading as Heading` on an `any Markup` is a
dynamic cast, about fifteen per node, plus a protocol conformance lookup for `node is BlockMarkup`, plus a
wrapper made per child visited. The parser that decides what the Markdown means was 6% of the parse.

`MarkdownTree` reads type, positions and strings from cmark's nodes in place. Same cmark-gfm (swift-cmark
0.8.0, the version swift-markdown 0.8.0 resolves), same options (`CMARK_OPT_TABLE_SPANS | CMARK_OPT_SMART |
CMARK_OPT_SOURCEPOS`), same extensions (table, strikethrough, tasklist), same position adjustments (end
column + 1, code spans widened by their backticks, an end before its start is no position). No Markdown
semantics moved into AirMark. swift-markdown is now linked only into `AirMarkCoreTests`; the Release app
binary has no `MarkupParser` symbols.

## Whole parse, p50 ms (`AirMarkBench`, three runs each)

| fixture | base | new | |
|---|---|---|---|
| 100KB | 19.19 / 19.10 / 19.05 | 3.99 / 3.46 / 3.45 | 5.5× |
| 1MB | 191.8 / 193.0 / 193.9 | 35.2 / 35.0 / 35.7 | 5.4× |
| 10MB | 1,944 / 1,959 / 1,985 | 373 / 374 / 381 | 5.2× |

`--adversarial`, largest size of each corpus, median of three runs:

| corpus | base | new | |
|---|---|---|---|
| normal | 192.3 | 35.4 | 5.4× |
| long-quote | 188.0 | 31.4 | 6.0× |
| nested-containers | 452.6 | 110.0 | 4.1× |
| long-list | 295.6 | 50.9 | 5.8× |
| unclosed-display | 229.4 | 40.8 | 5.6× |
| currency-lines | 12.8 | 6.7 | 1.9× |
| escaped-dollars | 20.8 | 17.5 | 1.2× |
| nested-list-depth-256 | 166.9 | 148.9 | 1.1× |
| nested-quote-depth-256 | 577.9 | 552.9 | 1.0× |
| long single line, 240KB (`--long-lines`) | 50.6 | 9.4 | 5.4× |

The two depth-256 corpora did not move: there every block quote and list item copies its own source text
and matches its markers over it, which is quadratic in the depth (bounded by `nestingLimit`) and was never
in the tree conversion. Not changed here.

## The text the app parses is bridged

Every figure above, and every figure recorded before today, parses a native Swift string. The editor's
text is bridged from the text storage's `NSString`, which has no UTF-8 to point at. Measured at `fd44d09`
with a probe (not kept): 10MB parsed in 1,992 ms native and 2,222 ms bridged; the two nesting estimates
alone were 20 ms native and 46 ms bridged, each copying the document's UTF-8 into an array through the
bridge. `String.withUTF8Bytes` now points at a native string's bytes and has Foundation transcode a bridged
one in bulk (about 14 ms for 10MB; making the string native through the standard library took 85–105 ms),
once per parse, for the estimates, the `]:` scan and cmark together. `SourceIndex` takes its UTF-16 with one
`getCharacters`, and the math scanner reuses that array instead of making a second one.
`AirMarkBench --bridged` keeps the comparison: 1MB 36.9 native / 36.5 bridged, 10MB 366 / 363.

## Moving the presentation with an edit

`PresentationStore.apply` visited each style after the edit in turn: its start, its end, its markers one by
one, then recomputed its reach from its markers. Everything after an edit moves by the same delta — starts,
live ends, every marker, and so every leaf of the reach tree — so it is now four flat passes over contiguous
integers. Elements and checkboxes were moved through a `WritableKeyPath`, one unspecialized access per
element; they go through a small protocol the compiler specializes.

`AirMarkBench --edits`, 200 single-character insertions, 1MB, three runs:

| | base | new |
|---|---|---|
| normal, head | 76.1 / 75.3 / 74.1 | 16.2 / 16.2 / 16.4 |
| normal, middle | 37.9 / 38.0 / 36.8 | 8.2 / 8.1 / 8.2 |
| normal, tail | 0.075 / 0.074 / 0.072 | 0.031 / 0.032 / 0.031 |
| long-quote, head | 56.2 (run 2) | 18.1 (run 2) |

In the editor (`scale-release.txt`, `AIRMARK_SCALE_10MB=1 swift test -c release --filter ScaleTests`, three
runs; base figures are `Validation/2026-09-18-keystroke-cost`, the same tests at `f8f1112`):

| 10MB, p50 ms | 2026-09-18 | now |
|---|---|---|
| NSDocument head | 4.32 / 4.12 / 4.35 | 1.19 / 1.19 / 1.20 |
| NSDocument middle | 2.94 / 2.22 / 2.26 | 0.61 / 0.62 / 0.62 |
| NSDocument tail | 0.12 / 0.12 / 0.12 | 0.12 / 0.12 / 0.12 |
| space, plain (max) | 2.69 / 2.58 / 2.58 (6.83 / 6.87 / 7.32) | 1.18 / 1.15 / 1.14 (4.67 / 4.68 / 4.80) |
| return, LF | 2.19 / 2.08 / 2.05 | 0.62 / 0.63 / 0.61 |

Still linear in what follows the edit; the constant is what changed. These stop when `performEdit` returns
and are not input-to-screen latency. The 2026-09-18 figures were not re-run today, so the comparison is
across two days on the same machine, not interleaved; the `--edits` rows above are interleaved.

## How the new parser is held to the old one

`Tests/AirMarkCoreTests/ReferenceParser.swift` is the previous `parse`, word for word, on swift-markdown;
both end in the same `MarkdownParser.finish`. `ParserDifferentialTests` compares styles with markers,
elements with content and labels, checkboxes, block spans and the reference flag:

- 3,000 generated documents weighted towards what the walk reads — nested and adjacent inline runs, every
  link and image form, smart punctuation, tables with inline cells, tasks, fence info strings, continuation
  lines indented by spaces, tabs and quote markers, CRLF and CR, Hangul, emoji, combining marks, a BOM, a NUL
  (over 100,000 styles and 10,000 elements; the test asserts those floors);
- 300 documents from the block-structure generator through 10 random edits each, for half-typed syntax;
- every Markdown file in the repository, native and bridged.

Mutations checked: without `CMARK_OPT_SMART`, and without the backtick widening, the generated, edited and
repository tests fail. Without the end-before-start guard nothing fails, because the offset lookup rejects
such a range anyway; the guard stays for fidelity and is not covered.

The nodes point into cmark's tree, which Swift would free after its last use — the expression that starts
the walk. `withExtendedLifetime` holds it for the walk; `resultsOutliveTheTree` checks nothing returned
points into it.

## Also fixed

- **Observers never removed.** `EditorController` registered five block observers and removed none. A block
  observer stays registered whatever becomes of what it captured weakly, so every closed document left five
  behind, three of them called for every window notification in the app. Removed in an `isolated deinit`;
  `releasedEditorDeallocates` checks the editor goes away.
- **A regular expression compiled per Return**, and the whole document bridged three times per Return
  (`string as NSString`), in `insertNewline`. Compiled once; reads the storage's own string.
- **The replaced text copied to count it.** `willProcessEditing` copied `editedRange` out of the storage to
  build a `PresentationEdit` that keeps only its length — a copy of the whole document on every load, revert
  and large paste.
- **Stale coordinates.** `fileLocationChanged` and `adoptEnvironment` took element spans from `parsed`, which
  is in the last parse's coordinates; with a parse pending (Save As or a resize while typing) the spans after
  the edit missed. They come from the presentation, which moves with every edit.
- **Scroll work in prose.** Every scroll step laid out one and three screens around the viewport to find
  render windows, and another to find what to release, in documents with nothing to render and under budget.
  Both are skipped when there are no elements, and the release range is not computed under budget.

## Tests

`swift test --disable-sandbox` and `swift test -c release --disable-sandbox`: 110 tests in 16 suites and 64
in 5 suites, both configurations. `bash Scripts/build.sh Release` succeeded. UI tests were not run: the
runner stopped at "Timed out while enabling automation mode", before any test, which needs someone at the
console. Not a result about this change either way.

## Not done, and measured

- `DocumentBytes.data` on a bridged source takes 13 ms for 10MB on the main thread at each save. Encoding in
  bulk through Foundation measured the same 13 ms — it is the transcoding, not the appending — so that
  change was dropped rather than kept as an improvement it was not.
- After deleting half of a 1MB document, a style query near the deletion costs 28 µs and grows with the
  document (`after-delete-query2000`, exponent 0.99, same on base): tombstones collapse onto the deletion
  point and every one reaches it. It lasts until the next parse replaces the store.
- A document that may define link references is still parsed whole on every keystroke; that parse is now
  five times cheaper (10MB: about 2.2 s → 0.37 s), not gone.
