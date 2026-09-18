# Discarding a document's changes

Mac17,3, arm64, macOS 27.0 (26A428), Xcode 27.0 (27A266a), Swift 6.4. UI tests in Release on an idle
machine; they type into the app.

## What the close panel actually is — probed before anything was changed

The task was written around `Close → Don't Save`. AirMark does not offer that for a document with a
file, and these two probes settled it rather than a reading of the source.

**A document with a file** (`probe-saved-file.txt`) — type into an opened file, press Cmd-W:

```
PROBE sheets=0 dialogs=0 windows=0
PROBE file on disk after Cmd-W: "original\nEDITED"
```

No panel. `autosavesInPlace` writes the edit and closes. **There is no Don't Save to reach for a saved
file, and no discarded text for a launch to revive.**

**An unsaved draft** (`probe-untitled-draft.txt`) — type into a blank document, press Cmd-W:

```
PROBE sheet buttons: ["Delete", "Cancel", "Save"]
```

The panel appears because `autosavesDrafts` is false, and macOS labels its discard button **Delete**.
This is the path the report was about, and the bug was real on it.

## Problem

Clicking Delete and then reading the recovery directory:

```
PROBE record state=closed hasUnsavedChanges=1 filePath=nil
PROBE source file holds: "DISCARD ME"
```

`close()` wrote a `.closed` record holding the discarded text, still marked as unsaved work. The launch
falls back to the most recently put-away document, finds a record with no file path and text in it, and
offers it as a "Recovered" window — exactly what the user had just deleted.

## Fix

`close()` asks whether the changes are being kept. A document still edited as it closes is one whose
changes are being thrown away — nothing else leaves it in that state — and its recovery is invalidated
before `close()` returns, through the synchronous writer the quit path uses.

- **An unsaved draft**: its record goes. The text was never anywhere but in that record.
- **A document with a file**: the record is replaced by a `.closed` one, clean, holding the bytes on
  disk, so the next launch opens the file at the position it was left at.

Both go through `discardImmediately(_:replacingWith:)`, one writer operation — see
`Validation/2026-09-18-review-fixes/`, which is where that became atomic. As first written this was a
remove and then a save, and a failed remove left the discarded text on disk under the clean record.

**Cancel** needs no code — a cancelled close is a close that does not happen — and has a test anyway.

## Before → after

| test | before (`unit-before.txt`) | after |
|---|---|---|
| `discardingAnUntitledDraftRemovesItsRecovery` | 3 issues | pass |
| `discardingEditsToASavedFileLeavesTheFileToOpen` | 4 issues | pass |
| `cancellingACloseKeepsTheRecovery` | pass | pass |
| `savingADraftOnCloseLeavesItsFileToOpen` | — | pass |

Before was produced by restoring the old unconditional `.closed` write. The Cancel test passes either
way by design: Cancel was never broken, and the test is there so it stays that way.

End to end through a relaunch, with the old `close()` (`ui-before.txt`):

```
XCTAssertTrue failed  - the discarded draft is still recorded: ["503DBAC6-…json"]
XCTAssertFalse failed - the discarded draft came back: "DISCARD ME"
```

After: passes. `testCancelledCloseKeepsTheDraftAfterRelaunch` clicks Cancel, checks the window, its text
and its record survive, then force-quits and relaunches to find it restored — force, because a clean
quit asks about the unsaved draft all over again, and surviving a stop that never asked is what recovery
is for. `testEditingASavedFileIsKeptOnCloseAndRelaunch` pins the probe above as a test.

Full suite, five consecutive runs: 106 + 55 as the suite stood then. All UI tests passed in Release at
that point; UI tests could not be run later in the day — see `Validation/2026-09-18-review-fixes/`.

## Not covered, and why

- **`Close → Don't Save` on a saved file is not tested, because it does not happen.** The handling is
  written and unit-tested against a programmatic close, so a document that ever does close with changes
  on it is handled, but no UI test can reach that panel while `autosavesInPlace` is true, and none
  claims to. Making it reachable is a product decision nobody asked for.
- **The panel's Save button is not driven from the UI.** The app is sandboxed, so that save panel is the
  system's powerbox and not AirMark; automating it would say more about the panel than about this app.
  What Save leads to is asserted by `savingADraftOnCloseLeavesItsFileToOpen`.
- The recovery directory is shared with whatever other suites are running, because
  `MarkdownDocument.recoveryStore` is a static they all set. The new tests resolve a launch from the
  document's own record for that reason: a foreign record does not just add a plan, it can decide the
  launch instead. One test failed twice that way before this was understood.
