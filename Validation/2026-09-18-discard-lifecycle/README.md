# Discarding a document's changes, and what the next launch offers back

Host: Mac17,3, arm64, macOS 27.0 (26A428), Xcode 27.0 (27A266a), Swift 6.4. UI tests in Release on an
idle machine; they type into the app. Observations on this machine, not PLAN.md budget certifications.

## What the close panel actually is — measured before anything was changed

The task was written around `Close → Don't Save`. AirMark does not offer that for a document with a
file, and the two probes recorded here are what settled it rather than a reading of the source.

**A document with a file** (`probe-saved-file.txt`): type into an opened file, press Cmd-W.

```
PROBE sheets=0 dialogs=0 windows=0
PROBE file on disk after Cmd-W: "original\nEDITED"
```

No panel at all. `MarkdownDocument.autosavesInPlace` is true, so AppKit writes the edit and closes.
**There is no Don't Save to reach for a saved file, and no discarded text for a launch to revive.**

**An unsaved draft** (`probe-untitled-draft.txt`): type into a blank document, press Cmd-W.

```
PROBE sheet buttons: ["Delete", "Cancel", "Save"]
```

The panel appears because `autosavesDrafts` is false, and macOS labels its discard button **Delete**.
This is the path the report is about, and the bug was real on it.

## The bug

Clicking Delete and then reading the recovery directory:

```
PROBE record state=closed hasUnsavedChanges=1 filePath=nil
PROBE source file holds: "DISCARD ME"
```

`close()` wrote a `.closed` record holding the discarded text and still marked as unsaved work. At the
next launch `LaunchPlan.resolve` finds no open records, falls back to the most recently put-away
document, sees a record with no file path and text in it, and offers it as `.recoverDraft` — a
"Recovered" window holding exactly what the user had just deleted.

## Change

`close()` now asks whether the changes are being kept. A document that is still edited as it closes is
one whose changes are being thrown away — nothing else leaves it in that state — and its recovery is
invalidated before `close()` returns, through the synchronous writer the quit path uses:

- **An unsaved draft**: `removeImmediately(identity)`. Its text was never anywhere but in that record,
  and it has been discarded, so the record and its source file go with it.
- **A document with a file**: the record is removed and written again as `.closed`, with
  `hasUnsavedChanges: false` and the bytes the file holds, so the next launch opens the file at the
  position it was left at and the discarded text is not left in the recovery directory. It is removed
  first because the writer keeps the source it last wrote for a revision, and this document's revision
  is the discarded text's.

`RecoveryStore.removeImmediately` is new, and is `remove` without the actor hop, for the same reason
`saveImmediately` exists: `close()` cannot await.

**Cancel** needs nothing. A cancelled close is a close that does not happen, so `close()` is never
called and the debounced record stands. It has a test because that is worth keeping true.

## Result

### Unit

| test | before (`unit-before.txt`) | after |
|---|---|---|
| `discardingAnUntitledDraftRemovesItsRecovery` | 3 issues | pass |
| `discardingEditsToASavedFileLeavesTheFileToOpen` | 4 issues | pass |
| `cancellingACloseKeepsTheRecovery` | pass | pass |
| `savingADraftOnCloseLeavesItsFileToOpen` | — | pass |

Before was produced by restoring the old unconditional `.closed` write. `cancellingACloseKeepsTheRecovery`
passes either way by design: Cancel was never broken, and the test is there so it stays that way.

Full suite, five consecutive runs: 106 tests in 15 suites and 55 in 4 suites, all passing.

### UI, end to end through a relaunch

`testDiscardedDraftIsNotRestoredAfterRelaunch` types into a blank document, presses Cmd-W, clicks
**Delete**, waits for the record to be gone, quits, and relaunches into the same recovery directory
with no file and no `--blank`, so the launch decides from the records alone.

With the old `close()` (`ui-before.txt`):

```
XCTAssertTrue failed - the discarded draft is still recorded: ["503DBAC6-…json"]
XCTAssertFalse failed - the discarded draft came back: "DISCARD ME"
```

After: passes. `testCancelledCloseKeepsTheDraftAfterRelaunch` clicks **Cancel**, checks the window and
its text survive and the record still holds the draft, then force-quits and relaunches to find it
restored — force, because a clean quit asks about the unsaved draft all over again, and surviving a
stop that never asked is what recovery is for. `testEditingASavedFileIsKeptOnCloseAndRelaunch` pins the
probe above as a test: no panel, the edit on disk, and the relaunch opening it.

All seven UI tests run pass in Release (`ui-release-after.txt`), including the four that existed before.

## Not covered, and why

- **`Close → Don't Save` on a saved file is not tested, because it does not happen.** Cmd-W on an
  edited file-backed document autosaves in place; the measurement is above. The handling for it is
  written and unit-tested against a programmatic close, so a document that ever does close with
  changes on it is handled — but no UI test can reach that panel today, and none claims to.
  Making it reachable would mean turning off `autosavesInPlace`, which is a product decision nobody
  asked for.
- **The close panel's Save button is not driven from the UI.** The app is sandboxed, so the save panel
  it opens for a draft belongs to the system's powerbox and not to AirMark; automating it says more
  about the panel than about this app. What Save leads to is asserted at the document level by
  `savingADraftOnCloseLeavesItsFileToOpen`.
- The recovery directory is shared with whatever other suites are running, because
  `MarkdownDocument.recoveryStore` is a static they all set. The new tests resolve a launch from the
  document's own record for that reason; a foreign record does not just add a plan, it can decide the
  launch instead. One of them failed twice that way before this was understood.
