# Table raster policy, recovery launch I/O, live resize

Host: Mac17,3, arm64, macOS 27.0 (26A428), Xcode 27.0 (27A266a), Swift 6.4. Debug `swift test`
unless stated otherwise. Observations on this machine, not PLAN.md budget certifications. Baseline is
the end of `Validation/2026-09-18-recovery-sessions/`: 99 tests in 15 suites, 52 in 4 suites.

## 1. One raster policy, and a cache key that names it

### Problem

`drawTable` read two inputs the cache key did not carry:

- the host window's screen color space, and
- `NSParagraphStyle.defaultWritingDirection(forLanguage: nil)`.

The key hashes `RenderEnvironment`, which carries the scale but neither of these. Two windows at the
same scale on differently profiled screens therefore shared one entry, and whichever rendered first
decided the bytes for both. The comment claimed a bitmap "carries its color space, so a result shared
with a window on another screen is converted rather than shown wrong", which is true of drawing and
beside the point for a key: a key that does not name an input cannot tell the two results apart.

### Change

`TableRenderer.raster(for:)` is now the only place the policy lives, and `RenderService.key` hashes
exactly what it reads:

- **scale** — `environment.scale`, the requesting window's, already in the key.
- **color space** — a fixed sRGB. The screen stops being an input rather than becoming an input the
  key has to name.
- **alignment** — added to the key for table elements.

`drawTable` no longer takes `host`.

### Why fixed sRGB is safe, measured

A table draws neutral grays over an alpha channel and is composited onto the text view's background.
Grays have the same coordinates in sRGB and in Display P3 — same white point, same transfer curve,
the primaries never enter — so the same table drawn into either profile is identical:

```
TABLE_PROFILE sRGB and Display P3 bytes identical: true, 792000 bytes
```

`tableRasterIsSRGBWhicheverScreenAsks` asserts that equality, so it is a guard rather than a remark:
give a table a saturated color and the bytes diverge, the test fails, and the policy has to be
revisited instead of silently becoming wrong.

### Result

| test | before | after |
|---|---|---|
| `tableRasterIsSRGBWhicheverScreenAsks` (replaces `tableColorSpaceComesFromTheHostWindowsScreen`) | — | pass |
| `tableCacheKeyCoversTheRasterAndNothingElse` | — | pass |
| `tableRasterFollowsTheRequestingWindow` | pass | pass |
| `matchesTheAppKitReference` | pass | pass |

The new cache test covers both conditions asked for. 1× and 2× produce different keys, two renders and
pixel dimensions that follow the scale; two hosts at one scale — one in a window on a screen, one in no
window, which is where the old code read two different color spaces — produce one key, one render, and
the second call returns the identical `CGImage` from the cache.

Mutating the key to drop the scale, which is the same fault the color space had, fails it on 4
assertions, including a 1× window being handed the 2× bitmap. Full suite: 100 + 52 passing.

## 2. A launch reads what it needs to decide

### Problem

Two costs, both paid at every launch:

- `RecoveryStore.records()` read every record's source in full and decoded it to a `String`. A
  directory holding four 8 MB documents read 32 MB before the launch had decided anything.
- `LaunchPlan.resolve` then ran **on the main actor**, inside `applicationDidFinishLaunching`'s
  `Task { @MainActor in }`. For every record it read that document's whole file from disk, re-encoded
  the record's source to `Data`, and compared the two — on the thread that has a window to put up.

The comparison was also asked of records that cannot answer anything with it. A record written while
the document's text was on disk is not the only copy of anything, and both outcomes the comparison
could reach — the file still matches, or another app has changed it since — open the file at the
recorded position. The comparison decided nothing and cost a whole document.

### Change

The file layout is untouched: `<id>.json` beside `<id>.<token>.source`, written exactly as before.

- `RecoveryMetadata` is a record without its source, with `sourceBytes` — the length the source has on
  disk. `RecoveryStore.metadata()` takes that length from the directory listing it already makes and
  reads only the small JSON beside it. `source(of:)` loads one record's text, through the same loader
  `records()` uses, so an inline source from an older build is read the same way here as anywhere.
- `LaunchPlan.resolve` takes metadata and a `LaunchStorage` of three closures — `size`, `data`,
  `source` — because they cost three different amounts. A clean record costs one `size`. A record that
  may hold the only copy of its text is compared, but a file of a length the record cannot have is
  ruled out without reading either side. `.openFile` carries metadata; `.recoverDraft` carries a whole
  record, and is the only plan whose source is loaded.
- `RecoveryStore.launchPlans(recentPaths:)` resolves inside the store, which is an actor and not the
  main actor. `main.swift` awaits it. Every file read and every comparison is off the main thread.

Behaviour is unchanged. All five outcomes of the old branch — bytes equal, file gone, dirty and
different, dirty and empty, clean and different — are preserved, and the existing launch tests assert
them with their assertions untouched; only the call syntax moved to the new API.

### Result

`RecoveryStoreTests.metadataReadsTheRecordsWithoutTheirSources`, four records of 8 MB:

```
RECOVERY_LAUNCH 4 records of 8000000 source bytes: metadata() 0.00023 seconds, records() 0.01400 seconds
```

60× on a warm cache, and 32 MB not read. The same test then resolves a real launch of that directory
and gets four `.openFile` plans with no source loaded.

`SourceTests.launchReadsNothingForDocumentsWhoseTextIsOnDisk` counts the calls for a session of eight
saved documents:

| | before (`launchio-before.txt`) | after |
|---|---:|---:|
| stats | 8 | 8 |
| document files read in full | 8 | **0** |
| record sources loaded | 16 | **0** |

Before was produced by restoring the old rule — compare every record — with everything else in place.

`launchComparesOnlyWhatTheLengthsLeaveOpen` pins the rest: a dirty record whose file is another length
is decided with no read; one whose length matches is read and compared, and wins or loses on the
bytes; a BOM counts toward the length it is checked against; an empty record opens no window and its
source is never loaded to find that out.

Full suite: 100 + 55 passing.
