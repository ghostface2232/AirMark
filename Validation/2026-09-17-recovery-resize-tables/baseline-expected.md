# What each new test asserts, and what the previous code did

Read from the source at `cb8c3df`. Not an observed run — see README.md.

## Task 1 — multi-document recovery

`LaunchPlan.resolve` took `records.first` and returned one plan
(`Sources/AirMarkCore/LaunchPlan.swift` at `cb8c3df`), and `applicationDidFinishLaunching` switched on
that one plan. Every other record stayed in the recovery directory with no way to reach it. A record
carried no state, so a document closed cleanly and a draft a crash left behind were told apart only by
comparing the record's source with the file on disk, which also reports a file another app edited.

| Test | Assertion that fails before the change |
|---|---|
| `SourceTests.launchRestoresEveryDocumentThatWasOpen` | `resolve` returned `LaunchPlan`, not `[LaunchPlan]`: the test does not compile against the old signature, and the behaviour it pins (three open documents, three plans) was one plan. |
| `SourceTests.launchSkipsClosedDocumentsUnlessNothingWasOpen` | `RecoveryState` did not exist. |
| `SourceTests.launchSeparatesUnsavedWorkFromAnExternallyChangedFile` | `RecoveryRecord.hasUnsavedChanges` did not exist; a cleanly closed record whose file changed externally resolved to `.recoverDraft`, i.e. a window titled "Recovered — …" marked dirty. |
| `SourceTests.launchRestoresEveryOpenDocumentWithoutALimit` | n/a before: one plan was always returned. |
| `SourceTests.launchUsesOnlyTheNewestRecordWrittenBeforeStatesExisted` | Pins that a directory of records from older builds still opens one window, not one per record. |
| `RecoveryStoreTests.recordsKeepTheirStateAndUnsavedFlag` | The two fields were not stored. |
| `DocumentTests.everyUnsavedDocumentOpenAtOnceIsRecovered` | Two documents edited at once produced one `.recoverDraft` plan; the test requires two. |
| `DocumentTests.closingADocumentRecordsItAsClosed` | `close()` wrote a record indistinguishable from one written while the document was open. |

`hasUnsavedChanges` is `NSDocument.isDocumentEdited`, read on the main actor where the record is built.
Comparing the source with `snapshot.persistedData()` would answer the same question exactly, but it
encodes the whole document on every record — including the caret-move and scroll records that `cb8c3df`
had just made cost about 4 KB and 0.3 ms on a 9.5 MB document. Nothing here measured either, so the
cheap one that AppKit already maintains is the one used.

Markdown source bytes are untouched by all of this. A launch with a single record behaves as before in
the cases that matter — the file still on disk opens with its position, a record holding text that is on
no disk comes back as a draft — but three single-record cases do change, and none of them is covered by
a test that would have caught the divergence:

- `filePath == nil` with an empty source: before, `.recoverDraft` of an empty draft (an empty window);
  now the record yields no plan, so the launch falls through to the most recent file or a blank note.
- `filePath` set, file gone, empty source, with a recent file: before, an explicit `.newDocument`
  branch; now `.openRecent`. The old `.newDocument`-from-a-record case is unreachable.
  `launchPlanPrefersRecoveryThenRecent` only exercises this with an empty recent list, which hides it.
- A record written by a clean close or quit whose file has since been changed by another app: before,
  `.recoverDraft`; now `.openFile`. That one is the point of `hasUnsavedChanges`, not an accident.

A file that is *gone* was briefly in this list too. It is not any more: the record is then the only copy
of that text the app can reach — the volume may simply be unmounted — so it comes back as a draft
exactly as before. There is no cap on how many documents a launch restores, because a record left
unrestored is work with no way to reach it, and the same records would be left out at every later
launch.

## Task 2 — live resize

`scheduleRenders` compared the live environment with `renderEnvironment`, and any difference —
including one point of width — cancelled every render task and ran `artifacts.removeAll()`,
`errors.removeAll()` and an invalidation of every element
(`Sources/AirMarkEditor/EditorController.swift` at `cb8c3df`). Paragraph building then found no metrics
for the element and laid out its Markdown source instead, so a window drag alternated between the
rendered element and its source at every step, and the layout that scroll eviction was careful to keep
was thrown away here. Renders were also started for every intermediate width and discarded by the next
step.

| Test | Assertion that fails before the change |
|---|---|
| `ResizeTests.draggingAWindowKeepsRenderedElementsInPlace` | At the first width step `measuredElementCount` was 0, `renderedElementCount` was 0 and the paragraph carried no `.attachment`. Each step also raised `renderRequestCount`, so `renderRequestCount == requests` fails as well. |
| `ResizeTests.changingTheFontSizeRemeasuresFromScratch` | Does not compile before — it reads `heldGeometryCount`, which this branch adds. It is a guard test, not a reproduction: it pins that geometry is the only thing held over, and that a new font size, theme or background still measures from scratch. |
| `ArtifactResidencyTests.heldGeometryStandsInUntilTheElementIsMeasuredAgain` | `ArtifactStore.holdGeometry` did not exist. |
| `ArtifactResidencyTests.metricsBelongToTheirEnvironment` | Unchanged, and still passes: metrics are matched to their environment until the store is told to hold what it has. |

Not measured: the frame time of a drag, the number of WebKit page loads during one, and whether 150 ms
is the right settling delay. The delay was taken from PLAN-2026-09-17 §W8; nothing here measured it.

## Task 3 — table raster

`RenderService.drawTable` read the raster scale and color space from `NSScreen.main`
(`Sources/AirMarkRender/RenderService.swift` at `cb8c3df`), while every other element on the page —
images, formulas, diagrams — followed `environment.scale`, which is the host window's backing scale.
A window on a 1× display beside a Retina main display therefore got its tables at 2× and everything
else at 1×, and the reverse in the other direction. The 2026-09-17 entry in DEV_LOG.md says as much:
"Right-to-left locales and multi-screen scale selection are unverified."

Worse, the scale went into the cache key while the bitmap it produced did not follow it, so a table
cached under a 1× key could hold 2× pixels.

| Test | Assertion that fails before the change |
|---|---|
| `TableRenderTests.tableRasterFollowsTheRequestingWindow` | Both scales rasterized at the main screen's, so the two bitmaps had the same pixel dimensions. On a 2× host `one.image.width == ceil(one.size.width)` fails; on a 1× host the 3× assertion fails. Either way the previous code cannot pass it. |
| `TableRenderTests.tableColorSpaceComesFromTheHostWindowsScreen` | Passes before and after on a single-screen machine, where the host window's screen is `NSScreen.main`; it pins where the value is read from and that the bitmap's scale is the environment's. It uses no new API, so it does compile against the previous code. |
| `TableRenderTests.matchesTheAppKitReference` | Kept, with the same corpus and the same three environments, but it now compares the two drawings inside one raster — the main screen's, which is what `NSImage` rasterized into — instead of routing one side through `RenderService`. Without that the test would compare a bitmap at the environment's scale with one at the screen's and fail for a reason that is the point of this change. |

One user-visible consequence is untested and worth knowing: `TableRenderer.cost` uses the raster scale
while the display limit uses `environment.scale`, and those were different numbers on a multi-screen
setup and are now the same. So the set of tables rejected with "Table is too large to render." or "This
image is too large to display." moves in both directions there — a 2× window beside a 1× main display
now rejects some tables it used to draw, and a 1× window beside a 2× main display draws some it used to
reject. Both are the correct answer for the bitmap actually produced, which is the point of the change,
and the messages are unchanged; but no test covers it and it cannot be observed on one screen.

Deliberately unchanged: cell text still aligns by the user's language direction
(`NSParagraphStyle.defaultWritingDirection`), not the host view's layout direction. That is the second
half of the unverified note above and is not what this task is about. Right-to-left locales remain
unverified, and so does an actual two-screen machine — which is the only place the first test's premise
can be observed rather than simulated by two scales.
