# Recovery sessions, close durability, termination flag

Host: Mac17,3, arm64, macOS 27.0 (26A428), Xcode 27.0 (27A266a), Swift 6.4. Debug `swift test`
unless stated otherwise. These are observations on this machine, not PLAN.md budget certifications.

PR #2 was merged onto `main` after PR #1 had landed (`fb3f8ab`); `merge-baseline.txt` is the full
suite immediately after that merge and before any change here. It is the baseline all three tasks
are measured against: 96 editor tests in 15 suites pass, 50 core tests in 4 suites run with
`launchUsesOnlyTheNewestRecordWrittenBeforeStatesExisted` failing on 3 assertions. That failure came
in with PR #2 and is fixed first, in its own commit, so the rest has a clean baseline.

## 0. The legacy launch record the test never built

`RecoveryRecord.init` defaults `state` to `.open` — the state a running document records. `.unknown`
is produced by `RecoveryWriter.load` when the stored JSON has no `state` field. The test's `legacy`
helper used the default and then asserted the result was `.unknown`, so it failed on that line and on
the two after it, which compared a plan for twenty `.open` records against a plan for one.

The helper now states `.unknown`. No production code changed. The decode itself is covered by
`RecoveryStoreTests.recordsKeepTheirStateAndUnsavedFlag`, which writes such a file and reads it back.

- Before: 3 issues in that test (`merge-baseline.txt`).
- After: `swift test --disable-sandbox --filter launch` — 7 tests, all pass.

## 1. Recovery session identification

### Problem

`state` says a document was open when AirMark stopped. It does not say at which stop, and a record is
rewritten only by the document it belongs to. A session that restored nothing — one launched on a file
from Finder, where `applicationDidFinishLaunching` returns early at `guard !openedFile` — left the
session before it with `.open` and `.quit` records that nothing had touched. Every later launch read
them as "was open when AirMark stopped" and opened a window for each, again and again.

### Change

`RecoveryRecord` carries `sessionID` and `order`. `RecoveryStore` makes one `sessionID` per instance,
and one store is made per launch, so every record a run writes names that run. No manifest file: the
newest record belongs to the last session and therefore names it, which is the same date ordering the
"most recently put away document" fallback already trusted. `LaunchPlan.resolve` takes the last
session from `records.first?.sessionID` and restores only `.open`/`.quit` records belonging to it.

A record excluded that way is not dropped. It joins the closed records as a candidate for the single
most recently put away document, so no work becomes unreachable — which is the property the
no-limit restore in PR #2 existed to protect.

`order` is the document's index in `NSApplication.shared.orderedDocuments`, front first, recorded with
every record rather than only at the quit. `resolve` sorts the session's records by it and reverses,
so the document that was in front is opened last, whichever document happened to write its record
last. Records without an order — a document with no window in the order, or a build that did not
record one — keep the newest-first order the store returns, which is what decided the front before.

Records written before either field read as nil, and a directory holding only those is read whole, as
it was before. That is deliberate: those records cannot be assigned to a session after the fact, and
treating them as an older session would drop work that the previous build would have restored.

### Result

New tests, run against the merged code with only `LaunchPlan.resolve`'s body reverted to the
pre-change logic (the record fields kept, so the tests compile) — `session-before.txt`:

| test | before | after |
|---|---|---|
| `launchRestoresOnlyTheLastSessionsDocuments` | 2 issues | pass |
| `launchRestoresTheSessionsWindowOrder` | 2 issues | pass |
| `recordsNameTheSessionThatWroteThem` | 1 issue | pass |

Full suite after (`session-after.txt`): 97 tests in 15 suites and 52 tests in 4 suites, all passing.
Baseline was 96 + 50 with 3 issues.

### Not verified

The scenario that motivates this — launch, Finder-open a file, quit, launch again — is a
multi-launch sequence. It is covered at the level of `LaunchPlan.resolve` and of records read back
through a real `RecoveryStore`, not by launching the app twice. `order` is asserted from constructed
records; that `NSApplication.shared.orderedDocuments` reports the window stacking a user sees is
taken from AppKit, not measured here. In the unit tests documents are not registered with
`NSDocumentController`, so their records carry no order and exercise the nil path.
