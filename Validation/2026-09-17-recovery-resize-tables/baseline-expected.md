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
| `SourceTests.launchCapsRestoredSessionsKeepingUnsavedWorkFirst` | n/a before: one plan was always returned. |
| `SourceTests.launchTreatsRecordsWithoutAStateAsOpen` | Pins that records from older builds keep the previous behaviour. |
| `RecoveryStoreTests.recordsKeepTheirStateAndUnsavedFlag` | The two fields were not stored. |
| `DocumentTests.everyUnsavedDocumentOpenAtOnceIsRecovered` | Two documents edited at once produced one `.recoverDraft` plan; the test requires two. |
| `DocumentTests.closingADocumentRecordsItAsClosed` | `close()` wrote a record indistinguishable from one written while the document was open. |

Unchanged on purpose: a launch with a single record behaves exactly as before, including the
`.openFile` / `.recoverDraft` / `.openRecent` / `.newDocument` order, and Markdown source bytes are
untouched by all of this.

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
| `ResizeTests.changingTheFontSizeRemeasuresFromScratch` | Passes before and after; it pins that geometry is the only thing held over, and that a new font size, theme or background still measures from scratch. |
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
| `TableRenderTests.tableColorSpaceComesFromTheHostWindowsScreen` | Passes before and after on a single-screen machine; it pins where the value is read from and that the bitmap's scale is the environment's. |
| `TableRenderTests.matchesTheAppKitReference` | Kept, with the same corpus and the same three environments, but it now compares the two drawings inside one raster — the main screen's, which is what `NSImage` rasterized into — instead of routing one side through `RenderService`. Without that the test would compare a bitmap at the environment's scale with one at the screen's and fail for a reason that is the point of this change. |

Deliberately unchanged: cell text still aligns by the user's language direction
(`NSParagraphStyle.defaultWritingDirection`), not the host view's layout direction. That is the second
half of the unverified note above and is not what this task is about. Right-to-left locales remain
unverified, and so does an actual two-screen machine — which is the only place the first test's premise
can be observed rather than simulated by two scales.
