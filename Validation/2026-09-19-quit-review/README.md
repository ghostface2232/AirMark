# Quitting with an edited document, and where a quit can be cancelled

Base `fd44d09`, in a separate worktree so other work in progress stayed out of the build. Debug.

## Where a quit can be called off

`quit-order-probe.swift` is a bare AppKit app with AirMark's document policy (`autosavesInPlace`, no
draft autosave) and logging in the document controller, the document, the delegate and
`NSApplication.terminate(_:)`. "Refuse" makes `canClose` answer no, which is what the review panel's
Cancel does. Logout is the quit Apple Event with `keyAEQuitReason = kAELogOut` sent to the app itself;
no real logout was run.

| case | order |
|---|---|
| clean, Cmd-Q | `terminate:` → delegate → `willTerminate` → the documents close → exit |
| one edited, Cmd-Q | `terminate:` → `reviewUnsavedDocuments` → **every document closes**, clean ones too → delegate, with no documents left → `willTerminate` → exit |
| edited, refused | `terminate:` returns inside the review; the delegate is never asked |
| logout, clean | the event handler asks the delegate itself; `terminate:` follows on a later turn → `willTerminate` → exit |
| logout, refused | the review runs before the delegate and cancels there |
| logout, edit made between the delegate and `terminate:` | no second review; straight to `willTerminate` |

Everything that can cancel a quit comes before `applicationShouldTerminate`, and nothing after
`.terminateNow` does. A flag set in the delegate cannot outlive a quit on a process that keeps running,
the case left open in `2026-09-18-recovery-sessions` §3. That note assumed the documents close after the
delegate. They do for a clean quit, and only after `applicationWillTerminate`.

## The bug this found

With a document edited, AppKit closes every document before the delegate, so each `close()` ran with the
flag clear and wrote `.closed`, and the delegate found no documents to record. A quit shortly after an
edit, before autosave, left a session that did not come back.

`testQuitRightAfterAnEditRecordsTheDocumentAsQuit` edits with Edit ▸ Paste and quits through the menu,
so nothing is typed. On the base, it fails with `"closed"` where `"quit"` is expected
(`ui-edit-quit-before.txt`); the edit itself was kept on disk.

## Fix

- `AirMarkDocumentController.reviewUnsavedDocuments` begins the quit: records every document `.quit` and
  sets the flag, then runs AppKit's review with its own callback. AppKit's `didReviewAll` answer is the
  cancellation signal; `false` clears the flag, and the answer is passed on to AppKit's delegate.
- `applicationShouldTerminate` begins the quit the same way when there was no review.
- `close()` during a quit writes `.quit` again instead of skipping the write: a draft saved from the
  review panel has a file by then. An edited document at close is still discarded, which is what Delete
  in the review panel means. The record keeps the window order taken when the quit began; the order read
  during the closes is only the windows still left.

## Results

| | base | fix |
|---|---|---|
| `testQuitRightAfterAnEditRecordsTheDocumentAsQuit` | fails (`closed`) | passes |
| `testDraftDeletedInTheQuitReviewIsNotRecorded` | — | passes |
| `testCancelledQuitLeavesALaterCloseRecordedAsClosed` | — | passes; **fails** (`quit`) with the flag-clearing line removed (`ui-cancel-without-clearing.txt`) |
| existing quit and session tests (4) | — | pass |

Run 1 (`ui-after-run1.txt`): 6 of 7. `testCancelledCloseKeepsTheDraftAfterRelaunch` found no close sheet
after Cmd-W. It ran first in the batch, before any new test. Alone it passes on the base and on the fix
(`ui-cancelled-close-*.txt`), and run 2 passed all 7 (`ui-after-run2.txt`). Not investigated further.

The four typing tests and `testCancelledCloseKeepsTheDraftAfterRelaunch`: 5 of 5 with PriType's English
mode selected by the helper instead of ABC (`ui-typing-pritype-english.txt`). The user's source,
PriType Korean, was restored afterwards.

Unit: 109 tests in 16 suites and 60 in 4 suites (`unit-after.txt`).

## Not verified

- A real logout through loginwindow, or another app cancelling one.
- The Save button of the quit's review panel: it opens the sandbox's save panel, which the UI tests do
  not drive (see the note in `AirMarkUITests`). The `.quit` rewrite at close is what covers it.
- Release configuration.
