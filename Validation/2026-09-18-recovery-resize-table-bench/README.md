# Recovery, resize and table: regression tests and Release measurements

Host: Mac17,3, 24 GiB RAM, arm64, macOS 27.0 (26A428), Xcode 27.0 (27A266a), Swift 6.4. Release
builds, idle machine. OS cache state uncontrolled and **warm** where it matters — see the caveat under
the recovery numbers. Observations on this machine, not PLAN.md budget certifications.

```sh
AIRMARK_BENCH=1 swift test -c release --disable-sandbox --filter RecoveryResizeTableBench
bash Scripts/test-ui.sh -configuration Release
```

`RecoveryResizeTableBench` is gated on `AIRMARK_BENCH`: an ordinary Release run skips all three of its
tests in 0.001 s. Nothing in it repeats the parse benchmarks — `ParsePacingBench` and `ScaleTests` own
those, and a second set of the same numbers would only be more to keep honest.

## 1. What is covered, and where

| | covered by |
|---|---|
| multi-document recovery | `launchRestoresEveryDocumentThatWasOpen`, `launchRestoresEveryOpenDocumentWithoutALimit`, `twoEditedDocumentsAreBothRecovered`, and **`UITests.testRelaunchRestoresTheLastSessionAndNotTheOneBefore`**, which is new |
| stale-session rejection | `launchRestoresOnlyTheLastSessionsDocuments`, `recordsNameTheSessionThatWroteThem`, and the same new UI test |
| close durability | `closingWritesTheRecordBeforeItReturns`, `closingADocumentRecordsItAsClosed` |
| quit restore | `closeDuringTerminationKeepsTheQuitRecord`, `UITests.testQuitRecordsAnOpenDocumentAsQuitNotClosed`, and **`UITests.testQuitRestoresTheDocumentThatWasOpen`**, which is new |
| table cache | `tableCacheKeyCoversTheRasterAndNothingElse`, `tableRasterIsSRGBWhicheverScreenAsks`, and `tableCacheAndRaster` in the bench |
| live resize | `draggingAWindowKeepsRenderedElementsInPlace`, `endOfADragAdoptsWithoutWaiting`, `geometryThatReportsNoEndIsCoalescedIntoOneRound`, and `liveResizeCost` in the bench |

The new session UI test hands the launch a recovery directory a previous run would have left — two
`.quit` records from one session and one from the session before — which is the only way to put several
documents and two sessions in front of a real launch without opening windows by hand. It finds two
windows, `FRONT DOCUMENT` and `BACK DOCUMENT`, and not `STALE DOCUMENT`.

## 2. Recovery launch, Release

`launchPlans` is the whole decision: read the records, work out what to open, off the main actor.
`decideTheOldWay` is the same decision made as it was before — every record's source loaded, then every
document's file read and compared with it — written out in the bench rather than inferred, so this is a
measurement and not an argument. p50 of 3, milliseconds.

**Clean records — every document's text was on disk when it was recorded, which is the ordinary case:**

| documents | size each | decide the old way | `launchPlans` | files read | sources loaded |
|---:|---:|---:|---:|---:|---:|
| 1 | 1 MB | 0.49 | **0.08** | 0 | 0 |
| 8 | 1 MB | 3.68 | **0.38** | 0 | 0 |
| 32 | 1 MB | 15.63 | **1.34** | 0 | 0 |
| 1 | 10 MB | 4.63 | **0.09** | 0 | 0 |
| 8 | 10 MB | 37.86 | **0.43** | 0 | 0 |
| 32 | 10 MB | 148.16 | **1.41** | 0 | 0 |

The shape matters more than the ratio: **the cost no longer follows the size of the documents.** One
document costs 0.08 ms at 1 MB and 0.09 ms at 10 MB; thirty-two cost 1.34 ms and 1.41 ms. It is a stat
per record and a small JSON read, and that is all. The old decision read 320 MB to restore 32 ten-megabyte
documents and took 148 ms doing it.

**Unsaved records — every record may hold the only copy of its text, the worst case:**

| documents | size each | decide the old way | `launchPlans` | files read | sources loaded |
|---:|---:|---:|---:|---:|---:|
| 8 | 10 MB | 36.04 | 30.48 | 0 | 8 |
| 32 | 10 MB | 142.54 | 122.51 | 0 | 32 |

Here the sources are loaded, because each one becomes a draft and the draft is the text. But **no
document file is read at all**: the recorded length does not match the file's, so the exact comparison
is ruled out before either side is touched. What is left is work that has to happen.

**Caveat.** These files were written moments before they were read, so the cache is warm and this is
not a cold launch. What that flatters is the reading — `records()` and `decideTheOldWay`, which read
hundreds of megabytes. A cold disk would make the gap wider, not narrower. The `launchPlans` figures
touch almost nothing either way.

## 3. Live resize, Release

```
BENCH_RESIZE elements=12 steps=21 rendersDuringDrag=0 measuredDuringDrag=12 rendersInTheRoundAfter=12
  | rendersStart 53.4ms afterLastStep | pixelsBack 58.8ms
  | mainThread perStep p50=0.75 min=0.73 max=0.95 totalDuringDrag=16.4ms
  | paragraph n=68 p50=0.01 max=0.06 | artifacts n=46 p50=0.00 max=0.00
```

Twelve rendered elements, twenty-one width steps from 770 to 610 points:

- **Renders started for widths passed through: 0.** All twelve elements keep their metrics the whole
  way, so nothing falls back to its source text and nothing is rendered for a width already gone.
- **After the last step**, the renders start at 53.4 ms — the 50 ms coalescing wait and what the
  scheduler adds — and the pixels are back at 58.8 ms. One round, twelve requests, one per element.
- **Main thread per step**: 0.75 ms p50, 0.95 ms worst, 16.4 ms across the whole drag. Building
  paragraphs is 0.01 ms each and moving artifacts rounds to zero; the rest is TextKit's own layout.

These steps are frame changes, so `view.inLiveResize` is false and this is the coalescing path. A real
drag skips the wait entirely and adopts on `didEndLiveResize`, which `endOfADragAdoptsWithoutWaiting`
covers at 0.3 ms.

**There is no UI test for a window resize, and it is not for want of trying.** Four routes were
measured here and none of them both resizes the window and leaves the suite usable:

- `XCUICoordinate.press(forDuration:thenDragTo:)` across the whole resize margin, and on the title bar:
  the window neither moved nor resized, for any grab point.
- HID `CGEvent`s posted to `.cghidEventTap`: `NSEvent.mouseLocation` was unchanged afterwards, so the
  runner does not get to post them here.
- The accessibility API, to set the window's size directly: `kAXErrorAPIDisabled`.

`kAXErrorAPIDisabled` says the test runner is not trusted for accessibility, and the HID failure is
consistent with the same thing. Both were true while every other UI test was passing, so they are about
input synthesis and not about the machine being unusable. Worth retrying at a logged-in console, with
the runner granted accessibility, before treating a window drag as impossible here.
- Double-clicking the title bar to zoom: harmless, and it does not zoom this window.

The full-screen button does work and resizes the window from 710 to 1710 points. Terminating out of the
space it creates then left the **next** test failing with "Cmd-Q did not quit the app" — twice,
including a test that passes on its own. That test was written, measured, and removed: one that breaks
the tests after it is worse than none.

**Covered since.** With the test runner trusted for Accessibility, HID events do drive a real edge drag,
and `view.inLiveResize == true` is covered by `testLiveResizeByDraggingTheWindowEdge` —
`Validation/2026-09-18-live-resize-ui/`.

## 4. Table cache and raster, Release

```
BENCH_TABLE scale=1x 40x5 points=766x1648 pixels=766x1648  bytes=10125312 | miss 13.61ms | hit p50=0.02ms | renders=1
BENCH_TABLE scale=2x 40x5 points=766x1648 pixels=1532x3296 bytes=40395776 | miss 11.67ms | hit p50=0.02ms | renders=1
BENCH_TABLE both scales in one cache: renders=2 1x=766x1648 2x=1532x3296
```

A 40×5 table: a miss costs 12–14 ms to measure and draw, a hit 0.02 ms, and twenty hits in a row render
nothing again. The two scales are two entries — 2× is exactly twice 1× in each direction and four times
the bytes, the table occupies the same 766×1648 points in both, and both bitmaps are sRGB whatever
screen asked. Neither scale is ever served the other's pixels.

## 5. Suites

- `swift test -c release --disable-sandbox`: 109 tests in 16 suites, 55 in 4 suites, all passing.
- `swift test --disable-sandbox` (Debug): the same, all passing.
- `Scripts/test-ui.sh -configuration Release`, the whole file: **11 of 11 passing**, including the two
  that type, which needed an idle machine and got one. `testRelaunchRestoresTheLastSessionAndNotTheOneBefore`
  later gained an assertion about the frontmost window that has **not** been run — see
  `Validation/2026-09-18-review-fixes/`.
