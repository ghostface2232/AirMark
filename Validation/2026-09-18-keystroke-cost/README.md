# Keystroke cost, re-measured on the current code

Mac17,3, arm64, macOS 27.0 (26A428), Xcode 27.0 (27A266a), Swift 6.4. Release, `swift test -c release`,
at commit `f8f1112`. Load average about 2. Three independent runs of each, as PLAN-2026-09-17 asks.

**Why.** The last recorded editor-only keystroke cost was 1MB p50/p95/max **3.69 / 9.05 / 10.26 ms**
(DEV_LOG, 2026-09-16), over the PLAN target of p95 ≤ 4 ms and max ≤ 8 ms. It had not been measured again
since, and the parse and presentation work in PR #1 and PR #2 has changed this path.

**How.** The same tests that produced that number, unchanged: `ScaleTests.largeDocumentRendersNearTheViewportAndStaysResponsive`
(30 edits at the end of a 1MB document, editor only), `documentKeystrokeCostsIncludeSnapshotAndDirtyState`
(with `NSDocument`'s snapshot copy and dirty state, at head, middle and tail), the Space and Return tests,
and the 10MB variants behind `AIRMARK_SCALE_10MB=1`. Raw output: `scale-release.txt`.

## Result

| | target | run 1 | run 2 | run 3 |
|---|---|---|---|---|
| 1MB editor-only p95 | ≤ 4 ms | 0.44 | 0.45 | 0.48 |
| 1MB editor-only max | ≤ 8 ms | 2.08 | 2.06 | 2.44 |
| 10MB NSDocument head p50 | ≤ 8 ms | 4.32 | 4.12 | 4.35 |
| 10MB NSDocument middle p50 | ≤ 8 ms | 2.94 | 2.22 | 2.26 |
| 10MB NSDocument tail p50 | ≤ 8 ms | 0.12 | 0.12 | 0.12 |

The 1MB target is met with about eight times headroom in every run; 9.05 ms is now 0.44–0.48 ms. The
10MB target is met with about twice the headroom at the worst position.

The worst single keystroke in any run is a plain space at 10MB, 7.32 ms — under one 120 Hz frame
(8.3 ms), but not by much. The 10MB head position costs most because an edit there moves everything after
it; that is linear in the document, as DEV_LOG has said since 2026-09-16, and it is what `head` measures.

| 10MB, p50 / p95 / max (ms) | run 1 | run 2 | run 3 |
|---|---|---|---|
| NSDocument head | 4.32 / 4.69 / 6.86 | 4.12 / 4.40 / 6.63 | 4.35 / 4.78 / 6.80 |
| space, plain | 2.69 / 3.09 / 6.83 | 2.58 / 3.11 / 6.87 | 2.58 / 3.19 / 7.32 |
| return, LF | 2.19 / 2.25 / 4.08 | 2.08 / 2.23 / 3.98 | 2.05 / 2.32 / 3.89 |

## What this does and does not say

- **Which change made the difference is not measured.** The drop happened somewhere between the
  2026-09-16 measurement and this commit. PR #1's rebase, span-list and windowed-install work is the
  likely cause, but no intermediate commit was measured, so it is not attributed.
- **Thirty samples per position**, so p95 is the second-slowest keystroke. The three runs agree closely,
  which is what makes the numbers usable.
- **This is the main-thread cost of an edit, not input-to-screen latency.** It stops when
  `performEdit` returns and does not include drawing the frame. PLAN.md's end-to-end targets —
  input to display p95 33 ms at 60 Hz, formatting within 100 ms after typing stops — are not measured by
  these tests.
- **Parse latency is a separate question.** A document containing `]:` is still parsed whole on every
  keystroke, which delays formatting (10MB: about 2.1 s p50, per DEV_LOG) but does not block typing.
