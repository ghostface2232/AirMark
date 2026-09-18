# Three fixes from review: source size, window order, discard atomicity

Mac17,3, arm64, macOS 27.0 (26A428), Xcode 27.0 (27A266a), Swift 6.4.
`swift test --disable-sandbox` and `swift test -c release --disable-sandbox`.

## 1. An unreadable source size is not zero

**Problem.** `metadata()` recorded a source file's size as `?? 0` when the listing could not give one,
and `loadMetadata` dropped a record whose size it could not find. A record of zero bytes is an empty
one: `LaunchPlan` opens no window for it, and nothing but the record holds a draft's text. A draft
whose size could not be read was therefore lost, silently.

**Fix.** An unknown size is left out of the listing rather than written down as zero, and the loader
falls back — listing, then a stat of the file, then the file itself. Only a source that cannot be read
at all still drops the record, which is what `records()` does with one.

**Verified.** `aSourceLengthTheListingDidNotGiveIsFoundNotAssumed` asks the loader for a length the
listing does not have and gets the true one; an empty source still reads as zero; a source that is
really gone still drops the record. `aNonEmptyRecordIsNeverReadAsEmpty` runs the whole path and finds
the draft offered back and the empty record opening nothing.

**Before → after.** Both pass. **The failure that reaches this is not injectable** —
`contentsOfDirectory` caches the value it was asked for, so it does not fail for a file that is there —
so what is covered is the fallback the fix routes to, not the stat failure itself. This is a defensive
fix and the test says so rather than implying a reproduction.

## 2. Window order applied, not inherited

**Problem.** The launch opened each plan and asked the last one to come to the front. `openDocument`
finishes asynchronously and in no particular order, so the stacking of everything else was whatever the
completions happened to do. The session records which window was in front and it was not being used.

**Fix.** The opens still run together. Each reports its document into a main-actor `OpenedDocuments`,
and when the last lands the windows are ordered back to front — the order the plans came in — and the
last is made key. Nothing depends on completion order any more.

**Verified.** Unit: `launchRestoresTheSessionsWindowOrder` already pins that `resolve` returns the
plans back to front, and 109 + 60 tests pass in Debug and Release.

**Verified, end to end.** `testRelaunchRestoresTheLastSessionAndNotTheOneBefore` restores three
documents and asserts the whole stacking, front to back — not just the count. Its first version, with
two small documents, passed on the old code as well: the old code asked the last document for the front
from its own completion, and with two that happens to be enough. It was rewritten until it could fail.

| | old code | this change |
|---|---|---|
| window titles, front to back | `["Middle.md", "Front.md", "Back.md"]` in 2 of 3 runs | `["Front.md", "Middle.md", "Back.md"]` in 5 of 5 |

Front's completion brought it forward and Middle's completion landed after, on top. The back document is
large to spread the completions apart; whether that is what exposes the race was not isolated.

This could not be run at first. From 14:21 every UI run failed to activate the app, where the whole
file had passed 11 of 11 at 12:16 in the same session; reverting `main.swift` reproduced it, so it was
not this change. It cleared once the machine was attended to — a prompt waiting on the console is the
likely cause, though that was not observed from here.

## 3. Discard is one writer operation

**Problem.** `discardRecovery` removed the record, ignored whether that worked, and then saved a
replacement at the same revision. The writer reuses the source file it last wrote for a revision, so a
failed remove left the **discarded text** on disk under a record claiming to hold the file's text — and
a launch would hand it back.

**Fix.** `RecoveryStore.discardImmediately(_:replacingWith:)` does it under one lock: drop the record,
drop its sources, then write the replacement fresh. The order is the opposite of `save`'s on purpose.
A save writes the source before the JSON that names it, so an interrupted save keeps what it had. A
discard removes the JSON first, because the JSON is the only thing that makes a source reachable, so an
interrupted discard leaves nothing of what was discarded — losing the replacement is the worst it can
do, and a document not restored is the right way to fail at throwing a document away.

**Verified.**

| test | before | after |
|---|---|---|
| `discardingReplacesTheRecordInOneOperation` | 2 issues — the record still names the discarded text, and the source is still on disk | pass |
| `anInterruptedDiscardLeavesNothingToRestore` | 1 issue — the discarded source survives | pass |
| `discardingADraftLeavesTheDirectoryEmpty` | — | pass |

Before was produced by restoring the two-step path, with the remove failing the way it used to be
allowed to. A crash cannot be injected into the middle of a locked file operation, so the interrupted
case is covered by its consequence: take the replacement away, as a failed write would have left it,
and nothing of the discarded document is left to find.

## Also

`recordsNameTheSessionThatWroteThem` resolved a launch over every record in the recovery directory,
which is shared with whatever suites run alongside — `MarkdownDocument.recoveryStore` is a static they
all set — so a neighbour's record could decide the launch instead. It failed that way once here. It now
resolves over its own two records, like the other tests that were corrected for this earlier.

## Suites

Debug 109 tests in 16 suites and 60 in 4 suites, three consecutive runs. Release the same.

UI, Release, the whole file: **7 of 11**. The seven that type nothing pass, including the window-order
test. The four that type — `testDiscardedDraftIsNotRestoredAfterRelaunch`,
`testEditingASavedFileIsKeptOnCloseAndRelaunch`, `testRepeatedAsynchronousSavesPreserveSource`,
`testTypingUndoAndReplaceAll` — all fail for one reason, visible in their output:

```
("얀ㅊㅁㄲㅇ 뜨") is not equal to ("DISCARD ME")
("… ㄴㅁㅍㄷ 1. ㄴㅁㅍㄷ 2. …") is not equal to ("… Save 1. Save 2. …")
```

Keystrokes arrive through the active Korean input method. The machine was in use at the time, with the
third-party input method `com.pritype.inputmethod.v2` selected. `useASCIIInputSource()` does select
`com.apple.keylayout.ABC` — checked — and moving that selection to after the editor has focus made no
difference, so the helper does not overcome this input method. The same four passed at 12:16 on an
idle machine. This is the test environment and not the branch; run the typing tests with ABC selected.

**Then run at the console:** `bash Scripts/test-ui.sh -configuration Release`, the whole file —

```
Executed 11 tests, with 0 failures (0 unexpected) in 108.602 seconds
** TEST SUCCEEDED **
```

All four typing tests and the window-order test included. That settles the input-method diagnosis, and
it is the final UI state of the branch.
