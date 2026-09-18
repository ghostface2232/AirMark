# Recovery sessions, close durability, termination flag

Mac17,3, arm64, macOS 27.0 (26A428), Xcode 27.0 (27A266a), Swift 6.4. Debug `swift test` unless said
otherwise. Baseline is the merge of PR #2 onto main (`merge-baseline.txt`): 96 editor tests in 15
suites pass, 50 core tests in 4 run with one failing.

## 0. PR #2's own failing test

**Problem.** `launchUsesOnlyTheNewestRecordWrittenBeforeStatesExisted` failed on its first assertion.
Its helper used `RecoveryRecord.init`'s default `state`, which is `.open`; `.unknown` comes from
decoding JSON with no `state` field. The two assertions after it then compared a plan for twenty
`.open` records against a plan for one.

**Fix.** The helper states `.unknown`. Test-only; the decode itself is covered by
`RecoveryStoreTests.recordsKeepTheirStateAndUnsavedFlag`.

**Before → after.** 3 issues → `--filter launch` passes all 7.

## 1. Restore the last session, not every session

**Problem.** `state` says a document was open when AirMark stopped, not at which stop, and only that
document rewrites its record. A session launched on a file from Finder returns early at
`guard !openedFile` and restores nothing, so it left the session before it with `.open`/`.quit` records
nothing had touched — and every later launch opened a window for each, again and again.

**Fix.** A record carries `sessionID` (one per `RecoveryStore`, one store per launch) and `order`. No
manifest: the newest record belongs to the last session and so names it, which is the date ordering the
"most recently put away" fallback already trusted. An excluded record is not dropped — it joins the
closed records as a candidate for that single fallback, so no work becomes unreachable. `order` is the
document's place in `NSApplication.shared.orderedDocuments`, so the window that was in front comes back
in front whichever document wrote its record last.

**Verified.** Three new tests, run against the merged code with only `resolve`'s body reverted
(`session-before.txt`), so the record fields stay and the tests compile.

**Before → after.**

| test | before | after |
|---|---|---|
| `launchRestoresOnlyTheLastSessionsDocuments` | 2 issues | pass |
| `launchRestoresTheSessionsWindowOrder` | 2 issues | pass |
| `recordsNameTheSessionThatWroteThem` | 1 issue | pass |

Full suite after (`session-after.txt`): 97 + 52 passing, against 96 + 50-with-3-issues.

**Not verified.** The multi-launch sequence behind this is covered at `resolve` and through a real
`RecoveryStore`, not by launching the app twice — `Validation/2026-09-18-recovery-resize-table-bench/`
later covers it end to end. That `orderedDocuments` reports the stacking a user sees is taken from
AppKit, not measured.

## 2. The closed record is on disk before `close()` returns

**Problem.** `close()` handed the `.closed` record to a detached Task nothing waited for. Closing a
document and quitting straight after could exit before it ran, leaving a record saying the document was
open; the quit does not cover it, because it writes records only for documents still in the document
controller. The next launch reopened a window the user had put away.

**Fix.** `saveImmediately`, the synchronous writer the quit path already uses. A debounced save already
suspended in `store.save` cannot undo it: same revision, earlier date, which the writer's ordering gate
rejects.

**Verified.** `closingWritesTheRecordBeforeItReturns` reads `<id>.json` straight off disk with no await
after `close()` returns, then checks a launch with another document of the same session left open does
not bring the closed one back. Before was produced by reverting only that write.

**Before → after.** Fails (`stored["state"]` is nil, the file holds the earlier `.open` record) → passes.
Full suite: 98 + 52.

## 3. `isTerminating` stays set for the whole quit

**Problem.** The quit set the flag and enqueued a main-actor Task to clear it on the next run-loop turn.
The flag is what stops the closes AppKit performs around the quit from writing `.closed` over the
`.quit` records just written, so whether a session survived came down to which ran first.

**Measured that the flag is load-bearing.** With it never set, a real Cmd-Q leaves a `.closed` record
(`quit-without-the-flag.txt`) — so AppKit does close the documents after `applicationShouldTerminate`
returns and before the process exits.

**Fix.** The Task is gone; only the `.terminateCancel` path clears the flag. A logout cancelled after
this method returns leaves it set on a process that keeps running, and a document closed then comes back
next launch — a window to close again, against a session that never returns. No AppKit callback reports
that cancellation, so it is left and written down.

**Before → after.**

| | before | after |
|---|---|---|
| quit UI test, flag never set | fails, record is `closed` | — |
| quit UI test, clearing Task present | passes 5/5 (`quit-with-autoclear.txt`) | — |
| quit UI test, Task removed | — | passes, Debug and Release |
| `closeDuringTerminationKeepsTheQuitRecord` | — | pass |

**The race was not reproduced.** With the Task in place the quit test passed all five runs. This removes
a dependence on scheduling, not an observed failure. What is measured is that the flag is required, and
that the invariant holds at the document level.

Full suite after (`term-after.txt`): 99 + 52. Release UI, the four that type nothing
(`ui-release-after.txt`): all passing. The two UI tests that type were not run in this round.
