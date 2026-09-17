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
