# Render queue refill, Space and Return input paths

Host: Mac17,3, 24 GiB RAM, arm64, macOS 27.0 (26A428), Swift 6.4. OS cache state uncontrolled. These are observations on this machine, not PLAN.md budget certifications. Each "before" run is the commit's test or benchmark against the unchanged implementation.

## 1. Render queue refill

At most 12 renders run at once. When one finished it freed its slot but nothing asked for the next element, so elements past the first 12 waited for an unrelated scroll, resize or parse.

- `render-refill-before.txt`: `swift test --disable-sandbox --filter elementsBeyondTheInFlightLimitRenderWithoutScrolling` (Debug) at `85943dc` with only the new test. 30 images in one paragraph on screen: 24 of 30 rendered on first display (an incidental layout pass started a second batch); after releasing every pixel and making one request, 12 of 30.
- `render-refill-after.txt`: the same test after the change: 30 of 30 both times, 30 requests per pass (no duplicates), at most 12 in flight.
- `render-refill-release-before.txt` / `render-refill-release-after.txt`: `AIRMARK_MEMORY=1 swift test -c release --disable-sandbox --filter 'MemoryTests|elementsBeyondTheInFlightLimitRenderWithoutScrolling'`. In Release the stall is worse (12 of 30 on first display). The 150-image scroll is unchanged within its earlier run-to-run range: peak growth 71.2 → 65.5MB, requests down/up 178/138 → 176/138, 14 images holding pixels in both.

A finished render (stored or recorded as a failure) releases its slot, checked against its token, and calls `scheduleRenders()` from the task. That call cannot recurse: `scheduleRenders` only creates tasks, whose bodies run later. A cancelled, stale or postponed render returns before that point; whoever cancelled it schedules again, and a postponed render in a hidden window would otherwise request itself in a loop. The element just finished is skipped because it now has pixels or an error.

## 2. Space: task shortcut check without bridging the document

`convertToTask(before:)` passed `text as String`, the whole storage, to the expression with a range covering the line so far. It now passes the line so far (at most 64 UTF-16 units) as its own string, and reads the indentation and mark from that string. The expression, its anchors and the 64-unit limit are unchanged; `bracketsThenSpaceAfterListMarkerMakeATask` passes.

- `space-before.txt` / `space-after.txt`: `AIRMARK_SCALE_10MB=1 swift test -c release --disable-sandbox --filter 'spaceKeystrokeCosts|tenMegabyteSpaceKeystrokeCosts'`, two runs each; before is the new benchmark against the unchanged implementation. The benchmark types in a paragraph line in the middle of a 1MB and a 10MB document. `check` is `convertToTask(before:)` alone where no shortcut matches; `plain` is one `insertText(" ")` there; `shortcut` is the Space that turns `[]` into `- [ ] `.
- `space-bridge-probe.txt`: a standalone probe of the bridge on a 10MB `NSTextStorage`.

| Release p50 (two runs) | before | after |
|---|---:|---:|
| check, 1MB | 0.0014 ms | 0.0015 ms |
| check, 10MB | 0.0015 ms | 0.0016–0.0017 ms |
| plain Space, 1MB | 0.96–0.97 ms | 0.97 ms |
| plain Space, 10MB | 2.52–2.54 ms | 2.53–2.56 ms |
| shortcut Space, 1MB | 0.45–0.46 ms | 0.45–0.46 ms |
| shortcut Space, 10MB | 1.98–2.04 ms | 2.01–2.05 ms |

The change is not measurable on this host. On macOS 27 with Swift 6.4 the bridge does not copy: `text as String` on a 10MB storage costs about 80 ns, and the check was already size-independent before the change. It is kept because it was asked for and makes the check's cost independent of how the platform bridges `NSString`; no speedup is claimed. What does grow with size is the edit itself: the `_PHASES` lines show `rebase` at 0.17 ms (1MB) and 1.7 ms (10MB) of the plain Space, which is moving every style after a mid-document edit (recorded as linear by design in `2026-09-17-w1-w3/README.md`). That was not changed here.
