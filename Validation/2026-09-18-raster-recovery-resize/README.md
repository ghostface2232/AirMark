# Table raster policy, recovery launch I/O, live resize

Mac17,3, arm64, macOS 27.0 (26A428), Xcode 27.0 (27A266a), Swift 6.4. Debug `swift test` unless said
otherwise. Baseline is the end of `Validation/2026-09-18-recovery-sessions/`: 99 + 52 passing.

## 1. One raster policy, and a cache key that names it

**Problem.** `drawTable` read two inputs the key did not carry: the host window's screen colour space
and `NSParagraphStyle.defaultWritingDirection`. The key hashes `RenderEnvironment`, which carries the
scale but neither of these, so two windows at one scale on differently profiled screens shared an entry
and whichever rendered first decided the bytes for both. That a bitmap carries its colour space is true
of drawing and beside the point for a key.

**Fix.** `TableRenderer.raster(for:)` is the only place the policy lives, and `key` hashes exactly what
it reads: the requesting window's scale, a fixed sRGB, and the alignment. The screen stops being an
input rather than becoming one the key must name. `drawTable` no longer takes `host`.

**Why fixed sRGB is safe — measured.** A table draws neutral greys over alpha, and greys have the same
coordinates in sRGB and Display P3, so the same table drawn into either is identical:

```
TABLE_PROFILE sRGB and Display P3 bytes identical: true, 792000 bytes
```

`tableRasterIsSRGBWhicheverScreenAsks` asserts that equality, so it is a guard: give a table a saturated
colour and the bytes diverge, the test fails, and the policy is revisited instead of quietly becoming
wrong.

**Before → after.** `tableCacheKeyCoversTheRasterAndNothingElse` covers both conditions asked for — 1×
and 2× give different keys, two renders and scale-following dimensions; two hosts at one scale (one in a
window on a screen, one in no window, where the old code read two different colour spaces) give one key,
one render and the identical cached `CGImage`. Mutating the key to drop the scale, the same fault the
colour space had, fails it on 4 assertions including a 1× window handed the 2× bitmap. Full suite:
100 + 52.

## 2. A launch reads the records, not every document

**Problem.** Two costs at every launch. `records()` read every source in full — 32 MB for four 8 MB
documents — and `resolve` then ran **on the main actor**, reading each document's whole file,
re-encoding the record's source and comparing them. Most of those comparisons decided nothing: a record
written while the document's text was on disk is not the only copy of anything, and both answers the
comparison could give open the file at the recorded position.

**Fix.** The `<id>.json` plus `<id>.<token>.source` layout is untouched. `RecoveryMetadata` is a record
without its source, carrying the length the source has on disk, which `metadata()` takes from the
directory listing it already makes. `resolve` takes metadata and a `LaunchStorage` of `size`, `data`,
`source` — three closures because they cost three different amounts. `launchPlans(recentPaths:)`
resolves inside the store, which is an actor and not the main actor.

**Behaviour unchanged.** All five outcomes of the old branch — bytes equal, file gone, dirty and
different, dirty and empty, clean and different — are preserved, and the existing launch tests assert
them with their assertions untouched; only the call syntax moved.

**Before → after.**

```
RECOVERY_LAUNCH 4 records of 8000000 source bytes: metadata() 0.23 ms, records() 14.00 ms
```

`launchReadsNothingForDocumentsWhoseTextIsOnDisk`, a session of eight saved documents:

| | before (`launchio-before.txt`) | after |
|---|---:|---:|
| stats | 8 | 8 |
| document files read in full | 8 | **0** |
| record sources loaded | 16 | **0** |

Before was produced by restoring the old rule — compare every record — with everything else in place.
`launchComparesOnlyWhatTheLengthsLeaveOpen` pins the rest: a dirty record whose file is another length
is decided with no read; one whose length matches is read and compared; a BOM counts toward the length;
an empty record opens no window and its source is never loaded to find that out. Full suite: 100 + 55.

Release numbers across 1/8/32 documents at 1 MB and 10 MB are in
`Validation/2026-09-18-recovery-resize-table-bench/`.

## 3. A drag says when it is over

**Problem.** While geometry moved the editor armed a 150 ms wait, and a wait that woke to find the drag
still going armed another. A drag was a poll, its end was noticed up to 150 ms late, and the 150 ms had
no stated basis.

**Fix.** Nothing is armed during a drag; `didEndLiveResize` adopts the width it left behind and renders
once. Geometry that reports no end — a zoom, a full-screen transition, a divider, a scroller appearing —
is still coalesced, because it arrives as one layout pass per displayed frame. The wait only has to
outlast the gap between two frames, so it is **50 ms**, about three at 60 Hz with room for a missed one.

**Before → after.**

| | before | after |
|---|---|---|
| end of a drag → renders start | up to 150 ms, by a poll that happened to wake | **0.3 ms**, on the event |
| 21 non-drag geometry steps | 1 round, 154 ms after the last (`resize-150ms.txt`) | 1 round, 57 ms after the last |
| the same with coalescing removed | — | **21 rounds** (`resize-nocoalesce.txt`) |

`endOfADragAdoptsWithoutWaiting` pins the wait at 30 seconds and posts the end-of-drag notification: the
renders start 0.3 ms later, so nothing but the event can have started them. The 21-rounds mutation is
what keeps the wait — it earns its place; the 150 ms did not. Under a full parallel suite the same burst
settles in 132 ms rather than 57; the assertion allows a second and the number is printed, not asserted.

PR #1's work is untouched: the diff is the environment branch of `scheduleRenders`, one observer and
`scheduleEnvironmentChange`. Full suite: 102 + 55; the four non-typing UI tests pass in Release.

**Not verified.** `view.inLiveResize == true` is not exercised — see
`Validation/2026-09-18-recovery-resize-table-bench/`, which records the four routes tried.

## 4. A flaky test, root-caused

**Problem.** `repeatedSavesPreserveBytesWithoutFalseConflicts` failed `#expect(document.isDocumentEdited)`
about one full-suite run in ten, on a loaded machine, and predated this work.

**Two wrong turns, recorded because they cost time.** Replacing the fixed 250 ms wait with a poll for
`isDocumentEdited` made it worse: the edit sets that flag synchronously, so the poll returned at once,
the save ran before the undo group closed, and the group closing afterwards marked the document dirty
again — the failure moved to the assertion after the save in two of three runs. That is why the 250 ms
is still there: it waits for the undo group, not for the flag. Separately, `autosavingDelay == 0.0` was
read as ruling autosave out; it does not govern an `autosavesInPlace` document.

**Root cause.** Overriding `updateChangeCount(_:)` showed only `done` and never `cleared`, because an
asynchronous save clears the count through `updateChangeCount(withToken:for:)`. With that overridden too
and the loop raised to 40 passes, a failure was caught on the second run:

```
--append 24--  done/edited=true  done/edited=true  token-out(op4)/edited=true  token-in(op4)/edited=false
SAVE_DIAG pass=24 editorSource=235 expected=235 snapshot=235
```

`op4` is `autosaveInPlaceOperation`. An autosave-in-place fired between the append and the assertion,
wrote the file and cleared the dirty flag — with the edit present throughout, which is why exactly one
assertion failed. That is `autosavesInPlace` doing its job: the product was right and the test was wrong.

**Fix.** The assertion moved to before the first `await`, where nothing can run between the edit and it.
The assertion after a failed Save As became `isDocumentEdited || !hasUnautosavedChanges`, since
asserting only the first asserts that no autosave ran.

**Before → after.** Reproduced within two full-suite runs at 40 passes; after, four runs at 40 passes —
about 640 append-and-save cycles — with no failure. No production code changed; all diagnostics removed.
