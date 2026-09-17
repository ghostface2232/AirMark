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
