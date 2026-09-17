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

## 2. The closed record written before `close()` returns

### Problem

`MarkdownDocument.close()` built the `.closed` record and handed it to a detached
`Task { try? await store.save(saved) }`. Nothing waited for that Task. Closing a document and quitting
straight after — Cmd-W then Cmd-Q — could exit the process before it ran, leaving the record saying the
document was open. `applicationShouldTerminate` does not rewrite it either: it only writes records for
the documents still in `NSDocumentController.shared.documents`, and this one has left. The next launch
read a stale `.open` record and reopened a window the user had put away.

### Change

`close()` calls `store.saveImmediately(record(state: .closed))`, the same synchronous writer the quit
path uses, so the record is on disk before the method returns. The error is still swallowed: the window
is going away and there is nowhere to report it, which is what happened before.

The cancelled debounced save cannot undo it. If that Task was already suspended inside `store.save`,
its record carries this document's revision with an earlier date, and `RecoveryWriter`'s ordering gate
rejects a record that is not newer at the same revision.

### Result

`closingWritesTheRecordBeforeItReturns` reads `<id>.json` straight off disk with no await and no wait
after `close()` returns, so nothing the process does afterwards can be what wrote it, and then checks
that a launch with another document of the same session left open does not bring the closed one back.

| | before (`close-before.txt`) | after (`close-after.txt`) |
|---|---|---|
| `closingWritesTheRecordBeforeItReturns` | fails: `stored?["state"]` is `nil`, the file holds the earlier `.open` record | pass |
| `closingADocumentRecordsItAsClosed` (existing, polls up to 5 s) | pass | pass |

Before was produced by reverting only the write in `close()` to the detached Task.

Full suite after: 98 tests in 15 suites and 52 in 4 suites, all passing.

### One flake, not from this change

In one of five full-suite runs, `repeatedSavesPreserveBytesWithoutFalseConflicts` failed its first
`#expect(document.isDocumentEdited)`. That assertion follows a fixed 250 ms wait for the text view to
close its undo group, and the run was on a machine at load average 3.3 with the other suites running in
parallel. It passed in the three isolated `--filter DocumentTests` runs and in both full runs after,
and nothing in this change touches the edit, undo or change-count path. Recorded rather than dropped.
